#!/usr/bin/env bash

# ----------------------------------------------------------------------
# CONFIGURAZIONE
# ----------------------------------------------------------------------
CALCURSE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/calcurse"
BACKUP_DIR="$HOME/Projects/calendar"
TODAY=$(date +%Y%m%d-%H%M%S)
TODAY_PROTON=$(date +%Y-%m-%d)

IMPORT_FILE="$BACKUP_DIR/calendar.ics"          # file scaricato da Proton
EXPORT_FILE="$BACKUP_DIR/calendario.ics"       # export da calcurse
BACKUP_FILE="$BACKUP_DIR/backup_$TODAY.ics"
NEW_EVENTS_FILE="$BACKUP_DIR/nuovi-appuntamenti-calcurse.ics"

mkdir -p "$BACKUP_DIR"

die() {
    echo "❌ Errore: $1" >&2
    exit 1
}

# ----------------------------------------------------------------------
# FUNZIONE PULIZIA BACKUP
# ----------------------------------------------------------------------
clean_old_backups() {
    echo "🧹 Pulizia vecchi backup (mantenendo solo gli ultimi 3)..."
    local backup_files=("$BACKUP_DIR"/backup_*.ics)
    if [[ ${#backup_files[@]} -gt 3 ]]; then
        # Ordina per data e rimuovi i più vecchi
        for file in $(ls -1 "$BACKUP_DIR"/backup_*.ics | sort | head -n -3); do
            echo "Rimuovo: $(basename "$file")"
            rm -- "$file"
        done
        echo "✅ Backup puliti: mantenuti solo gli ultimi 3"
    else
        echo "✅ Meno di 3 backup, nessuna pulizia necessaria"
    fi
}

# ----------------------------------------------------------------------
# FUNZIONE GESTIONE FILE PROTON
# ----------------------------------------------------------------------
find_and_prepare_proton_file() {
    local proton_file
    
    # Cerca il file Proton più recente
    proton_file=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "My calendar-*.ics" -o -name "My Calendar-*.ics" \) -type f | sort -r | head -n1)
    
    if [[ -n "$proton_file" ]]; then
        echo "🔄 Trovato nuovo file Proton: $(basename "$proton_file")"
        # Rinomina in calendar.ics per uso futuro
        mv "$proton_file" "$IMPORT_FILE"
        echo "✅ File rinominato in: $(basename "$IMPORT_FILE")"
    elif [[ -f "$IMPORT_FILE" ]]; then
        echo "📁 Uso file Proton esistente: $(basename "$IMPORT_FILE")"
    else
        die "Nessun file Proton trovato e $IMPORT_FILE non esiste"
    fi
}

# ----------------------------------------------------------------------
# FUNZIONI PER LA NORMALIZZAZIONE DEI PROMEMORIA
# ----------------------------------------------------------------------

# Converte un trigger in secondi
convert_trigger_to_seconds() {
    local trigger="$1"
    local seconds=0

    # Rimuovi spazi bianchi
    trigger=$(echo "$trigger" | tr -d '[:space:]')

    if [[ $trigger =~ ^-P([0-9]+)D$ ]]; then
        # Giorni: -P1D
        seconds=$(( ${BASH_REMATCH[1]} * 86400 ))
    elif [[ $trigger =~ ^-P([0-9]+)DT([0-9]+)H$ ]]; then
        # Giorni e ore: -P1DT2H
        seconds=$(( (${BASH_REMATCH[1]} * 86400) + (${BASH_REMATCH[2]} * 3600) ))
    elif [[ $trigger =~ ^-P([0-9]+)DT([0-9]+)H([0-9]+)M$ ]]; then
        # Giorni, ore e minuti: -P1DT2H30M
        seconds=$(( (${BASH_REMATCH[1]} * 86400) + (${BASH_REMATCH[2]} * 3600) + (${BASH_REMATCH[3]} * 60) ))
    elif [[ $trigger =~ ^-P([0-9]+)S$ ]]; then
        # Secondi: -P300S
        seconds=${BASH_REMATCH[1]}
    elif [[ $trigger =~ ^-PT([0-9]+)M$ ]]; then
        # Minuti: -PT15M
        seconds=$(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ $trigger =~ ^-PT([0-9]+)H$ ]]; then
        # Ore: -PT1H
        seconds=$(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ $trigger =~ ^-PT([0-9]+)H([0-9]+)M$ ]]; then
        # Ore e minuti: -PT1H30M
        seconds=$(( (${BASH_REMATCH[1]} * 3600) + (${BASH_REMATCH[2]} * 60) ))
    else
        seconds=0
    fi

    echo "$seconds"
}

# Converte i secondi in un trigger per il sistema target
convert_seconds_to_trigger() {
    local seconds=$1
    local target=$2
    
    if [ "$target" == "proton" ]; then
        # Arrotonda ai minuti (arrotondamento per eccesso se >=30 secondi)
        local minutes=$(( (seconds + 30) / 60 ))
        
        # Mappa a valori standard comuni
        if [[ $minutes -le 5 ]]; then
            standard_minutes=5
        elif [[ $minutes -le 10 ]]; then
            standard_minutes=10
        elif [[ $minutes -le 15 ]]; then
            standard_minutes=15
        elif [[ $minutes -le 30 ]]; then
            standard_minutes=30
        elif [[ $minutes -le 60 ]]; then
            standard_minutes=60
        elif [[ $minutes -le 120 ]]; then
            standard_minutes=120
        elif [[ $minutes -le 1440 ]]; then
            standard_minutes=1440
        else
            standard_minutes=1440
        fi
        echo "-PT${standard_minutes}M"
    else
        # Calcurse: usa i secondi esatti
        echo "-P${seconds}S"
    fi
}

