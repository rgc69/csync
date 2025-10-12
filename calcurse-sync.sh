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
    local backup_files=("$BACKUP_DIR"/backup_*.ics)
    if [[ ${#backup_files[@]} -gt 3 ]]; then
        for file in $(ls -1 "$BACKUP_DIR"/backup_*.ics | sort | head -n -3); do
            rm -- "$file"
        done
    fi
}

# ----------------------------------------------------------------------
# FUNZIONE GESTIONE FILE PROTON
# ----------------------------------------------------------------------
find_and_prepare_proton_file() {
    local proton_file

    proton_file=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "My calendar-*.ics" -o -name "My Calendar-*.ics" \) -type f | sort -r | head -n1)

    if [[ -n "$proton_file" ]]; then
        mv "$proton_file" "$IMPORT_FILE"
    elif [[ -f "$IMPORT_FILE" ]]; then
        :
    else
        die "No Proton file found and $IMPORT_FILE does not exist"
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
# PULIZIA RRULE PER COMPATIBILITÀ PROTON
# ----------------------------------------------------------------------

clean_rrule_for_proton() {
    local rrule="$1"


    # Rimuovi elementi non supportati da Proton
    if [[ "$rrule" =~ FREQ=WEEKLY ]]; then
        # Per ricorrenze settimanali, rimuovi BYMONTH
        rrule=$(echo "$rrule" | sed 's/;BYMONTH=[0-9]*//g' | sed 's/BYMONTH=[0-9]*;//g')
    fi

    # Rimuovi BYSETPOS (non supportato)
    rrule=$(echo "$rrule" | sed 's/;BYSETPOS=[^;]*//g' | sed 's/BYSETPOS=[^;]*;//g')

    # Rimuovi BYSECOND, BYMINUTE, BYHOUR (non supportati)
    rrule=$(echo "$rrule" | sed 's/;BY\(SECOND\|MINUTE\|HOUR\)=[^;]*//g')

    # Rimuovi WKST (ignorato da Proton comunque)
    rrule=$(echo "$rrule" | sed 's/;WKST=[^;]*//g' | sed 's/WKST=[^;]*;//g')

    echo "$rrule"
}

# ----------------------------------------------------------------------
# ARRICCHIMENTO EVENTI PER COMPATIBILITÀ PROTON
# ----------------------------------------------------------------------
enrich_event_for_proton() {
    local event_block="$1"
    local user_tz="${TZ:-Europe/Rome}"
    local result=""
    local has_dtstamp=0
    local has_sequence=0
    local dtstart="" dtend="" duration=""

    # Prima passata: leggi e converti DURATION -> DTEND
    while IFS= read -r line; do
        if [[ "$line" =~ ^DTSTART:(.+) ]]; then
            dtstart="${BASH_REMATCH[1]}"
            result+="DTSTART;TZID=$user_tz:$dtstart"$'\n'
        elif [[ "$line" =~ ^DURATION:(.+) ]]; then
            duration="${BASH_REMATCH[1]}"
            # Calcola DTEND (parsing semplificato)
            local hours=0 minutes=0
            [[ "$duration" =~ ([0-9]+)H ]] && hours=${BASH_REMATCH[1]}
            [[ "$duration" =~ ([0-9]+)M ]] && minutes=${BASH_REMATCH[1]}

            local total_minutes=$((hours * 60 + minutes))
            local start_hour=${dtstart:9:2}
            local start_min=${dtstart:11:2}
            local end_minutes=$((10#$start_hour * 60 + 10#$start_min + total_minutes))
            local end_hour=$((end_minutes / 60))
            local end_min=$((end_minutes % 60))

            dtend=$(printf "%s%02d%02d00" "${dtstart:0:9}" $end_hour $end_min)
            result+="DTEND;TZID=$user_tz:$dtend"$'\n'
        elif [[ "$line" =~ ^UID: ]]; then
            result+="$line"$'\n'
            if [[ $has_dtstamp -eq 0 ]]; then
                result+="DTSTAMP:$(date -u +%Y%m%dT%H%M%SZ)"$'\n'
                has_dtstamp=1
            fi
        elif [[ "$line" == "BEGIN:VALARM" || "$line" == "END:VEVENT" ]]; then
            if [[ $has_sequence -eq 0 ]]; then
                result+="SEQUENCE:0"$'\n'
                result+="STATUS:CONFIRMED"$'\n'
                has_sequence=1
            fi
            result+="$line"$'\n'
        else
            [[ "$line" =~ ^DTSTAMP: ]] && has_dtstamp=1
            [[ "$line" =~ ^SEQUENCE: ]] && has_sequence=1
            result+="$line"$'\n'
        fi
    done < <(echo "$event_block")

    echo "${result%$'\n'}"
}

# ----------------------------------------------------------------------
# CONTROLLO SE SYNC EXPORT NECESSARIA (solo per C/D/E)
# ----------------------------------------------------------------------
check_if_export_needed() {
    local last_export_file="$BACKUP_DIR/.last_calcurse_export"

    # Controlla il database Calcurse, non l'export
    local calcurse_db="$CALCURSE_DIR/apts"

    if [[ ! -f "$calcurse_db" ]]; then
        echo "⚠️  Calcurse database not found"
        return 0
    fi

    # Se non esiste timestamp precedente, export necessario
    if [[ ! -f "$last_export_file" ]]; then
        return 0
    fi

    local last_export=$(cat "$last_export_file")
    local calcurse_mtime=$(stat -c %Y "$calcurse_db" 2>/dev/null || stat -f %m "$calcurse_db" 2>/dev/null)

    # Se il database Calcurse NON è cambiato dall'ultimo export
    if [[ $calcurse_mtime -le $last_export ]]; then
        echo ""
        echo "ℹ️  No changes in Calcurse since last export"
        echo "   Last export: $(date -d @$last_export '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $last_export '+%Y-%m-%d %H:%M:%S')"
        echo "   Calcurse DB last modified: $(date -d @$calcurse_mtime '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $calcurse_mtime '+%Y-%m-%d %H:%M:%S')"
        echo ""
        read -rp "   Continue export anyway? (y/N): " proceed

        if [[ ! "$proceed" =~ ^[yY]$ ]]; then
            return 1
        fi
    fi

    return 0
}

save_export_timestamp() {
    echo "$(date +%s)" > "$BACKUP_DIR/.last_calcurse_export"
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
   # echo "📤 Esporto i miei eventi con UID in $EXPORT_FILE…"
    local temp_export=$(mktemp)
    calcurse -D "$CALCURSE_DIR" --export > "$temp_export" || die "Export failed"

    # Leggi notification.warning dalla configurazione Calcurse
    local notification_warning=""
    local conf_paths=(
        "${XDG_CONFIG_HOME:-$HOME/.config}/calcurse/conf"
        "$HOME/.calcurse/conf"
        "$CALCURSE_DIR/../conf"
    )

    for conf_path in "${conf_paths[@]}"; do
        if [[ -f "$conf_path" ]]; then
            notification_warning=$(grep "^notification.warning=" "$conf_path" 2>/dev/null | cut -d= -f2)
            if [[ -n "$notification_warning" ]]; then
                break
            fi
        fi
    done

    # Default a 900 se non trovato
    notification_warning=${notification_warning:-900}

    local in_event=0
    local event_block=""
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            event_block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            event_block+=$'\n'"$line"

            # Sostituisci -P300S con il valore configurato
            event_block=$(echo "$event_block" | sed "s/TRIGGER:-P300S/TRIGGER:-P${notification_warning}S/g")

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
    [[ -s "$EXPORT_FILE" ]] # && echo "✅ Esportazione con UID completata"
}

# ----------------------------------------------------------------------
# FUNZIONE DI NORMALIZZAZIONE RRULE
# ----------------------------------------------------------------------
normalize_rrule_for_comparison() {
    local rrule="$1"
    
    # Se vuoto, ritorna vuoto
    [[ -z "$rrule" ]] && return
    
    # Rimuovi BYMONTH (problema noto)
    rrule=$(echo "$rrule" | sed 's/;BYMONTH=[0-9]*//g' | sed 's/BYMONTH=[0-9]*;//g')
    
    # Normalizza UNTIL a solo data (ignora orario e Z)
    rrule=$(echo "$rrule" | sed -E 's/UNTIL=[0-9]{8}T[0-9]{6}Z?/UNTIL=NORM/g')
    
    # Estrai i componenti e ordina alfabeticamente
    local freq="" byday="" bymonthday="" bymonth="" until="" interval="" count="" wkst=""
    
    IFS=';' read -ra components <<< "$rrule"
    for component in "${components[@]}"; do
        case "$component" in
            FREQ=*) freq="$component" ;;
            BYDAY=*) byday="$component" ;;
            BYMONTHDAY=*) bymonthday="$component" ;;
            BYMONTH=*) bymonth="$component" ;;
            UNTIL=*) until="$component" ;;
            INTERVAL=*) interval="$component" ;;
            COUNT=*) count="$component" ;;
            WKST=*) wkst="$component" ;;
        esac
    done
    
    # Ricostruisci in ordine standard: FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH
    local normalized=""
    [[ -n "$freq" ]] && normalized="${normalized}${freq};"
    [[ -n "$interval" ]] && normalized="${normalized}${interval};"
    [[ -n "$count" ]] && normalized="${normalized}${count};"
    [[ -n "$until" ]] && normalized="${normalized}${until};"
    [[ -n "$byday" ]] && normalized="${normalized}${byday};"
    [[ -n "$bymonthday" ]] && normalized="${normalized}${bymonthday};"
    [[ -n "$bymonth" ]] && normalized="${normalized}${bymonth};"
    [[ -n "$wkst" ]] && normalized="${normalized}${wkst};"
    
    # Rimuovi ultimo ";"
    normalized="${normalized%;}"
    
    echo "$normalized"
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


    echo "🔍 Comparing .ics files to find new events… "

    [[ -f "$proton_file" ]]   || die "Proton file not found: $proton_file"
    [[ -f "$calcurse_file" ]] || die "Calcurse file not found: $calcurse_file"

    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)
    local out_tmp=$(mktemp)

    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$proton_file" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$calcurse_file" | tr -d '\r' > "$calcurse_tmp"


    declare -A proton_hashes
    declare -A proton_uids
    declare -A proton_summaries

    local block="" in_event=0 proton_count=0

    #echo "📊 Indicizzazione eventi Proton..."

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

    # echo "📊 Trovati $proton_count eventi nel file Proton"

    cat > "$out_tmp" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//calcurse-sync//Nuovi Eventi//
