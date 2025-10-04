#!/usr/bin/env bash

# ----------------------------------------------------------------------
# CONFIGURAZIONE
# ----------------------------------------------------------------------
CALCURSE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/calcurse"
BACKUP_DIR="$HOME/Projects/calendar"
TODAY=$(date +%Y%m%d-%H%M%S)
TODAY_PROTON=$(date +%Y-%m-%d)

IMPORT_FILE="$BACKUP_DIR/calendar.ics"
EXPORT_FILE="$BACKUP_DIR/calendario.ics"
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

    proton_file=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "My calendar-*.ics" -o -name "My Calendar-*.ics" \) -type f | sort -r | head -n1)

    if [[ -n "$proton_file" ]]; then
        echo "📄 Trovato nuovo file Proton: $(basename "$proton_file")"
        mv "$proton_file" "$IMPORT_FILE"
        echo "✅ File rinominato in: $(basename "$IMPORT_FILE")"
    elif [[ -f "$IMPORT_FILE" ]]; then
        echo "📂 Uso file Proton esistente: $(basename "$IMPORT_FILE")"
    else
        die "Nessun file Proton trovato e $IMPORT_FILE non esiste"
    fi
}

# ----------------------------------------------------------------------
# FUNZIONI PER LA NORMALIZZAZIONE DEI PROMEMORIA
# ----------------------------------------------------------------------

convert_trigger_to_seconds() {
    local trigger="$1"
    local seconds=0

    trigger=$(echo "$trigger" | tr -d '[:space:]')

    if [[ $trigger =~ ^-P([0-9]+)D$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 86400 ))
    elif [[ $trigger =~ ^-P([0-9]+)DT([0-9]+)H$ ]]; then
        seconds=$(( (${BASH_REMATCH[1]} * 86400) + (${BASH_REMATCH[2]} * 3600) ))
    elif [[ $trigger =~ ^-P([0-9]+)DT([0-9]+)H([0-9]+)M$ ]]; then
        seconds=$(( (${BASH_REMATCH[1]} * 86400) + (${BASH_REMATCH[2]} * 3600) + (${BASH_REMATCH[3]} * 60) ))
    elif [[ $trigger =~ ^-P([0-9]+)S$ ]]; then
        seconds=${BASH_REMATCH[1]}
    elif [[ $trigger =~ ^-PT([0-9]+)M$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ $trigger =~ ^-PT([0-9]+)H$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ $trigger =~ ^-PT([0-9]+)H([0-9]+)M$ ]]; then
        seconds=$(( (${BASH_REMATCH[1]} * 3600) + (${BASH_REMATCH[2]} * 60) ))
    else
        seconds=0
    fi

    echo "$seconds"
}

convert_seconds_to_trigger() {
    local seconds=$1
    local target=$2

    if [ "$target" == "proton" ]; then
        local minutes=$(( (seconds + 30) / 60 ))

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
        echo "-P${seconds}S"
    fi
}

normalize_alarms() {
    local event_block="$1"
    local target_system="$2"

    if ! echo "$event_block" | grep -q "BEGIN:VALARM"; then
        echo "$event_block"
        return 0
    fi

    local result=""
    local in_alarm=0
    local in_event=0
    local alarm_count=0

    while IFS= read -r line; do
        case $line in
            "BEGIN:VEVENT")
                in_event=1
                result+="$line"$'\n'
                ;;
            "END:VEVENT")
                if [[ $in_alarm -eq 1 ]]; then
                    result+="END:VALARM"$'\n'
                    in_alarm=0
                fi
                in_event=0
                result+="$line"$'\n'
                ;;
            "BEGIN:VALARM"*)
                in_alarm=1
                alarm_count=$((alarm_count + 1))
                result+="BEGIN:VALARM"$'\n'

                local remaining_line="${line#BEGIN:VALARM}"
                if [[ -n "$remaining_line" ]]; then
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
                    if [[ "$target_system" == "proton" ]]; then
                        local event_summary=$(echo "$event_block" | grep "^SUMMARY:" | head -1 | cut -d: -f2-)
                        if [[ -n "$event_summary" ]]; then
                            result+="DESCRIPTION:$event_summary"$'\n'
                        fi
                    fi
                else
                    result+="$line"$'\n'
                fi
                ;;
            *)
                result+="$line"$'\n'
                ;;
        esac
    done < <(echo "$event_block")

    result="${result%$'\n'}"
    echo "$result"
}