# Normalizza i promemoria di un evento per il sistema target
normalize_alarms() {
    local event_block="$1"
    local target_system="$2"
    
    # Se non ci sono promemoria, restituisci l'evento così com'è
    if ! echo "$event_block" | grep -q "BEGIN:VALARM"; then
        echo "$event_block"
        return 0
    fi
    
    local result=""
    local in_alarm=0
    local current_alarm=""
    local in_event=0
    local alarm_count=0
    
    # Processa l'evento riga per riga
    while IFS= read -r line; do
        case $line in
            "BEGIN:VEVENT")
                in_event=1
                result+="$line"$'\n'
                ;;
            "END:VEVENT")
                if [[ $in_alarm -eq 1 ]]; then
                    # Chiudi l'allarme aperto se presente
                    result+="END:VALARM"$'\n'
                    in_alarm=0
                fi
                in_event=0
                result+="$line"$'\n'
                ;;
            "BEGIN:VALARM"*)
                in_alarm=1
                alarm_count=$((alarm_count + 1))
                # Inizia un nuovo blocco VALARM corretto
                result+="BEGIN:VALARM"$'\n'
                
                # Se la linea contiene già altri campi, processali
                local remaining_line="${line#BEGIN:VALARM}"
                if [[ -n "$remaining_line" ]]; then
                    # Se c'è altro testo dopo BEGIN:VALARM, processalo come righe separate
                    while [[ "$remaining_line" =~ ^(TRIGGER|ACTION|DESCRIPTION): ]]; do
                        local field_line="$remaining_line"
                        remaining_line=""
                        result+="$field_line"$'\n'
                    done
                fi
                ;;
            "END:VALARM")
                in_alarm=0
                result+="$line"$'\n'
                ;;
            "TRIGGER:"*)
                if [[ $in_alarm -eq 1 ]]; then
                    local trigger=$(echo "$line" | cut -d: -f2-)
                    local seconds=$(convert_trigger_to_seconds "$trigger")
                    local new_trigger=$(convert_seconds_to_trigger "$seconds" "$target_system")
                    
                    result+="TRIGGER:$new_trigger"$'\n'
                else
                    result+="$line"$'\n'
                fi
                ;;
            "ACTION:"*)
                if [[ $in_alarm -eq 1 ]]; then
                    result+="$line"$'\n'
                    # Per Proton, assicurati che ci sia DESCRIPTION dopo ACTION
                    if [[ "$target_system" == "proton" ]]; then
                        local event_summary=$(echo "$event_block" | grep "^SUMMARY:" | head -1 | cut -d: -f2-)
                        if [[ -n "$event_summary" ]] && ! echo "$current_alarm" | grep -q "^DESCRIPTION:"; then
                            result+="DESCRIPTION:$event_summary"$'\n'
                        fi
                    fi
                else
                    result+="$line"$'\n'
                fi
                ;;
            *)
                if [[ $in_alarm -eq 1 ]]; then
                    # Per Proton, aggiungi campi mancanti obbligatori
                    if [[ "$target_system" == "proton" && ! "$line" =~ ^(DESCRIPTION|SUMMARY): ]]; then
                        # Se manca DESCRIPTION, usa il summary dell'evento
                        local event_summary=$(echo "$event_block" | grep "^SUMMARY:" | head -1 | cut -d: -f2-)
                        if [[ -n "$event_summary" ]] && ! echo "$current_alarm" | grep -q "^DESCRIPTION:"; then
                            result+="DESCRIPTION:$event_summary"$'\n'
                        fi
                    fi
                    result+="$line"$'\n'
                elif [[ $in_event -eq 1 ]]; then
                    result+="$line"$'\n'
                else
                    result+="$line"$'\n'
                fi
                ;;
        esac
    done < <(echo "$event_block")
    
    # Se stiamo esportando per Proton, assicuriamoci che i VALARM siano completi
    if [[ "$target_system" == "proton" && $alarm_count -gt 0 ]]; then
        local temp_result=""
        local in_valarm=0
        local current_valarm=""
        
        while IFS= read -r line; do
            if [[ "$line" == "BEGIN:VALARM" ]]; then
                in_valarm=1
                current_valarm="$line"$'\n'
            elif [[ "$line" == "END:VALARM" ]]; then
                in_valarm=0
                current_valarm+="$line"$'\n'
                
                # Verifica che il VALARM abbia tutti i campi necessari per Proton
                if ! echo "$current_valarm" | grep -q "^DESCRIPTION:"; then
                    # Aggiungi DESCRIPTION mancante
                    local event_summary=$(echo "$result" | grep "^SUMMARY:" | head -1 | cut -d: -f2-)
                    if [[ -n "$event_summary" ]]; then
                        # Inserisci DESCRIPTION dopo ACTION
                        if echo "$current_valarm" | grep -q "^ACTION:"; then
                            current_valarm=$(echo "$current_valarm" | sed '/^ACTION:/a DESCRIPTION:'"$event_summary")
                        else
                            # Se non c'è ACTION, aggiungi dopo BEGIN:VALARM
                            current_valarm=$(echo "$current_valarm" | sed '/^BEGIN:VALARM/a DESCRIPTION:'"$event_summary")
                        fi
                    fi
                fi
                
                temp_result+="$current_valarm"
                current_valarm=""
            elif [[ $in_valarm -eq 1 ]]; then
                current_valarm+="$line"$'\n'
            else
                temp_result+="$line"$'\n'
            fi
        done < <(echo "$result")
        
        result="$temp_result"
    fi
    
    # Rimuovi l'ultima newline se presente
    result="${result%$'\n'}"
    
    echo "$result"
}