EOF

    local new_count=0
    block="" in_event=0

   # echo "🔍 Ricerca nuovi eventi in Calcurse..."

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
                local enriched_block=$(enrich_event_for_proton "$block")
                local cleaned_block=""
                while IFS= read -r line; do
                    if [[ "$line" =~ ^RRULE: ]]; then
                        local rrule="${line#RRULE:}"
                        local cleaned_rrule=$(clean_rrule_for_proton "$rrule")
                        cleaned_block+="RRULE:$cleaned_rrule"$'\n'
                    else
                        cleaned_block+="$line"$'\n'
                    fi
                done < <(echo "$enriched_block")

                local normalized_event=$(normalize_alarms "$cleaned_block" "proton")
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMTRIGGER/BEGIN:VALARM\nTRIGGER/g')
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMACTION/BEGIN:VALARM\nACTION/g')

                echo "$normalized_event" >> "$out_tmp"
                ((new_count++))
                local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
                local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                echo "➕ New event: $summary ($dtstart)"
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

   # echo "✅ Trovati $new_count nuovi eventi genuini in $output_file"
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

   # echo "📅 Filtro eventi da oggi a $end_date"

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
   # echo "✅ Filtro completato: $filtered_count eventi nell'intervallo selezionato"
}

# ----------------------------------------------------------------------
# OPZIONE A OTTIMIZZATA
# ----------------------------------------------------------------------
option_A() {
    echo "🔄 INTERACTIVE BIDIRECTIONAL SYNC: Calcurse ↔ Proton"

    export_calcurse_with_uids

    # ============================================================
    # CONTROLLO FRESHNESS DEL FILE PROTON
    # ============================================================

    # Cerca file Proton PRIMA di chiamare find_and_prepare_proton_file
    local fresh_proton_file=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "My calendar-*.ics" -o -name "My Calendar-*.ics" \) -type f | sort -r | head -n1)

    # Ora prepara il file (rinomina se necessario)
    find_and_prepare_proton_file

    # Se NON è stato trovato un file My Calendar-*.ics, significa che stiamo usando calendar.ics esistente
    if [[ -z "$fresh_proton_file" ]]; then
        # Caso 3: Nessun file fresco trovato, usando calendar.ics esistente
        echo ""
        echo "⚠️  WARNING: Using existing 'calendar.ics' file"
        echo "    This file may have been used in a previous sync."
        echo "    For best results, download a fresh calendar from Proton:"
        echo "    Proton Calendar → Settings → Export → Download as .ics"
        echo ""
        read -rp "    Do you want to continue anyway? (y/N): " continue_old

        if [[ ! "$continue_old" =~ ^[yY]$ ]]; then
            echo "❌ Sync cancelled. Please download a fresh calendar from Proton."
            return 1
        fi
        echo ""
    else
        # Caso 1 e 2: File My Calendar-... trovato, controlla timestamp
        local file_timestamp=$(stat -c %Y "$IMPORT_FILE" 2>/dev/null || stat -f %m "$IMPORT_FILE" 2>/dev/null)
        local current_timestamp=$(date +%s)
        local age_seconds=$((current_timestamp - file_timestamp))
        local age_hours=$((age_seconds / 3600))

        if [[ $age_seconds -gt 10800 ]]; then
            # Caso 2: File più vecchio di 3 ore (10800 secondi)
            echo ""
            echo "⚠️  WARNING: Proton calendar file is older than 3 hours"
            echo "    File age: approximately $age_hours hours"
            echo "    Last modified: $(date -r "$IMPORT_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$IMPORT_FILE" 2>/dev/null)"
            echo ""
            echo "    For accurate synchronization, it's recommended to download"
            echo "    a fresh calendar from Proton Calendar before syncing."
            echo ""
            read -rp "    Do you want to continue anyway? (y/N): " continue_old

            if [[ ! "$continue_old" =~ ^[yY]$ ]]; then
                echo "❌ Sync cancelled. Please download a fresh calendar from Proton."
                return 1
            fi
            echo ""
        fi
        # Caso 1: File recente (< 3 ore), procedi normalmente senza warning
    fi

    # ============================================================

   # local sync_report="$BACKUP_DIR/sync-report.txt"
   # > "$sync_report"

   # echo "🔍 Analizzo le differenze tra i calendari..."

    local proton_tmp=$(mktemp)
    local calcurse_tmp=$(mktemp)

    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$IMPORT_FILE" | tr -d '\r' > "$proton_tmp"
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$EXPORT_FILE" | tr -d '\r' > "$calcurse_tmp"

    local proton_file_count=$(grep -c "^BEGIN:VEVENT" "$proton_tmp" 2>/dev/null || echo "0")
    local calcurse_file_count=$(grep -c "^BEGIN:VEVENT" "$calcurse_tmp" 2>/dev/null || echo "0")

   # echo "📊 File Proton contiene: $proton_file_count eventi"
   # echo "📊 File Calcurse contiene: $calcurse_file_count eventi"

    # Indicizzazione Proton
    declare -A proton_events
    declare -A proton_blocks

    local block=""
    local in_event=0
    local proton_count=0

   # echo "📊 Indicizzazione eventi Proton..."

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
            # Normalizza DTSTART: rimuovi TZID e altri parametri, solo data/ora
            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n' | tr -d 'Z')
            local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n')

            # Normalizza RRULE usando la funzione dedicata
            local rrule=$(echo "$block" | grep -m1 "^RRULE:" | cut -d: -f2- | tr -d '\r\n')
            rrule=$(normalize_rrule_for_comparison "$rrule")
            
            local key="${dtstart}||${rrule}"  # Chiave composta normalizzata

            proton_events["$key"]="${summary}||${uid}"
            proton_blocks["$key"]="$block"

            ((proton_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"

    # echo "✅ Indicizzati $proton_count eventi da Proton"

    # Indicizzazione Calcurse
    declare -A calcurse_events
    declare -A calcurse_blocks

    block=""
    in_event=0
    local calcurse_count=0

    #echo "📊 Indicizzazione eventi Calcurse..."

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local summary=$(echo "$block" | grep -m1 "^SUMMARY:" | cut -d: -f2- | tr -d '\r\n')
            # Normalizza DTSTART: rimuovi TZID e altri parametri, solo data/ora
            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n' | tr -d 'Z')
            local uid=$(echo "$block" | grep -m1 "^UID:" | cut -d: -f2- | tr -d '\r\n')

            # Normalizza RRULE usando la funzione dedicata
            local rrule=$(echo "$block" | grep -m1 "^RRULE:" | cut -d: -f2- | tr -d '\r\n')
            rrule=$(normalize_rrule_for_comparison "$rrule")
            
            local key="${dtstart}||${rrule}"  # Chiave composta normalizzata

            calcurse_events["$key"]="${summary}||${uid}"
            calcurse_blocks["$key"]="$block"

            ((calcurse_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$calcurse_tmp"

    #echo "✅ Indicizzati $calcurse_count eventi da Calcurse"
    echo ""

    # Array per tracciare le decisioni
    declare -a events_to_import_to_calcurse
    declare -a events_to_delete_from_calcurse
    declare -a events_to_export_to_proton

    # ============================================================
    # NUOVO: Controllo EXDATE per eventi ricorrenti
    # ============================================================
    declare -A exdate_conflicts
    local exdate_conflict_count=0
    
    # Confronta EXDATE per tutti gli eventi con stessa chiave (DTSTART+RRULE)
    # anche se hanno UID diversi
    for key in "${!proton_events[@]}"; do
        # Se l'evento esiste in entrambi i calendari (stessa chiave)
        if [[ -n "${calcurse_events[$key]}" ]]; then
            # Estrai EXDATE da entrambi i blocchi
            local proton_block="${proton_blocks[$key]}"
            local calcurse_block="${calcurse_blocks[$key]}"
            
            # Estrai tutti gli EXDATE (possono essere su righe multiple)
            # e normalizza: rimuovi TZID, spazi, estrai solo le date
            local proton_exdate=""
            while IFS= read -r line; do
                # Estrai solo la data/ora dopo i due punti, rimuovi TZID
                local date_part=$(echo "$line" | sed 's/^EXDATE[^:]*://' | tr -d '\r\n ' | sed 's/;TZID=[^:]*://')
                [[ -n "$date_part" ]] && proton_exdate="${proton_exdate},${date_part}"
            done < <(echo "$proton_block" | grep "^EXDATE")
            proton_exdate="${proton_exdate#,}"  # Rimuovi virgola iniziale
            
            local calcurse_exdate=""
            while IFS= read -r line; do
                local date_part=$(echo "$line" | sed 's/^EXDATE[^:]*://' | tr -d '\r\n ' | sed 's/;TZID=[^:]*://')
                [[ -n "$date_part" ]] && calcurse_exdate="${calcurse_exdate},${date_part}"
            done < <(echo "$calcurse_block" | grep "^EXDATE")
            calcurse_exdate="${calcurse_exdate#,}"  # Rimuovi virgola iniziale
            
            # Ordina le date per confronto consistente
            if [[ -n "$proton_exdate" ]]; then
                proton_exdate=$(echo "$proton_exdate" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
            fi
            if [[ -n "$calcurse_exdate" ]]; then
                calcurse_exdate=$(echo "$calcurse_exdate" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
            fi
            
            # Se EXDATE sono diversi, segnala conflitto
            if [[ "$proton_exdate" != "$calcurse_exdate" ]]; then
                exdate_conflicts["$key"]="$proton_exdate||$calcurse_exdate"
                ((exdate_conflict_count++))
            fi
        fi
    done
    
    # Mostra conflitti EXDATE all'utente
    if [[ $exdate_conflict_count -gt 0 ]]; then
        echo "⚠️  Found $exdate_conflict_count recurring event(s) with different exclusions (EXDATE)"
        echo ""
        
        for key in "${!exdate_conflicts[@]}"; do
            IFS='||' read -r proton_exdate calcurse_exdate <<< "${exdate_conflicts[$key]}"
            
            # Recupera informazioni sull'evento
            IFS='||' read -r summary proton_uid <<< "${proton_events[$key]}"
            IFS='||' read -r _ calcurse_uid <<< "${calcurse_events[$key]}"
            
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "⚠️  Recurring event with different exclusions:"
            echo "   📝 Title: ${summary:-[No title]}"
            echo "   📅 Date/Time: $key"
            echo "   🆔 Proton UID: $proton_uid"
            echo "   🆔 Calcurse UID: $calcurse_uid"
            echo ""
            echo "   📅 Excluded dates in Proton:"
            if [[ -n "$proton_exdate" ]]; then
                echo "$proton_exdate" | tr ',' '\n' | sed 's/^/      /'
            else
                echo "      (none)"
            fi
            echo ""
            echo "   📅 Excluded dates in Calcurse:"
            if [[ -n "$calcurse_exdate" ]]; then
                echo "$calcurse_exdate" | tr ',' '\n' | sed 's/^/      /'
            else
                echo "      (none)"
            fi
            echo ""
            echo "   What do you want to do?"
            echo "   P) Use Proton version (update Calcurse with Proton's exclusions)"
            echo "   C) Use Calcurse version (update Proton with Calcurse's exclusions)"
            echo "   S) Skip (leave both as is)"
            echo ""
            read -rp "   Choice (P/C/S): " exdate_choice
            
            case "${exdate_choice^^}" in
                P)
                    # Importa la versione Proton in Calcurse (sostituisce quella esistente)
                    events_to_import_to_calcurse+=("$key")
                    events_to_delete_from_calcurse+=("$key")
                    echo "   ✅ Will update Calcurse with Proton's exclusions"
                    ;;
                C)
                    # Esporta la versione Calcurse in Proton
                    events_to_export_to_proton+=("$key")
                    echo "   ✅ Will update Proton with Calcurse's exclusions"
                    ;;
                *)
                    echo "   ⏭️  Skipped (no changes)"
                    ;;
            esac
        done
        echo ""
    fi
    # ============================================================

    # Confronto: eventi in Proton ma non in Calcurse
    local proton_only_count=0
    echo "🔍 Checking events present only in Proton..."

    for key in "${!proton_events[@]}"; do
        if [[ -z "${calcurse_events[$key]}" ]]; then
            IFS='||' read -r summary uid <<< "${proton_events[$key]}"
            ((proton_only_count++))

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "📍 Event #$proton_only_count present in Proton but not in Calcurse:"
            echo "   📝 Title: ${summary:-[Senza titolo]}"
            echo "   📅 Date/Time: $key"
            echo "   🆔 UID: $uid"
            echo ""
            read -rp "   ➡️  Do you want to import it into Calcurse? (y/N): " import_choice

            if [[ "$import_choice" =~ ^[sSyY]$ ]]; then
                events_to_import_to_calcurse+=("$key")
                echo "   ✅ It will be imported in Calcurse"
            else
                echo "   ⏭️  Skipped (remains only in Proton)"
            fi
        fi
    done

    # Confronto: eventi in Calcurse ma non in Proton
    local calcurse_only_count=0
    echo ""
    #echo "🔍 Verifico eventi presenti solo in Calcurse..."

    for key in "${!calcurse_events[@]}"; do
        if [[ -z "${proton_events[$key]}" ]]; then
            IFS='||' read -r summary uid <<< "${calcurse_events[$key]}"
            ((calcurse_only_count++))

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "📍 Event #$calcurse_only_count present in Calcurse but not in Proton:"
            echo "   📝 Title: ${summary:-[Senza titolo]}"
            echo "   📅 Date/Time: $key"
            echo "   🆔 UID: $uid"
            echo ""
            echo "   What do you want to do?"
            echo "   A) 🗑️  Delete it from Calcurse (it was already deleted in Proton)"
            echo "   B) ➕ Keep it and add it to Proton"
            echo "   C) ⏭️  Skip (leave as is, no changes)"
            echo ""
            read -rp "   Choice (A/B/C): " choice

            case "${choice^^}" in
                A)
                    events_to_delete_from_calcurse+=("$key")
                    echo "   ✅ It will be deleted from Calcurse"
                    ;;
                B)
                    events_to_export_to_proton+=("$key")
                    echo "   ✅ It will be added to Proton"
                    ;;
                *)
                  echo "   ⏭️  Skipped (no changes)"
                    ;;
            esac
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Riepilogo decisioni
    if [[ ${#events_to_import_to_calcurse[@]} -eq 0 ]] && \
       [[ ${#events_to_delete_from_calcurse[@]} -eq 0 ]] && \
       [[ ${#events_to_export_to_proton[@]} -eq 0 ]]; then
        echo "✅ No changes to apply. The calendars are synchronized!"
        rm -f "$proton_tmp" "$calcurse_tmp"
        return 0
    fi

    echo "📋 Summary of changes:"
    echo ""

    if [[ ${#events_to_import_to_calcurse[@]} -gt 0 ]]; then
        echo "📥 Events to import into Calcurse: ${#events_to_import_to_calcurse[@]}"
        for key in "${events_to_import_to_calcurse[@]}"; do
            IFS='||' read -r summary uid <<< "${proton_events[$key]}"
            local dtstart_display="${key%%::*}"
            echo "   • ${summary:-[Senza titolo]} ($dtstart_display)"
        done
        echo ""
    fi

    if [[ ${#events_to_delete_from_calcurse[@]} -gt 0 ]]; then
        echo "🗑️  Events to delete from Calcurse: ${#events_to_delete_from_calcurse[@]}"
        for key in "${events_to_delete_from_calcurse[@]}"; do
            IFS='||' read -r summary uid <<< "${calcurse_events[$key]}"
            local dtstart_display="${key%%::*}"
            echo "   • ${summary:-[Senza titolo]} ($dtstart_display)"
        done
        echo ""
    fi

    if [[ ${#events_to_export_to_proton[@]} -gt 0 ]]; then
        echo "📤 Events to export to Proton: ${#events_to_export_to_proton[@]}"
        for key in "${events_to_export_to_proton[@]}"; do
            IFS='||' read -r summary uid <<< "${calcurse_events[$key]}"
            local dtstart_display="${key%%::*}"
            echo "   • ${summary:-[Senza titolo]} ($dtstart_display)"
        done
        echo ""
    fi

    read -rp "Do you confirm applying these changes? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[sSyY]$ ]]; then
        echo "❌ Operation cancelled by the user"
        rm -f "$proton_tmp" "$calcurse_tmp"
        return 1
    fi

    # Backup prima delle modifiche
    echo ""
    echo "💾 Creating backup..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup failed"
    echo "✅ Backup saved: $BACKUP_FILE"

    # FASE 1: Importa eventi da Proton a Calcurse
    if [[ ${#events_to_import_to_calcurse[@]} -gt 0 ]]; then
        echo ""
        echo "📥 Importing ${#events_to_import_to_calcurse[@]} events form Proton to Calcurse..."

        local import_temp=$(mktemp)
        echo "BEGIN:VCALENDAR" > "$import_temp"
        echo "VERSION:2.0" >> "$import_temp"
        echo "PRODID:-//calcurse-sync//Import da Proton//" >> "$import_temp"

        for key in "${events_to_import_to_calcurse[@]}"; do
            local normalized=$(normalize_alarms "${proton_blocks[$key]}" "calcurse")
            echo "$normalized" >> "$import_temp"
        done

        echo "END:VCALENDAR" >> "$import_temp"

        calcurse -D "$CALCURSE_DIR" -i "$import_temp" || die "Import failed"
        rm -f "$import_temp"
        echo "✅ Import completed"
    fi

    # FASE 2: Elimina eventi da Calcurse (tramite re-import filtrato)
if [[ ${#events_to_delete_from_calcurse[@]} -gt 0 ]]; then
    echo ""
    echo "🗑️  Deleting ${#events_to_delete_from_calcurse[@]} events from Calcurse..."

    declare -A to_delete
    #echo "DEBUG: Chiavi da eliminare:"
    for key in "${events_to_delete_from_calcurse[@]}"; do
        to_delete["$key"]=1
        echo "  -> [$key]"
    done

    # Esporta SOLO appuntamenti (no TODO)
    local current_export=$(mktemp)
    calcurse -D "$CALCURSE_DIR" --export --export-uid | \
        awk '/^BEGIN:VTODO/,/^END:VTODO/ {next} 1' > "$current_export"

    local filtered_temp=$(mktemp)
    echo "BEGIN:VCALENDAR" > "$filtered_temp"
    echo "VERSION:2.0" >> "$filtered_temp"
    echo "PRODID:-//calcurse-sync//Filtered//" >> "$filtered_temp"

    block=""
    in_event=0
    local event_count=0
    local kept_count=0
    local deleted_count=0

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"
            ((event_count++))

            local dtstart=$(echo "$block" | grep -m1 "^DTSTART" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n')
            local rrule=$(echo "$block" | grep -m1 "^RRULE:" | cut -d: -f2- | tr -d '\r\n')
            local key="${dtstart}||${rrule}"

            #echo "DEBUG: Evento #$event_count - Chiave estratta: [$key]"

            # Includi solo se NON è nella lista da eliminare
            if [[ -z "${to_delete[$key]}" ]]; then
                echo "$block" >> "$filtered_temp"
                ((kept_count++))
                echo "  -> MANTENUTO"
            else
                ((deleted_count++))
                echo "  -> ELIMINATO"
            fi

            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$current_export"

    echo "END:VCALENDAR" >> "$filtered_temp"

    echo ""
    echo "Processing summary:"
    echo "  - Total events processed: $event_count"
    echo "  - Events kept: $kept_count"
    echo "  - Events deleted: $deleted_count"
    echo ""

    # SVUOTA COMPLETAMENTE la directory Calcurse
    rm -f "$CALCURSE_DIR/apts"

    # Re-importa il contenuto filtrato
    calcurse -D "$CALCURSE_DIR" -i "$filtered_temp" || die "Eliminazione fallita"

    rm -f "$current_export" "$filtered_temp"
    echo "✅ Deletion completed"
fi

    # FASE 3: Genera file per export a Proton
    if [[ ${#events_to_export_to_proton[@]} -gt 0 ]]; then
        echo ""
        echo "📤 Generating file for import into Proton..."

        echo "BEGIN:VCALENDAR" > "$NEW_EVENTS_FILE"
        echo "VERSION:2.0" >> "$NEW_EVENTS_FILE"
        echo "PRODID:-//calcurse-sync//Export to Proton//" >> "$NEW_EVENTS_FILE"

        for key in "${events_to_export_to_proton[@]}"; do
            local event_block="${calcurse_blocks[$key]}"

            # Arricchisci per Proton
            event_block=$(enrich_event_for_proton "$event_block")

            # Pulisci RRULE
            local cleaned_block=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^RRULE: ]]; then
                    local rrule="${line#RRULE:}"
                    local cleaned_rrule=$(clean_rrule_for_proton "$rrule")
                    cleaned_block+="RRULE:${cleaned_rrule}"$'\n'
                else
                    cleaned_block+="${line}"$'\n'
                fi
            done < <(echo "$event_block")

            local normalized=$(normalize_alarms "$cleaned_block" "proton")
            normalized=$(echo "$normalized" | sed 's/BEGIN:VALARMTRIGGER/BEGIN:VALARM\nTRIGGER/g')
            normalized=$(echo "$normalized" | sed 's/BEGIN:VALARMACTION/BEGIN:VALARM\nACTION/g')
            echo "$normalized" >> "$NEW_EVENTS_FILE"
        done

        echo "END:VCALENDAR" >> "$NEW_EVENTS_FILE"
        sed -i '/^$/d' "$NEW_EVENTS_FILE"

        echo "✅ File generated: $NEW_EVENTS_FILE"
        echo "   📌 Please manually import this file into  Proton Calendar"
    fi

    # Aggiorna export
    if [[ ${#events_to_import_to_calcurse[@]} -gt 0 ]] || [[ ${#events_to_delete_from_calcurse[@]} -gt 0 ]]; then
        echo ""
        echo "🔄 Updating Calcurse export..."
        export_calcurse_with_uids
    fi

    # Pulizia
    clean_old_backups
    rm -f "$proton_tmp" "$calcurse_tmp"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ SYNCRONIZATION COMPLETED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 Summary:"
    echo "   • Events imported into Calcurse: ${#events_to_import_to_calcurse[@]}"
    echo "   • Events deleted from Calcurse: ${#events_to_delete_from_calcurse[@]}"
    echo "   • Events to import into Proton: ${#events_to_export_to_proton[@]}"
    echo ""
    echo "💾 Backup available: $BACKUP_FILE"
}


option_B() {
  echo "➡️ Import events from Proton (merge - ONLY additions)"


    # ============================================================
    # CONTROLLO FRESHNESS DEL FILE PROTON
    # ============================================================

#    local proton_basename=$(basename "$IMPORT_FILE")
    local fresh_proton_file=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "My calendar-*.ics" -o -name "My Calendar-*.ics" \) -type f | sort -r | head -n1)

    find_and_prepare_proton_file

    if [[ -z "$fresh_proton_file" ]]; then
        echo ""
        echo "⚠️  WARNING: Using existing 'calendar.ics' file"
        echo "    This file may have been used in a previous sync."
        echo "    Batch import will add ALL events from this file."
        echo "    For best results, download a fresh calendar from Proton."
        echo ""
        read -rp "    Do you want to continue with batch import anyway? (y/N): " continue_old

        if [[ ! "$continue_old" =~ ^[yY]$ ]]; then
            echo "❌ Import cancelled. Please download a fresh calendar from Proton."
            return 1
        fi
        echo ""
      else
        local file_timestamp=$(stat -c %Y "$IMPORT_FILE" 2>/dev/null || stat -f %m "$IMPORT_FILE" 2>/dev/null)
        local current_timestamp=$(date +%s)
        local age_seconds=$((current_timestamp - file_timestamp))
        local age_hours=$((age_seconds / 3600))

        if [[ $age_seconds -gt 10800 ]]; then
            echo ""
            echo "⚠️  WARNING: Proton calendar file is older than 3 hours"
            echo "    File age: approximately $age_hours hours"
            echo "    Last modified: $(date -r "$IMPORT_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$IMPORT_FILE" 2>/dev/null)"
            echo ""
            echo "    Batch import may add outdated events to Calcurse."
            echo ""
            read -rp "    Do you want to continue anyway? (y/N): " continue_old

            if [[ ! "$continue_old" =~ ^[yY]$ ]]; then
                echo "❌ Import cancelled. Please download a fresh calendar from Proton."
                return 1
            fi
            echo ""
        fi
    fi
    # ============================================================

    local proton_file="$IMPORT_FILE"

    #echo "📄 Trovato: $(basename "$proton_file")"

    #echo "💾 Backup in $BACKUP_FILE..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup fallito"

    local current_calcurse_export=$(mktemp)
    export_calcurse_with_uids
    cp "$EXPORT_FILE" "$current_calcurse_export"

    local proton_file_normalized=$(mktemp)
   # echo "📄 Normalizzo i promemoria per Calcurse..."

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

   # echo "📄 Cerco nuovi eventi da Proton da importare in Calcurse..."

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
                echo "➕ New event to import: $summary ($dtstart)"
            fi

            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
        fi
    done < "$proton_tmp"

    echo "END:VCALENDAR" >> "$new_events_for_calcurse"

    if [[ $import_count -gt 0 ]]; then
        echo "📥 Importing $import_count new events from Proton to Calcurse…"
        calcurse -D "$CALCURSE_DIR" -i "$new_events_for_calcurse" || die "Import failed"

    #    echo "📄 Aggiorno il file di export con i nuovi eventi importati..."
        export_calcurse_with_uids
    else
        echo "✅ No new events to import from Proton"
    fi

    rm -f "$proton_file_normalized" "$current_calcurse_export" "$new_events_for_calcurse" "$proton_tmp" "$calcurse_tmp"

    clean_old_backups

    echo "✅ Import completed! Events updated from Proton (merge)."
    echo "📂 Backup saved: $BACKUP_FILE"
    echo "📂 Export updated: $EXPORT_FILE"
    echo "📊 Events imported: $import_count"
}

option_C() {
    echo "➡️ Export events to Proton"
    export_calcurse_with_uids
    # Check if Calcurse is changed
    if ! check_if_export_needed; then
        echo "⏭️  Export skipped - no changes in Calcurse"
        return 0
    fi
    find_and_prepare_proton_file
    find_new_events "$IMPORT_FILE" "$EXPORT_FILE" "$NEW_EVENTS_FILE"
     # Salva timestamp DOPO export riuscito
    save_export_timestamp
    echo "📂 File for Proton: $NEW_EVENTS_FILE"
}

option_D() {
    echo "➡️ Export future events only (30 days)"
    export_calcurse_with_uids
    # Check if Calcurse is changed
    if ! check_if_export_needed; then
        echo "⏭️  Export skipped - no changes in Calcurse"
        return 0
    fi
    find_and_prepare_proton_file

    local proton_filtered=$(mktemp)
    local calcurse_filtered=$(mktemp)

    filter_events_by_date "$IMPORT_FILE" "$proton_filtered" 30
    filter_events_by_date "$EXPORT_FILE" "$calcurse_filtered" 30

    find_new_events "$proton_filtered" "$calcurse_filtered" "$NEW_EVENTS_FILE"

    rm -f "$proton_filtered" "$calcurse_filtered"
    save_export_timestamp
    echo "📂 File for Proton (future events only): $NEW_EVENTS_FILE"
}

option_E() {
    echo "➡️ Export with custom interval"
    read -rp "Days in the future to include (default: 90): " days_future
    days_future=${days_future:-90}

    export_calcurse_with_uids
    if ! check_if_export_needed; then
        echo "⏭️  Export skipped - no changes in Calcurse"
        return 0
    fi
    find_and_prepare_proton_file

    local proton_filtered=$(mktemp)
    local calcurse_filtered=$(mktemp)

    filter_events_by_date "$IMPORT_FILE" "$proton_filtered" "$days_future"
    filter_events_by_date "$EXPORT_FILE" "$calcurse_filtered" "$days_future"

    find_new_events "$proton_filtered" "$calcurse_filtered" "$NEW_EVENTS_FILE"

    rm -f "$proton_filtered" "$calcurse_filtered"
    save_export_timestamp
    echo "📂 File for Proton (next $days_future days): $NEW_EVENTS_FILE"
}

option_F() {
    echo "🔄 COMPLETE SYNC: Proton → Calcurse"
    echo "⚠️  WARNING: This will completely replace Calcurse with Proton "
    echo "   All events in Calcurse not present in Proton will be LOST!"

    read -rp "Are you sure? (type 'CONFIRM' to proceed): " confirmation
    if [[ "$confirmation" != "CONFIRM" ]]; then
        echo "❌ Synchronization cancelled"
        return 1
    fi

    find_and_prepare_proton_file

    echo "💾 Backup in $BACKUP_FILE..."
    calcurse -D "$CALCURSE_DIR" --export > "$BACKUP_FILE" || die "Backup failed"

    echo "🗑️ Emptying Calcurse..."
    > "$CALCURSE_DIR/apts"

    echo "📥 Importing everything from Proton..."
    calcurse -D "$CALCURSE_DIR" -i "$IMPORT_FILE" || die "Import failed"

    export_calcurse_with_uids
    clean_old_backups

    echo "✅ Complete synchronization completed!"
    echo "📂 Backup saved: $BACKUP_FILE"
}

echo "🔔 REMEMBER: Make sure you have downloaded the UPDATED file from Proton Calendar"
echo "Choose an option:"
echo "A) 🧹 GUIDED BIDIRECTIONAL SYNC: Calcurse ↔ Proton + report"
echo "B) Import events from Proton (merge - ONLY additions)"
echo "C) Export events to Proton (ONLY additions)"
echo "D) Export only future events (30 days)"
echo "E) Export with custom interval"
echo "---------"
echo "F) 🔄 COMPLETE SYNC: Proton → Calcurse (REPLACES everything)"
echo "---------"
echo "Q) ❌ Exit without operations"
echo ""

while true; do
    read -rp "Enter A, B, C, D, E, F o Q: " choice

    case "${choice^^}" in
        A) option_A; break ;;
        B) option_B; break ;;
        C) option_C; break ;;
        D) option_D; break ;;
        E) option_E; break ;;
        F) option_F; break ;;
        Q) echo "👋 Goodbye!"; exit 0 ;;
        *) echo "❌ Error: Invalid choice. Use A, B, C, D, E, F or Q." ;;
    esac
done