# ----------------------------------------------------------------------
# FUNZIONI PER LA GESTIONE DEGLI UID
# ----------------------------------------------------------------------

generate_event_uid() {
    local event_block="$1"
    local source_system="$2"

    local dtstart=$(echo "$event_block" | grep "^DTSTART" | head -1 | sed 's/^DTSTART[^:]*://' | tr -d '\r\n')
    local summary=$(echo "$event_block" | grep "^SUMMARY:" | head -1 | cut -d: -f2- | tr -d '\r\n')
    local description=$(echo "$event_block" | grep "^DESCRIPTION:" | head -1 | cut -d: -f2- | tr -d '\r\n')
    local duration=$(echo "$event_block" | grep "^DURATION:" | head -1 | cut -d: -f2- | tr -d '\r\n')
    local dtend=$(echo "$event_block" | grep "^DTEND" | head -1 | sed 's/^DTEND[^:]*://' | tr -d '\r\n')

    local uid_base="${source_system}|${dtstart}|${summary}|${description}|${duration}|${dtend}"
    local uid_hash=$(echo -n "$uid_base" | sha256sum | cut -d' ' -f1 | head -c 16)

    echo "CALCURSE-${uid_hash}@$(hostname)"
}

export_calcurse_with_uids() {
    echo "📤 Esporto i miei eventi con UID in $EXPORT_FILE…"
    local temp_export=$(mktemp)
    calcurse -D "$CALCURSE_DIR" --export > "$temp_export" || die "Esportazione fallita"

    local in_event=0
    local event_block=""

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            event_block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            event_block+=$'\n'"$line"

            if ! echo "$event_block" | grep -q "^UID:"; then
                local uid=$(generate_event_uid "$event_block" "calcurse")
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
# FUNZIONE DI HASH EVENTO OTTIMIZZATA
# ----------------------------------------------------------------------
compute_event_hash() {
    local event_block="$1"
    
    local dtstart=$(echo "$event_block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
    local summary=$(echo "$event_block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
    local description=$(echo "$event_block" | grep -m1 "^DESCRIPTION:" | cut -d: -f2- | tr -d '\r\n')
    
    local duration_min=0
    if echo "$event_block" | grep -q "^DURATION:"; then
        local duration=$(echo "$event_block" | grep -m1 "^DURATION:" | cut -d: -f2-)
        if [[ $duration =~ P([0-9]+)DT([0-9]+)H([0-9]+)M ]]; then
            duration_min=$((${BASH_REMATCH[1]} * 1440 + ${BASH_REMATCH[2]} * 60 + ${BASH_REMATCH[3]}))
        fi
    elif echo "$event_block" | grep -q "^DTEND"; then
        duration_min=30
    fi
    
    local alarm_sig=""
    if echo "$event_block" | grep -q "BEGIN:VALARM"; then
        while IFS= read -r trigger_line; do
            local trigger=$(echo "$trigger_line" | cut -d: -f2-)
            local seconds=$(convert_trigger_to_seconds "$trigger")
            local rounded=$((seconds / 300 * 300))
            alarm_sig="${alarm_sig},${rounded}"
        done < <(echo "$event_block" | grep "^TRIGGER:")
        alarm_sig="${alarm_sig#,}"
    fi
    
    echo -n "${dtstart}|${summary}|${description}|${duration_min}|${alarm_sig}" | \
        sha256sum | cut -d' ' -f1 | head -c16
}

# ----------------------------------------------------------------------
# FUNZIONE DI CONFRONTO OTTIMIZZATA
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

    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$proton_file" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$calcurse_file" | tr -d '\r' > "$calcurse_tmp"

    declare -A proton_hashes
    declare -A proton_uids
    declare -A proton_summaries
    
    local block="" in_event=0 proton_count=0
    
    echo "📊 Indicizzazione eventi Proton..."
    
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            
            local hash=$(compute_event_hash "$block")
            proton_hashes["$hash"]=1
            
            local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n ')
            [[ -n "$uid" ]] && proton_uids["$uid"]=1
            
            local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
            [[ -n "$summary" ]] && proton_summaries["$summary"]="$dtstart"
            
            ((proton_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"

    echo "📊 Trovati $proton_count eventi nel file Proton"

    cat > "$out_tmp" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//calcurse-sync//Nuovi Eventi//
EOF

    local new_count=0
    block="" in_event=0
    
    echo "🔍 Ricerca nuovi eventi in Calcurse..."

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            
            local is_duplicate=0
            
            local hash=$(compute_event_hash "$block")
            if [[ -n "${proton_hashes[$hash]}" ]]; then
                is_duplicate=1
            else
                local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n ')
                if [[ -n "$uid" && -n "${proton_uids[$uid]}" ]]; then
                    is_duplicate=1
                else
                    local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
                    local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                    
                    if [[ -n "$summary" && -n "${proton_summaries[$summary]}" ]]; then
                        local proton_dtstart="${proton_summaries[$summary]}"
                        if [[ "${dtstart:0:8}" == "${proton_dtstart:0:8}" ]]; then
                            is_duplicate=1
                        fi
                    fi
                fi
            fi

            if [[ $is_duplicate -eq 0 ]]; then
                local normalized_event=$(normalize_alarms "$block" "proton")
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMTRIGGER/BEGIN:VALARM\nTRIGGER/g')
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMACTION/BEGIN:VALARM\nACTION/g')
                
                echo "$normalized_event" >> "$out_tmp"
                ((new_count++))
                local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
                local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                echo "➕ Nuovo evento: $summary ($dtstart)"
            fi

            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"

    echo "END:VCALENDAR" >> "$out_tmp"

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

    local temp_file=$(mktemp)
    local filtered_temp=$(mktemp)

    echo "BEGIN:VCALENDAR" > "$filtered_temp"
    echo "VERSION:2.0" >> "$filtered_temp"
    echo "PRODID:-//calcurse-sync//Filtro Temporale//" >> "$filtered_temp"

    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$input_file" | tr -d '\r' > "$temp_file"

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

            local include_event=0

            if [[ $has_rrule -eq 1 ]]; then
                include_event=1
            elif [[ -n "$dtstart" ]]; then
                if [[ "$dtstart_type" == "date" ]]; then
                    if [[ "$dtstart" -ge "$current_date" ]] && [[ "$dtstart" -le "$end_date" ]]; then
                        include_event=1
                    fi
                else
                    local event_date="${dtstart:0:8}"
                    if [[ "$event_date" -le "$end_date" ]]; then
                        if [[ "$event_date" -eq "$current_date" ]]; then
                            local event_time="${dtstart:9}"
                            local current_time=$(date +%H%M%S)
                            if [[ "$event_time" > "$current_time" ]]; then
                                include_event=1
                            fi
                        else
                            include_event=1
                        fi
                    fi
                fi
            else
                include_event=1
            fi

            if [[ $include_event -eq 1 ]]; then
                echo "$event_block" >> "$filtered_temp"
            fi

            in_event=0
            event_block=""
        elif [[ $in_event -eq 1 ]]; then
            event_block+=$'\n'"$line"

            if [[ "$line" =~ ^DTSTART ]]; then
                if [[ "$line" =~ VALUE=DATE ]]; then
                    dtstart=$(echo "$line" | cut -d: -f2 | tr -cd '0-9')
                    dtstart_type="date"
                elif [[ "$line" =~ T ]]; then
                    dtstart=$(echo "$line" | sed 's/^[^:]*://' | sed 's/Z$//' | sed 's/[^0-9T]//g')
                    dtstart_type="datetime"
                else
                    dtstart=$(echo "$line" | cut -d: -f2 | tr -cd '0-9')
                    dtstart_type="date"
                fi
            fi

            if [[ "$line" =~ ^RRULE: ]]; then
                has_rrule=1
            fi
        fi
    done < "$temp_file"

    echo "END:VCALENDAR" >> "$filtered_temp"

    sed '/^$/d' "$filtered_temp" > "$output_file"

    rm -f "$temp_file" "$filtered_temp"

    local filtered_count=$(grep -c "^BEGIN:VEVENT" "$output_file" 2>/dev/null || echo "0")
    echo "✅ Filtro completato: $filtered_count eventi nell'intervallo selezionato"
}

# ----------------------------------------------------------------------
# OPZIONE A OTTIMIZZATA
# ----------------------------------------------------------------------
option_A() {
    echo "➡️ Importa eventi da Proton (merge)"

    find_and_prepare_proton_file
    local proton_file="$IMPORT_FILE"

    echo "📄 Trovato: $(basename "$proton_file")"

    echo "💾 Backup in $BACKUP_FILE..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup fallito"

    local current_calcurse_export=$(mktemp)
    export_calcurse_with_uids
    cp "$EXPORT_FILE" "$current_calcurse_export"

    local proton_file_normalized=$(mktemp)
    echo "📄 Normalizzo i promemoria per Calcurse..."

    {
        local in_event=0
        local event_block=""

        while IFS= read -r line; do
            if [[ "$line" == "BEGIN:VEVENT" ]]; then
                in_event=1
                event_block="$line"
            elif [[ "$line" == "END:VEVENT" ]]; then
                event_block+=$'\n'"$line"
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

    echo "📄 Cerco nuovi eventi da Proton da importare in Calcurse..."

    local new_events_for_calcurse=$(mktemp)
    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)

    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$proton_file_normalized" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$current_calcurse_export" | tr -d '\r' > "$calcurse_tmp"

    declare -A calcurse_hashes
    declare -A calcurse_uids
    declare -A calcurse_summaries

    local block="" in_event=0

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            
            local hash=$(compute_event_hash "$block")
            calcurse_hashes["$hash"]=1
            
            local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n ')
            [[ -n "$uid" ]] && calcurse_uids["$uid"]=1
            
            local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
            [[ -n "$summary" ]] && calcurse_summaries["$summary"]="$dtstart"
            
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"

    local import_count=0
    block="" in_event=0

    echo "BEGIN:VCALENDAR" > "$new_events_for_calcurse"
    echo "VERSION:2.0" >> "$new_events_for_calcurse"
    echo "PRODID:-//calcurse-sync//Import da Proton//" >> "$new_events_for_calcurse"

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local should_import=1
            
            local hash=$(compute_event_hash "$block")
            if [[ -n "${calcurse_hashes[$hash]}" ]]; then
                should_import=0
            else
                local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n ')
                if [[ -n "$uid" && -n "${calcurse_uids[$uid]}" ]]; then
                    should_import=0
                else
                    local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
                    local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                    
                    if [[ -n "$summary" && -n "${calcurse_summaries[$summary]}" ]]; then
                        local calcurse_dtstart="${calcurse_summaries[$summary]}"
                        if [[ "${dtstart:0:8}" == "${calcurse_dtstart:0:8}" ]]; then
                            should_import=0
                        fi
                    fi
                fi
            fi

            if [[ $should_import -eq 1 ]]; then
                echo "$block" >> "$new_events_for_calcurse"
                ((import_count++))
                local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
                local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                echo "➕ Nuovo evento da importare: $summary ($dtstart)"
            fi

            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"

    echo "END:VCALENDAR" >> "$new_events_for_calcurse"

    if [[ $import_count -gt 0 ]]; then
        echo "📥 Importo $import_count nuovi eventi da Proton a Calcurse…"
        calcurse -D "$CALCURSE_DIR" -i "$new_events_for_calcurse" || die "Importazione fallita"

        echo "📄 Aggiorno il file di export con i nuovi eventi importati..."
        export_calcurse_with_uids
    else
        echo "✅ Nessun nuovo evento da importare da Proton"
    fi

    rm -f "$proton_file_normalized" "$current_calcurse_export" "$new_events_for_calcurse" "$proton_tmp" "$calcurse_tmp"

    clean_old_backups

    echo "✅ Importazione completata! Eventi aggiornati da Proton (merge)."
    echo "📂 Backup salvato: $BACKUP_FILE"
    echo "📂 Export aggiornato: $EXPORT_FILE"
    echo "📊 Eventi importati: $import_count"
}

option_B() {
    echo "➡️ Sincronizza tutti gli eventi con Proton"
    export_calcurse_with_uids
    find_and_prepare_proton_file
    find_new_events "$IMPORT_FILE" "$EXPORT_FILE" "$NEW_EVENTS_FILE"
    echo "📂 File per Proton: $NEW_EVENTS_FILE"
}

option_C() {
    echo "➡️ Sincronizza solo eventi futuri (30 giorni)"
    export_calcurse_with_uids
    find_and_prepare_proton_file

    local proton_filtered=$(mktemp)
    local calcurse_filtered=$(mktemp)

    filter_events_by_date "$IMPORT_FILE" "$proton_filtered" 30
    filter_events_by_date "$EXPORT_FILE" "$calcurse_filtered" 30

    find_new_events "$proton_filtered" "$calcurse_filtered" "$NEW_EVENTS_FILE"

    rm -f "$proton_filtered" "$calcurse_filtered"
    echo "📂 File per Proton (solo eventi futuri): $NEW_EVENTS_FILE"
}

option_D() {
    echo "➡️ Sincronizza con intervallo personalizzato"
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
    echo "📂 File per Proton (prossimi $days_future giorni): $NEW_EVENTS_FILE"
}

option_E() {
    echo "🔄 SYNC COMPLETA: Proton → Calcurse"
    echo "⚠️ ATTENZIONE: Questo sostituirà completamente Calcurse con Proton"
    echo "   Tutti gli eventi in Calcurse non presenti in Proton verranno PERDUTI!"

    read -rp "Sei sicuro? (scrivi 'CONFERMO' per procedere): " confirmation
    if [[ "$confirmation" != "CONFERMO" ]]; then
        echo "❌ Sincronizzazione annullata"
        return 1
    fi

    find_and_prepare_proton_file

    echo "💾 Backup in $BACKUP_FILE..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup fallito"

    echo "🗑️ Svuoto Calcurse..."
    > "$CALCURSE_DIR/apts"

    echo "📥 Importo tutto da Proton..."
    calcurse -D "$CALCURSE_DIR" -i "$IMPORT_FILE" || die "Importazione fallita"

    export_calcurse_with_uids
    clean_old_backups

    echo "✅ Sincronizzazione completa completata!"
    echo "📂 Backup salvato: $BACKUP_FILE"
}

option_F() {
    echo "🧹 SYNC GUIDATA: Report sincronizzazione bidirezionale"

    export_calcurse_with_uids
    find_and_prepare_proton_file

    local sync_report="$BACKUP_DIR/sync-report.txt"
    > "$sync_report"

    echo "🔍 Analizzo le differenze tra i calendari..."

    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)

    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$IMPORT_FILE" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$EXPORT_FILE" | tr -d '\r' > "$calcurse_tmp"

    local proton_file_count=$(grep -c "^BEGIN:VEVENT" "$proton_tmp" 2>/dev/null || echo "0")
    local calcurse_file_count=$(grep -c "^BEGIN:VEVENT" "$calcurse_tmp" 2>/dev/null || echo "0")
    
    echo "📊 File Proton contiene: $proton_file_count eventi"
    echo "📊 File Calcurse contiene: $calcurse_file_count eventi"

    declare -A proton_events
    
    local block="" 
    local in_event=0
    local proton_count=0

    echo "📊 Indicizzazione eventi Proton..."

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n')
            local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n')
            
            local key="${dtstart}"
            proton_events["$key"]="${summary}||${uid}"
            
            ((proton_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"

    echo "✅ Indicizzati $proton_count eventi da Proton"

    declare -A calcurse_events

    block=""
    in_event=0
    local calcurse_count=0

    echo "📊 Indicizzazione eventi Calcurse..."

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n')
            local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n')
            
            local key="${dtstart}"
            calcurse_events["$key"]="${summary}||${uid}"
            
            ((calcurse_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"

    echo "✅ Indicizzati $calcurse_count eventi da Calcurse"

    local proton_only_count=0
    local calcurse_only_count=0

    echo "🔍 Confronto eventi..."

    echo "📋 EVENTI IN PROTON ASSENTI IN CALCURSE:" >> "$sync_report"
    echo "==========================================" >> "$sync_report"
    echo "" >> "$sync_report"

    for key in "${!proton_events[@]}"; do
        if [[ -z "${calcurse_events[$key]}" ]]; then
            local dtstart="$key"
            IFS='||' read -r summary uid <<< "${proton_events[$key]}"

            echo "🗑️ ${summary:-[Senza titolo]}" >> "$sync_report"
            echo "   Data/Ora: $dtstart" >> "$sync_report"
            echo "   UID: $uid" >> "$sync_report"
            echo "" >> "$sync_report"
            ((proton_only_count++))
            echo "➖ In Proton ma non in Calcurse: ${summary:-[Senza titolo]} ($dtstart)"
        fi
    done

    if [[ $proton_only_count -eq 0 ]]; then
        echo "✅ Nessun evento da cancellare in Proton" >> "$sync_report"
        echo "" >> "$sync_report"
    fi

    echo "" >> "$sync_report"
    echo "📋 EVENTI IN CALCURSE ASSENTI IN PROTON:" >> "$sync_report"
    echo "==========================================" >> "$sync_report"
    echo "" >> "$sync_report"

    for key in "${!calcurse_events[@]}"; do
        if [[ -z "${proton_events[$key]}" ]]; then
            local dtstart="$key"
            IFS='||' read -r summary uid <<< "${calcurse_events[$key]}"

            echo "➕ ${summary:-[Senza titolo]}" >> "$sync_report"
            echo "   Data/Ora: $dtstart" >> "$sync_report"
            echo "   UID: $uid" >> "$sync_report"
            echo "" >> "$sync_report"
            ((calcurse_only_count++))
            echo "➕ In Calcurse ma non in Proton: ${summary:-[Senza titolo]} ($dtstart)"
        fi
    done

    if [[ $calcurse_only_count -eq 0 ]]; then
        echo "✅ Nessun evento da gestire in Calcurse" >> "$sync_report"
        echo "" >> "$sync_report"
    fi

    if [[ $calcurse_only_count -gt 0 ]]; then
        echo "📄 Genero file per importazione in Proton..."
        
        echo "BEGIN:VCALENDAR" > "$NEW_EVENTS_FILE"
        echo "VERSION:2.0" >> "$NEW_EVENTS_FILE"
        echo "PRODID:-//calcurse-sync//Nuovi Eventi//" >> "$NEW_EVENTS_FILE"
        
        block=""
        in_event=0
        
        while IFS= read -r line; do
            if [[ "$line" == "BEGIN:VEVENT" ]]; then
                block="$line"
                in_event=1
            elif [[ "$line" == "END:VEVENT" ]]; then
                block+=$'\n'"$line"
                
                local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n')
                local key="${dtstart}"
                
                if [[ -z "${proton_events[$key]}" ]]; then
                    local normalized=$(normalize_alarms "$block" "proton")
                    normalized=$(echo "$normalized" | sed 's/BEGIN:VALARMTRIGGER/BEGIN:VALARM\nTRIGGER/g')
                    normalized=$(echo "$normalized" | sed 's/BEGIN:VALARMACTION/BEGIN:VALARM\nACTION/g')
                    echo "$normalized" >> "$NEW_EVENTS_FILE"
                fi
                
                in_event=0
                block=""
            elif (( in_event )); then
                block+=$'\n'"$line"
            fi
        done < "$calcurse_tmp"
        
        echo "END:VCALENDAR" >> "$NEW_EVENTS_FILE"
        sed -i '/^$/d' "$NEW_EVENTS_FILE"
    else
        echo "BEGIN:VCALENDAR" > "$NEW_EVENTS_FILE"
        echo "VERSION:2.0" >> "$NEW_EVENTS_FILE"
        echo "PRODID:-//calcurse-sync//Nuovi Eventi//" >> "$NEW_EVENTS_FILE"
        echo "END:VCALENDAR" >> "$NEW_EVENTS_FILE"
    fi

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

    echo ""
    echo "✅ Report completo: $sync_report"
    echo "✅ File per Proton (eventi nuovi): $NEW_EVENTS_FILE"
    echo ""
    echo "📊 STATISTICHE:"
    echo "   - Eventi solo in Proton: $proton_only_count (da valutare per cancellazione)"
    echo "   - Eventi solo in Calcurse: $calcurse_only_count (da aggiungere a Proton o cancellare da Calcurse)"
    echo "   - File per importazione Proton: $NEW_EVENTS_FILE"
    echo ""
    echo "📖 CONSULTA IL REPORT:"
    echo "   - Leggi $sync_report per le istruzioni dettagliate"
    echo "   - Il report viene sovrascritto ad ogni esecuzione"
    echo ""
    
    read -rp "📖 Vuoi aprire adesso il report con Vim? (s/N): " open_report
    if [[ "$open_report" =~ ^[sSyY]$ ]]; then
        if command -v vim >/dev/null 2>&1; then
            vim "$sync_report"
        else
            echo "⚠️ Vim non trovato. Apri manualmente: $sync_report"
            echo "   Puoi usare: less '$sync_report' o cat '$sync_report'"
        fi
    else
        echo "📖 Per consultare il report in seguito:"
        echo "   vim '$sync_report'"
    fi
}

echo "🔔 RICORDA: Assicurati di avere scaricato il file AGGIORNATO da Proton Calendar"
echo "Scegli un'opzione:"
echo "A) Importa eventi da Proton (merge - SOLO aggiunte)"
echo "B) Sincronizza eventi con Proton (SOLO aggiunte)"
echo "C) Sincronizza solo eventi futuri (30 giorni)"
echo "D) Sincronizza con intervallo personalizzato"
echo "---------"
echo "E) 🧹 SYNC BIDIREZIONALE GUIDATA: Calcurse ↔ Proton + report"
echo "F) 🔄 SYNC COMPLETA: Proton → Calcurse (SOSTITUISCE tutto)"
echo "---------"
echo "Q) ❌ Esci senza operazioni"
echo ""

while true; do
    read -rp "Inserisci A, B, C, D, E, F o Q: " choice

    case "${choice^^}" in
        A) option_A; break ;;
        B) option_B; break ;;
        C) option_C; break ;;
        D) option_D; break ;;
        E) option_F; break ;;
        F) option_E; break ;;
        Q) echo "👋 Arrivederci!"; exit 0 ;;
        *) echo "❌ Errore: Scelta non valida. Usa A, B, C, D, E, F o Q." ;;
    esac
done