# ----------------------------------------------------------------------
# FUNZIONI PER LA GESTIONE DEGLI UID
# ----------------------------------------------------------------------

# Genera un UID artificiale basato sul contenuto dell'evento
generate_event_uid() {
    local event_block="$1"
    local source_system="$2"
    
    # Estrai le proprietà chiave per l'hash
    local dtstart=$(echo "$event_block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | tr -d '\r\n')
    local summary=$(echo "$event_block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | tr -d '\r\n')
    local description=$(echo "$event_block" | grep "^DESCRIPTION:" | head -1 | cut -d: -f2- | tr -d '\r\n')
    local duration=$(echo "$event_block" | grep "^DURATION:" | head -1 | cut -d: -f2- | tr -d '\r\n')
    local dtend=$(echo "$event_block" | grep "^DTEND" | head -1 | sed 's/^DTEND[^:]*://' | tr -d '\r\n')
    
    # Usa anche la source_system per evitare collisioni tra sistemi
    local uid_base="${source_system}|${dtstart}|${summary}|${description}|${duration}|${dtend}"
    local uid_hash=$(echo -n "$uid_base" | sha256sum | cut -d' ' -f1 | head -c 16)
    
    echo "CALCURSE-${uid_hash}@$(hostname)"
}

# Esporta Calcurse con UID artificiali
export_calcurse_with_uids() {
    echo "📤 Esporto i miei eventi con UID in $EXPORT_FILE…"
    local temp_export=$(mktemp)
    calcurse -D "$CALCURSE_DIR" --export > "$temp_export" || die "Esportazione fallita"
    
    # Aggiungi UID agli eventi che non li hanno
    local in_event=0
    local event_block=""
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            event_block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            event_block+=$'\n'"$line"
            
            # Se l'evento non ha UID, aggiungine uno
            if ! echo "$event_block" | grep -q "^UID:"; then
                local uid=$(generate_event_uid "$event_block" "calcurse")
                # Inserisci UID dopo BEGIN:VEVENT
                event_block=$(echo "$event_block" | sed "/^BEGIN:VEVENT/a UID:$uid")
            fi
            
            echo "$event_block"
            in_event=0
            event_block=""
        elif [[ $in_event -eq 1 ]]; then
            event_block+=$'\n'"$line"
        else
            echo "$line"
        fi
    done < "$temp_export" > "$EXPORT_FILE"
    
    rm -f "$temp_export"
    [[ -s "$EXPORT_FILE" ]] && echo "✅ Esportazione con UID completata"
}

# ----------------------------------------------------------------------
# FUNZIONE DI CONFRONTO MIGLIORATA CON SUPPORO UID
# ----------------------------------------------------------------------
find_new_events() {
    local proton_file="$1"
    local calcurse_file="$2"
    local output_file="$3"

    echo "🔍 Confronto i file .ics per trovare nuovi eventi…"

    [[ -f "$proton_file" ]]   || die "File Proton non trovato: $proton_file"
    [[ -f "$calcurse_file" ]] || die "File calcurse non trovato: $calcurse_file"

    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)
    local out_tmp=$(mktemp)

    # ------------------------------------------------------------------
    # Extract VEVENT blocks
    # ------------------------------------------------------------------
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$proton_file"   | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$calcurse_file" | tr -d '\r' > "$calcurse_tmp"

    # ------------------------------------------------------------------
    # Helper: extract and normalize key event properties
    # ------------------------------------------------------------------
    get_event_signature() {
        local event="$1"
        
        # Extract and normalize DTSTART (remove timezone, parameters)
        local dtstart=$(echo "$event" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | sed 's/[[:space:]]*$//')
        
        # Extract SUMMARY
        local summary=$(echo "$event" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
        
        # Extract DESCRIPTION
        local description=$(echo "$event" | grep "^DESCRIPTION:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
        
        # Calculate duration in minutes
        local duration_minutes=0
        if echo "$event" | grep -q "^DURATION:"; then
            local duration=$(echo "$event" | grep "^DURATION:" | head -1 | cut -d: -f2-)
            # Parse ISO8601 duration P0DT0H30M0S
            if [[ $duration =~ P([0-9]+)DT([0-9]+)H([0-9]+)M([0-9]+)S ]]; then
                local days=${BASH_REMATCH[1]}
                local hours=${BASH_REMATCH[2]}
                local minutes=${BASH_REMATCH[3]}
                duration_minutes=$((days * 1440 + hours * 60 + minutes))
            fi
        elif echo "$event" | grep -q "^DTEND"; then
            local dtend=$(echo "$event" | grep "^DTEND" | head -1 | sed 's/^DTEND[^:]*://')
            # Simple duration calculation (would need proper date parsing for production)
            duration_minutes=30 # default assumption
        else
            duration_minutes=0
        fi
        
        # Extract and normalize alarms for signature
        local alarm_signature=""
        if echo "$event" | grep -q "BEGIN:VALARM"; then
            local alarm_blocks=$(echo "$event" | awk '/BEGIN:VALARM/,/END:VALARM/')
            while IFS= read -r alarm_block; do
                if [[ "$alarm_block" =~ ^TRIGGER: ]]; then
                    local trigger=$(echo "$alarm_block" | grep "^TRIGGER:" | cut -d: -f2-)
                    local seconds=$(convert_trigger_to_seconds "$trigger")
                    # Arrotonda a step di 300 secondi (5 minuti) per normalizzazione
                    local rounded_seconds=$(( (seconds + 150) / 300 * 300 ))
                    alarm_signature+=",${rounded_seconds}"
                fi
            done < <(echo "$alarm_blocks")
        fi
        
        # Remove leading comma if present
        alarm_signature="${alarm_signature#,}"

        # Create a unique signature based on core properties
        printf "%s|%s|%s|%d|%s" "$dtstart" "$summary" "$description" "$duration_minutes" "$alarm_signature"
    }

    # ------------------------------------------------------------------
    # Build lookup for Proton events by UID and signature
    # ------------------------------------------------------------------
    declare -A proton_uids
    declare -A proton_signatures
    local block="" in_event=0 proton_count=0
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            local uid=$(echo "$block" | grep "^UID:" | cut -d: -f2-)
            if [[ -n "$uid" ]]; then
                proton_uids["$uid"]=1
            fi
            local sig=$(get_event_signature "$block")
            proton_signatures["$sig"]=1
            ((proton_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"

    echo "📊 Trovati $proton_count eventi nel file Proton"

    # ------------------------------------------------------------------
    # Header for output
    # ------------------------------------------------------------------
    cat > "$out_tmp" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//calcurse-sync//Nuovi Eventi//
EOF

    # ------------------------------------------------------------------
    # Find new events in Calcurse
    # ------------------------------------------------------------------
    local new_count=0
    block="" in_event=0
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            local uid=$(echo "$block" | grep "^UID:" | cut -d: -f2-)
            local sig=$(get_event_signature "$block")
            local summary=$(echo "$block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            
            local is_duplicate=0
            
            # Prima controlla per UID
            if [[ -n "$uid" && -n "${proton_uids[$uid]}" ]]; then
                is_duplicate=1
                echo "➖ Già presente (per UID): $summary"
            # Poi controlla per signature
            elif [[ -n "${proton_signatures[$sig]}" ]]; then
                is_duplicate=1
                echo "➖ Già presente (per signature): $summary"
            else
                # Ulteriore controllo: look for events with same summary and similar time
                local dtstart=$(echo "$block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://')
                for proton_sig in "${!proton_signatures[@]}"; do
                    local proton_summary=$(echo "$proton_sig" | cut -d'|' -f2)
                    local proton_dtstart=$(echo "$proton_sig" | cut -d'|' -f1)
                    
                    # If summary matches and dtstart is the same or very close, it's likely a duplicate
                    if [[ "$proton_summary" == "$summary" ]] && [[ "$proton_dtstart" == "$dtstart" ]]; then
                        is_duplicate=1
                        echo "➖ Escluso duplicato confermato: $summary ($dtstart)"
                        break
                    fi
                done
            fi
            
            if [[ $is_duplicate -eq 0 ]]; then
                # Normalizza i promemoria per Proton prima di scrivere
                local normalized_event=$(normalize_alarms "$block" "proton")
                
                # Correzione aggiuntiva: separa BEGIN:VALARM dai campi successivi
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMTRIGGER/BEGIN:VALARM\nTRIGGER/g')
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMACTION/BEGIN:VALARM\nACTION/g')
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMDESCRIPTION/BEGIN:VALARM\nDESCRIPTION/g')
                
                echo "$normalized_event" >> "$out_tmp"
                ((new_count++))
                echo "➕ Nuovo evento: $summary ($dtstart)"
            fi
            
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"

    # ------------------------------------------------------------------
    # Footer
    # ------------------------------------------------------------------
    echo "END:VCALENDAR" >> "$out_tmp"

    # ------------------------------------------------------------------
    # Final cleanup
    # ------------------------------------------------------------------
    # Remove empty lines but keep event structure
    sed '/^$/d' "$out_tmp" > "$output_file"
    rm -f "$proton_tmp" "$calcurse_tmp" "$out_tmp"

    echo "✅ Trovati $new_count nuovi eventi genuini in $output_file"
}

# ----------------------------------------------------------------------
# FUNZIONE DI FILTRO TEMPORALE
# ----------------------------------------------------------------------
filter_events_by_date() {
    local input_file="$1"
    local output_file="$2"
    local days_future="${3:-30}"
    
    local current_datetime=$(date +%Y%m%dT%H%M%S)
    local current_date=$(date +%Y%m%d)
    local end_date=$(date -d "+${days_future} days" +%Y%m%d)
    
    echo "📅 Filtro eventi da oggi a $end_date"
    
    # Crea file temporanei
    local temp_file=$(mktemp)
    local filtered_temp=$(mktemp)
    
    # Header del calendario
    echo "BEGIN:VCALENDAR" > "$filtered_temp"
    echo "VERSION:2.0" >> "$filtered_temp"
    echo "PRODID:-//calcurse-sync//Filtro Temporale//" >> "$filtered_temp"
    
    # Estrai tutti gli eventi VEVENT
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$input_file" | tr -d '\r' > "$temp_file"
    
    # Processa ogni evento
    local event_block=""
    local in_event=0
    local has_rrule=0
    local dtstart=""
    local dtstart_type=""
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            event_block="$line"
            in_event=1
            has_rrule=0
            dtstart=""
            dtstart_type=""
        elif [[ "$line" == "END:VEVENT" ]]; then
            event_block+=$'\n'"$line"
            
            # Determina se includere l'evento
            local include_event=0
            
            if [[ $has_rrule -eq 1 ]]; then
                # Includi sempre eventi ricorrenti
                include_event=1
            elif [[ -n "$dtstart" ]]; then
                if [[ "$dtstart_type" == "date" ]]; then
                    # Per eventi giornalieri (senza ora): includi se la data è tra oggi e end_date
                    if [[ "$dtstart" -ge "$current_date" ]] && [[ "$dtstart" -le "$end_date" ]]; then
                        include_event=1
                    fi
                else
                    # Per eventi con ora: estrai solo la parte della data per il controllo dell'intervallo
                    local event_date="${dtstart:0:8}"
                    # Controlla se la data è nell'intervallo E se l'evento è nel futuro
                    if [[ "$event_date" -le "$end_date" ]]; then
                        # Se l'evento è oggi, controlla l'ora, altrimenti includi se è nel futuro
                        if [[ "$event_date" -eq "$current_date" ]]; then
                            # Per eventi di oggi, controlla se l'ora è nel futuro
                            local event_time="${dtstart:9}"
                            local current_time=$(date +%H%M%S)
                            if [[ "$event_time" > "$current_time" ]]; then
                                include_event=1
                            fi
                        else
                            # Per eventi futuri (non oggi), includi sempre
                            include_event=1
                        fi
                    fi
                fi
            else
                # Se non possiamo determinare la data, includi per sicurezza
                include_event=1
            fi
            
            if [[ $include_event -eq 1 ]]; then
                echo "$event_block" >> "$filtered_temp"
            fi
            
            in_event=0
            event_block=""
        elif [[ $in_event -eq 1 ]]; then
            event_block+=$'\n'"$line"
            
            # Estrai DTSTART e determina il tipo
            if [[ "$line" =~ ^DTSTART ]]; then
                if [[ "$line" =~ VALUE=DATE ]]; then
                    # Formato: DTSTART;VALUE=DATE:20231231 (evento giornaliero)
                    dtstart=$(echo "$line" | cut -d: -f2 | tr -cd '0-9')
                    dtstart_type="date"
                elif [[ "$line" =~ T ]]; then
                    # Formato: DTSTART:20231231T083000 (evento con ora)
                    # Estrai solo la parte dopo i due punti e rimuovi eventuali timezone
                    dtstart=$(echo "$line" | sed 's/^[^:]*://' | sed 's/Z$//' | sed 's/[^0-9T]//g')
                    dtstart_type="datetime"
                else
                    # Formato: DTSTART:20231231 (evento giornaliero)
                    dtstart=$(echo "$line" | cut -d: -f2 | tr -cd '0-9')
                    dtstart_type="date"
                fi
            fi
            
            # Controlla se è ricorrente
            if [[ "$line" =~ ^RRULE: ]]; then
                has_rrule=1
            fi
        fi
    done < "$temp_file"
    
    # Footer del calendario
    echo "END:VCALENDAR" >> "$filtered_temp"
    
    # Rimuovi linee vuote multiple
    sed '/^$/d' "$filtered_temp" > "$output_file"
    
    # Pulizia
    rm -f "$temp_file" "$filtered_temp"
    
    local filtered_count=$(grep -c "^BEGIN:VEVENT" "$output_file" 2>/dev/null || echo "0")
    echo "✅ Filtro completato: $filtered_count eventi nell'intervallo selezionato"
}

# ----------------------------------------------------------------------
# FUNZIONI PER LE OPZIONI
# ----------------------------------------------------------------------

option_A() {
    echo "➡️  Importa/aggiorna eventi da Proton (merge)"
    
    # Trova e prepara il file Proton
    find_and_prepare_proton_file
    local proton_file="$IMPORT_FILE"
    
    echo "🔄 Trovato: $(basename "$proton_file")"
    
    # Backup prima del merge
    echo "💾 Backup in $BACKUP_FILE..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup fallito"
    
    # Export degli eventi attuali di Calcurse per il confronto
    local current_calcurse_export=$(mktemp)
    export_calcurse_with_uids
    cp "$EXPORT_FILE" "$current_calcurse_export"
    
    # Normalizza i promemoria per Calcurse prima dell'importazione
    local proton_file_normalized=$(mktemp)
    echo "🔄 Normalizzo i promemoria per Calcurse..."
    
    # Processa tutto il file Proton normalizzando i promemoria
    {
        local in_event=0
        local event_block=""
        
        while IFS= read -r line; do
            if [[ "$line" == "BEGIN:VEVENT" ]]; then
                in_event=1
                event_block="$line"
            elif [[ "$line" == "END:VEVENT" ]]; then
                event_block+=$'\n'"$line"
                # Normalizza i promemoria per Calcurse
                normalize_alarms "$event_block" "calcurse"
                in_event=0
                event_block=""
            elif [[ $in_event -eq 1 ]]; then
                event_block+=$'\n'"$line"
            else
                echo "$line"
            fi
        done < "$proton_file"
    } > "$proton_file_normalized"
    
    echo "🔄 Cerco nuovi eventi da Proton da importare in Calcurse..."
    
    # Crea file temporanei per il confronto
    local new_events_for_calcurse=$(mktemp)
    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)
    
    # Estrai VEVENT blocks
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$proton_file_normalized" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$current_calcurse_export" | tr -d '\r' > "$calcurse_tmp"
    
    # Mappa UID degli eventi esistenti in Calcurse
    declare -A calcurse_uids
    declare -A calcurse_events
    
    local block="" in_event=0
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            local uid=$(echo "$block" | grep "^UID:" | cut -d: -f2-)
            if [[ -n "$uid" ]]; then
                calcurse_uids["$uid"]=1
            fi
            
            # Estrai informazioni chiave per confronto più robusto
            local dtstart=$(echo "$block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | sed 's/[[:space:]]*$//')
            local summary=$(echo "$block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            local description=$(echo "$block" | grep "^DESCRIPTION:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            
            # Crea chiavi multiple per matching robusto
            local key1="${dtstart}|${summary}"  # Data + Titolo
            local key2="${summary}"             # Solo titolo (per eventi ricorrenti)
            
            calcurse_events["$key1"]=1
            calcurse_events["$key2"]=1
            
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"
    
    # Trova eventi Proton che non sono in Calcurse
    local import_count=0
    block="" in_event=0
    
    # Header per il file di import
    echo "BEGIN:VCALENDAR" > "$new_events_for_calcurse"
    echo "VERSION:2.0" >> "$new_events_for_calcurse"
    echo "PRODID:-//calcurse-sync//Import da Proton//" >> "$new_events_for_calcurse"
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            
            local uid=$(echo "$block" | grep "^UID:" | cut -d: -f2-)
            local dtstart=$(echo "$block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | sed 's/[[:space:]]*$//')
            local summary=$(echo "$block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            local description=$(echo "$block" | grep "^DESCRIPTION:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            
            # Crea le stesse chiavi usate per Calcurse
            local key1="${dtstart}|${summary}"
            local key2="${summary}"
            
            local should_import=1
            
            # Controllo 1: UID diretto
            if [[ -n "$uid" && -n "${calcurse_uids[$uid]}" ]]; then
                echo "➖ Già presente (UID): $summary"
                should_import=0
            # Controllo 2: Data + Titolo esatti
            elif [[ -n "${calcurse_events[$key1]}" ]]; then
                echo "➖ Già presente (data+titolo): $summary ($dtstart)"
                should_import=0
            # Controllo 3: Solo titolo (per eventi ricorrenti che potrebbero avere date diverse ma sono lo stesso evento)
            elif [[ -n "${calcurse_events[$key2]}" ]]; then
                # Per eventi ricorrenti, controlla più attentamente
                local is_recurring=$(echo "$block" | grep -c "^RRULE:")
                if [[ $is_recurring -gt 0 ]]; then
                    echo "➖ Già presente (titolo ricorrente): $summary"
                    should_import=0
                else
                    # Per eventi non ricorrenti, cerca corrispondenze esatte per data
                    local found_exact=0
                    for calcurse_key in "${!calcurse_events[@]}"; do
                        if [[ "$calcurse_key" == *"|$summary" ]]; then
                            local calcurse_dtstart=$(echo "$calcurse_key" | cut -d'|' -f1)
                            # Se la data è la stessa, è un duplicato
                            if [[ "$calcurse_dtstart" == "$dtstart" ]]; then
                                found_exact=1
                                break
                            fi
                        fi
                    done
                    if [[ $found_exact -eq 1 ]]; then
                        echo "➖ Già presente (data+titolo): $summary ($dtstart)"
                        should_import=0
                    fi
                fi
            fi
            
            # Controllo aggiuntivo: cerca eventi con stesso summary e data molto simile
            if [[ $should_import -eq 1 ]]; then
                for calcurse_key in "${!calcurse_events[@]}"; do
                    if [[ "$calcurse_key" == *"|$summary" ]]; then
                        local calcurse_dtstart=$(echo "$calcurse_key" | cut -d'|' -f1)
                        # Se le date sono simili (entro 24 ore) e il titolo è uguale, probabilmente è lo stesso evento
                        if [[ "${calcurse_dtstart:0:8}" == "${dtstart:0:8}" ]]; then
                            echo "➖ Escluso duplicato (data simile): $summary ($dtstart)"
                            should_import=0
                            break
                        fi
                    fi
                done
            fi
            
            if [[ $should_import -eq 1 ]]; then
                echo "$block" >> "$new_events_for_calcurse"
                ((import_count++))
                echo "➕ Nuovo evento da importare: $summary ($dtstart)"
            fi
            
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"
    
    # Footer
    echo "END:VCALENDAR" >> "$new_events_for_calcurse"
    
    # Importa solo i nuovi eventi in Calcurse
    if [[ $import_count -gt 0 ]]; then
        echo "📥 Importo $import_count nuovi eventi da Proton a Calcurse…"
        calcurse -D "$CALCURSE_DIR" -i "$new_events_for_calcurse" || die "Importazione fallita"
        
        # Aggiorna il file di export dopo l'importazione
        echo "🔄 Aggiorno il file di export con i nuovi eventi importati..."
        export_calcurse_with_uids
    else
        echo "✅ Nessun nuovo evento da importare da Proton"
    fi
    
    # Pulizia
    rm -f "$proton_file_normalized" "$current_calcurse_export" "$new_events_for_calcurse" "$proton_tmp" "$calcurse_tmp"
    
    # Pulizia backup vecchi
    clean_old_backups
    
    echo "✅ Importazione completata! Eventi aggiornati da Proton (merge)."
    echo "📁 Backup salvato: $BACKUP_FILE"
    echo "📁 Export aggiornato: $EXPORT_FILE"
    echo "📊 Eventi importati: $import_count"
}

option_B() {
    echo "➡️  Sincronizza tutti gli eventi con Proton"
    export_calcurse_with_uids
    find_and_prepare_proton_file
    find_new_events "$IMPORT_FILE" "$EXPORT_FILE" "$NEW_EVENTS_FILE"
    echo "📁 File per Proton: $NEW_EVENTS_FILE"
}

option_C() {
    echo "➡️  Sincronizza solo eventi futuri (30 giorni)"
    export_calcurse_with_uids
    find_and_prepare_proton_file
    
    local proton_filtered=$(mktemp)
    local calcurse_filtered=$(mktemp)
    
    filter_events_by_date "$IMPORT_FILE" "$proton_filtered" 30
    filter_events_by_date "$EXPORT_FILE" "$calcurse_filtered" 30
    
    find_new_events "$proton_filtered" "$calcurse_filtered" "$NEW_EVENTS_FILE"
    
    rm -f "$proton_filtered" "$calcurse_filtered"
    echo "📁 File per Proton (solo eventi futuri): $NEW_EVENTS_FILE"
}

option_D() {
    echo "➡️  Sincronizza con intervallo personalizzato"
    read -rp "Giorni nel futuro da includere (default: 90): " days_future
    days_future=${days_future:-90}
    
    export_calcurse_with_uids
    find_and_prepare_proton_file
    
    local proton_filtered=$(mktemp)
    local calcurse_filtered=$(mktemp)
    
    filter_events_by_date "$IMPORT_FILE" "$proton_filtered" "$days_future"
    filter_events_by_date "$EXPORT_FILE" "$calcurse_filtered" "$days_future"
    
    find_new_events "$proton_filtered" "$calcurse_filtered" "$NEW_EVENTS_FILE"
    
    rm -f "$proton_filtered" "$calcurse_filtered"
    echo "📁 File per Proton (prossimi $days_future giorni): $NEW_EVENTS_FILE"
}

option_E() {
    echo "🔄 SYNC COMPLETA: Proton → Calcurse"
    echo "⚠️  ATTENZIONE: Questo sostituirà completamente Calcurse con Proton"
    echo "   Tutti gli eventi in Calcurse non presenti in Proton verranno PERDUTI!"
    
    read -rp "Sei sicuro? (scrivi 'CONFERMO' per procedere): " confirmation
    if [[ "$confirmation" != "CONFERMO" ]]; then
        echo "❌ Sincronizzazione annullata"
        return 1
    fi
    
    find_and_prepare_proton_file
    
    # Backup
    echo "💾 Backup in $BACKUP_FILE..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup fallito"
    
    # Sostituzione completa
    echo "🗑️  Svuoto Calcurse..."
    > "$CALCURSE_DIR/apts"
    
    echo "📥 Importo tutto da Proton..."
    calcurse -D "$CALCURSE_DIR" -i "$IMPORT_FILE" || die "Importazione fallita"
    
    # Aggiorna export
    export_calcurse_with_uids
    clean_old_backups
    
    echo "✅ Sincronizzazione completa completata!"
    echo "📁 Backup salvato: $BACKUP_FILE"
}

option_F() {
    echo "🧹 SYNC COMPLETA: Report sincronizzazione bidirezionale"
    
    export_calcurse_with_uids
    find_and_prepare_proton_file
    
    # File unico per il report (sovrascritto ogni volta)
    local sync_report="$BACKUP_DIR/sync-report.txt"
    > "$sync_report"  # Svuota il file
    
    # 1. Trova nuovi eventi da Calcurse a Proton
    echo "🔍 Analizzo le differenze tra i calendari..."
    find_new_events "$IMPORT_FILE" "$EXPORT_FILE" "$NEW_EVENTS_FILE"
    
    # Crea file temporanei per il confronto
    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)
    
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$IMPORT_FILE" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$EXPORT_FILE" | tr -d '\r' > "$calcurse_tmp"
    
    # Mappe per entrambe le direzioni
    declare -A proton_signatures
    declare -A calcurse_signatures
    declare -A proton_events
    declare -A calcurse_events
    
    local block="" in_event=0
    
    # Costruisci mappa Proton
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            
            local dtstart=$(echo "$block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | sed 's/[[:space:]]*$//')
            local summary=$(echo "$block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            local signature="${dtstart}|${summary}"
            
            proton_signatures["$signature"]=1
            proton_events["$signature"]="$block"
            
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"
    
    # Costruisci mappa Calcurse
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            
            local dtstart=$(echo "$block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | sed 's/[[:space:]]*$//')
            local summary=$(echo "$block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | sed 's/[[:space:]]*$//')
            local signature="${dtstart}|${summary}"
            
            calcurse_signatures["$signature"]=1
            calcurse_events["$signature"]="$block"
            
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"
    
    # Trova differenze in entrambe le direzioni
    local proton_only_count=0
    local calcurse_only_count=0
    
    # Sezione 1: Eventi in Proton ma non in Calcurse (da cancellare in Proton)
    echo "📋 EVENTI IN PROTON ASSENTI IN CALCURSE:" >> "$sync_report"
    echo "==========================================" >> "$sync_report"
    echo "" >> "$sync_report"
    
    for signature in "${!proton_signatures[@]}"; do
        if [[ -z "${calcurse_signatures[$signature]}" ]]; then
            local summary=$(echo "$signature" | cut -d'|' -f2)
            local dtstart=$(echo "$signature" | cut -d'|' -f1)
            local uid=$(echo "${proton_events[$signature]}" | grep "^UID:" | cut -d: -f2-)
            
            echo "🗑️  $summary" >> "$sync_report"
            echo "   Data/Ora: $dtstart" >> "$sync_report"
            echo "   UID: $uid" >> "$sync_report"
            echo "" >> "$sync_report"
            ((proton_only_count++))
            echo "➖ Rilevato in Proton ma non in Calcurse: $summary ($dtstart)"
        fi
    done
    
    if [[ $proton_only_count -eq 0 ]]; then
        echo "✅ Nessun evento da cancellare in Proton" >> "$sync_report"
        echo "" >> "$sync_report"
    fi
    
    # Sezione 2: Eventi in Calcurse ma non in Proton (da cancellare in Calcurse O da aggiungere a Proton)
    echo "" >> "$sync_report"
    echo "📋 EVENTI IN CALCURSE ASSENTI IN PROTON:" >> "$sync_report"
    echo "==========================================" >> "$sync_report"
    echo "" >> "$sync_report"
    
    for signature in "${!calcurse_signatures[@]}"; do
        if [[ -z "${proton_signatures[$signature]}" ]]; then
            local summary=$(echo "$signature" | cut -d'|' -f2)
            local dtstart=$(echo "$signature" | cut -d'|' -f1)
            local uid=$(echo "${calcurse_events[$signature]}" | grep "^UID:" | cut -d: -f2-)
            
            echo "❓ $summary" >> "$sync_report"
            echo "   Data/Ora: $dtstart" >> "$sync_report"
            echo "   UID: $uid" >> "$sync_report"
            echo "" >> "$sync_report"
            ((calcurse_only_count++))
            echo "➖ Rilevato in Calcurse ma non in Proton: $summary ($dtstart)"
        fi
    done
    
    if [[ $calcurse_only_count -eq 0 ]]; then
        echo "✅ Nessun evento da gestire in Calcurse" >> "$sync_report"
        echo "" >> "$sync_report"
    fi
    
    # Sezione 3: Istruzioni
    echo "" >> "$sync_report"
    echo "🎯 ISTRUZIONI PER LA SINCRONIZZAZIONE:" >> "$sync_report"
    echo "======================================" >> "$sync_report"
    echo "" >> "$sync_report"
    
    if [[ $proton_only_count -gt 0 ]]; then
        echo "1. CANCELLAZIONI IN PROTON:" >> "$sync_report"
        echo "   - Gli eventi elencati nella Sezione 1 sono presenti in Proton ma non in Calcurse." >> "$sync_report"
        echo "   - Se sono stati cancellati in Calcurse, cancellali anche in Proton." >> "$sync_report"
        echo "   - Le cancellazioni in Proton devono essere fatte MANUALMENTE via web interface." >> "$sync_report"
        echo "" >> "$sync_report"
    fi
    
    if [[ $calcurse_only_count -gt 0 ]]; then
        echo "2. GESTIONE EVENTI IN CALCURSE:" >> "$sync_report"
        echo "   - Gli eventi elencati nella Sezione 2 sono presenti in Calcurse ma non in Proton." >> "$sync_report"
        echo "   - OPZIONE A: Se sono stati cancellati in Proton, cancellali anche in Calcurse." >> "$sync_report"
        echo "   - OPZIONE B: Se sono nuovi eventi, importa il file '$NEW_EVENTS_FILE' in Proton." >> "$sync_report"
        echo "" >> "$sync_report"
    fi
    
    if [[ $proton_only_count -eq 0 && $calcurse_only_count -eq 0 ]]; then
        echo "✅ I calendari sono già perfettamente allineati!" >> "$sync_report"
    fi
    
    rm -f "$proton_tmp" "$calcurse_tmp"
    
    echo "✅ Report completo: $sync_report"
    echo "✅ File per Proton (eventi nuovi): $NEW_EVENTS_FILE"
    echo ""
    echo "📊 STATISTICHE:"
    echo "   - Eventi solo in Proton: $proton_only_count (da valutare per cancellazione)"
    echo "   - Eventi solo in Calcurse: $calcurse_only_count (da aggiungere a Proton O cancellare da Calcurse)"
    echo "   - File per importazione Proton: $NEW_EVENTS_FILE"
    echo ""
    echo "📖 CONSULTA IL REPORT:"
    echo "   - Leggi $sync_report per le istruzioni dettagliate"
    echo "   - Il report viene sovrascritto ad ogni esecuzione"
}

# ----------------------------------------------------------------------
# MENU INTERATTIVO
# ----------------------------------------------------------------------
echo "Scegli un'opzione:"
echo "A) Importa eventi da Proton (merge - SOLO aggiunte)"
echo "B) Sincronizza eventi con Proton (SOLO aggiunte)" 
echo "C) Sincronizza solo eventi futuri (30 giorni)"
echo "D) Sincronizza con intervallo personalizzato"
echo "---"
echo "E) 🔄 SYNC COMPLETA: Proton → Calcurse (SOSTITUISCE tutto)"
echo "F) 🧹 SYNC GUIDATA: Calcurse → Proton + lista pulizia"
read -rp "Inserisci A, B, C, D, E o F: " choice

case "${choice^^}" in
    A) option_A ;;
    B) option_B ;;
    C) option_C ;;
    D) option_D ;;
    E) option_E ;;
    F) option_F ;;
    *) die "Scelta non valida. Usa A, B, C, D, E o F." ;;
esac
