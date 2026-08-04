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
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/calcurse-sync"
ALARM_STATE_FILE="$STATE_DIR/alarm-state.tsv"
ALARM_STATE_VERSION=1
EVENT_STATE_FILE="$STATE_DIR/event-state.tsv"
EVENT_STATE_VERSION=1
DRY_RUN=0

die() {
    echo "❌ Errore: $1" >&2
    exit 1
}

show_usage() {
    echo "Usage: ${0##*/} [--dry-run]"
    echo ""
    echo "  --dry-run  Analyze guided sync choices without modifying files or Calcurse"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) show_usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

if [[ $DRY_RUN -eq 1 ]]; then
    [[ -d "$BACKUP_DIR" ]] || die "Calendar directory not found: $BACKUP_DIR"
else
    mkdir -p "$BACKUP_DIR"
fi

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
        if [[ $DRY_RUN -eq 1 ]]; then
            IMPORT_FILE="$proton_file"
        else
            mv "$proton_file" "$IMPORT_FILE"
        fi
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

    trigger="${trigger//[[:space:]]/}"

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
# SANITIZZAZIONE ICS PER IMPORT IN CALCURSE
# (calcurse è molto severo su EXDATE/TZID e sull'ordine di alcuni campi)
# ----------------------------------------------------------------------

_ics_clean_datetime_value() {
    # Input: YYYYMMDDTHHMMSS[Z] oppure varianti con timezone/parametri già rimossi
    # Output: YYYYMMDDTHHMMSS (senza Z)
    local v="$1"
    v="${v%%Z}"                          # drop trailing Z
    v="$(echo "$v" | tr -d '\r\n ')"     # trim
    v="$(echo "$v" | tr -cd '0-9T,')"    # keep only digits/T/commas

    # If it's a single datetime, normalize seconds to HHMMSS
    if [[ "$v" != *","* ]]; then
        if [[ "$v" =~ ^[0-9]{8}T[0-9]{4}$ ]]; then
            v="${v}00"
        fi
    else
        # For lists, normalize each token individually (add seconds if missing)
        local out=""
        IFS=',' read -ra parts <<< "$v"
        for p in "${parts[@]}"; do
            if [[ "$p" =~ ^[0-9]{8}T[0-9]{4}$ ]]; then
                p="${p}00"
            fi
            [[ -z "$out" ]] && out="$p" || out="${out},${p}"
        done
        v="$out"
    fi

    echo "$v"
}

_ics_clean_date_value() {
    # Input may contain YYYYMMDD or YYYYMMDDT000000 etc. Output: YYYYMMDD
    local v="$1"
    v="${v%%Z}"
    v="$(echo "$v" | tr -d '\r\n ')"
    v="$(echo "$v" | tr -cd '0-9T,')"
    # Take only the date part for each token
    local out=""
    IFS=',' read -ra parts <<< "$v"
    for p in "${parts[@]}"; do
        local d="${p:0:8}"
        [[ -z "$out" ]] && out="$d" || out="${out},${d}"
    done
    echo "$out"
}

_ics_duration_from_dtstart_dtend() {
    # Input: dtstart dtend in YYYYMMDDTHHMMSS (floating/local)
    # Output: RFC5545 duration like P0DT1H30M0S
    local s="$1"
    local e="$2"

    # Convert to "YYYY-MM-DD HH:MM:SS"
    local s_iso="${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}"
    local e_iso="${e:0:4}-${e:4:2}-${e:6:2} ${e:9:2}:${e:11:2}:${e:13:2}"

    local s_epoch e_epoch diff
    s_epoch=$(date -d "$s_iso" +%s 2>/dev/null) || return 1
    e_epoch=$(date -d "$e_iso" +%s 2>/dev/null) || return 1
    diff=$(( e_epoch - s_epoch ))
    # Cross-midnight safety
    [[ $diff -lt 0 ]] && diff=$(( diff + 86400 ))

    local days=$(( diff / 86400 ))
    local rem=$(( diff % 86400 ))
    local hours=$(( rem / 3600 ))
    rem=$(( rem % 3600 ))
    local mins=$(( rem / 60 ))
    local secs=$(( rem % 60 ))

    echo "P${days}DT${hours}H${mins}M${secs}S"
}


extract_compatible_display_alarm_trigger() {
    local event_block="$1"
    local in_alarm=0
    local current_trigger=""
    local current_action=""

    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            "BEGIN:VALARM"*)
                in_alarm=1
                current_trigger=""
                current_action=""
                ;;
            "END:VALARM"*)
                if [[ "${current_action^^}" == "DISPLAY" && -n "$current_trigger" ]]; then
                    local seconds
                    seconds=$(convert_trigger_to_seconds "$current_trigger")
                    if [[ "$seconds" -gt 0 ]]; then
                        convert_seconds_to_trigger "$seconds" "calcurse"
                        return 0
                    fi
                fi
                in_alarm=0
                ;;
            TRIGGER*)
                if [[ $in_alarm -eq 1 && "$line" != *"RELATED=END"* ]]; then
                    current_trigger="${line#*:}"
                fi
                ;;
            ACTION:*)
                if [[ $in_alarm -eq 1 ]]; then
                    current_action="${line#ACTION:}"
                fi
                ;;
        esac
    done <<< "$event_block"

    echo ""
}

event_is_timed() {
    local event_block="$1"
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" == DTSTART* ]] || continue
        [[ "$line" != *"VALUE=DATE"* && "${line#*:}" == *"T"* ]]
        return
    done <<< "$event_block"
    return 1
}

add_display_alarm_to_event() {
    local event_block="$1"
    local trigger="$2"

    if [[ -n "$(extract_compatible_display_alarm_trigger "$event_block")" ]]; then
        echo "$event_block"
        return 0
    fi

    local out=""
    while IFS= read -r line; do
        if [[ "$line" == "END:VEVENT" ]]; then
            out+="BEGIN:VALARM"$'\n'
            out+="TRIGGER:${trigger}"$'\n'
            out+="ACTION:DISPLAY"$'\n'
            out+="END:VALARM"$'\n'
        fi
        out+="$line"$'\n'
    done < <(echo "$event_block")

    echo "${out%$'\n'}"
}

remove_alarms_from_event() {
    local event_block="$1"
    local out="" in_alarm=0 line

    while IFS= read -r line; do
        case "$line" in
            BEGIN:VALARM*) in_alarm=1; continue ;;
            END:VALARM*) in_alarm=0; continue ;;
        esac
        [[ $in_alarm -eq 0 ]] && out+="$line"$'\n'
    done <<< "$event_block"

    printf '%s' "${out%$'\n'}"
}

alarm_state_key() {
    local event_block="$1"
    local uid="" has_rrule=0 line identity hash

    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            UID:*) [[ -z "$uid" ]] && uid="${line#UID:}" ;;
            RRULE:*) has_rrule=1 ;;
        esac
    done <<< "$event_block"

    if [[ -n "$uid" ]]; then
        identity="UID:${uid}"
    elif [[ $has_rrule -eq 1 ]]; then
        identity="RECURRENCE:$(generate_recurrence_signature "$event_block")"
    else
        identity="HASH:$(compute_event_hash "$event_block")"
    fi

    hash=$(printf '%s' "$identity" | sha256sum)
    hash="${hash%% *}"
    echo "${hash:0:32}"
}

load_alarm_state() {
    local destination_name="$1"
    local -n destination="$destination_name"

    [[ -f "$ALARM_STATE_FILE" ]] || return 1

    local expected_header=$'calcurse-sync-alarm-state\t1'
    local header="" key alarm extra
    IFS= read -r header < "$ALARM_STATE_FILE" || return 2
    [[ "$header" == "$expected_header" ]] || return 2

    while IFS=$'\t' read -r key alarm extra; do
        [[ -z "$key" ]] && continue
        if [[ ! "$key" =~ ^[0-9a-f]{32}$ || ! "$alarm" =~ ^[01]$ || -n "$extra" ]]; then
            destination=()
            return 2
        fi
        destination["$key"]="$alarm"
    done < <(tail -n +2 "$ALARM_STATE_FILE")
}

save_alarm_state() {
    local blocks_name="$1"
    local overrides_name="$2"
    local state_keys_name="${3:-}"
    local -n blocks="$blocks_name"
    local -n overrides="$overrides_name"
    if [[ -n "$state_keys_name" ]]; then
        local -n state_keys="$state_keys_name"
    fi

    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true

    local tmp
    tmp=$(mktemp "$STATE_DIR/.alarm-state.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true

    printf 'calcurse-sync-alarm-state\t%s\n' "$ALARM_STATE_VERSION" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    local pkey state_key alarm_value trigger
    for pkey in "${!blocks[@]}"; do
        state_key=""
        if [[ -n "$state_keys_name" ]]; then
            state_key="${state_keys[$pkey]}"
        fi
        [[ -n "$state_key" ]] || state_key=$(alarm_state_key "${blocks[$pkey]}")
        alarm_value=0
        if event_is_timed "${blocks[$pkey]}"; then
            trigger=$(extract_compatible_display_alarm_trigger "${blocks[$pkey]}")
            [[ -n "$trigger" ]] && alarm_value=1
        fi
        if [[ -n "${overrides[$state_key]+present}" ]]; then
            alarm_value="${overrides[$state_key]}"
        fi
        printf '%s\t%s\n' "$state_key" "$alarm_value" >> "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    done

    if ! mv -f "$tmp" "$ALARM_STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

load_event_state() {
    local destination_name="$1"
    local -n destination="$destination_name"

    [[ -f "$EVENT_STATE_FILE" ]] || return 1

    local expected_header=$'calcurse-sync-event-state\t1'
    local line line_number=0
    while IFS= read -r line; do
        ((line_number++))
        if [[ $line_number -eq 1 ]]; then
            [[ "$line" == "$expected_header" ]] || return 2
            continue
        fi
        [[ -z "$line" ]] && continue
        if [[ ! "$line" =~ ^[0-9a-f]{32}$ ]]; then
            destination=()
            return 2
        fi
        destination["$line"]=1
    done < "$EVENT_STATE_FILE"

    [[ $line_number -gt 0 ]] || return 2
}

save_event_state() {
    local state_name="$1"
    local -n state="$state_name"

    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true

    local tmp
    tmp=$(mktemp "$STATE_DIR/.event-state.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true

    printf 'calcurse-sync-event-state\t%s\n' "$EVENT_STATE_VERSION" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    local state_key
    for state_key in "${!state[@]}"; do
        printf '%s\n' "$state_key" >> "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    done

    if ! mv -f "$tmp" "$EVENT_STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

sanitize_vevent_for_calcurse() {
    # Produce a minimal, calcurse-friendly VEVENT:
    # - Remove TZID params from DTSTART/DTEND/EXDATE
    # - Normalize EXDATE type/format (DATE vs DATE-TIME)
    # - Convert DTEND -> DURATION for timed events (more reliable with calcurse)
    # - Keep the first compatible DISPLAY alarm (Calcurse supports one notification)
    # - Keep ordering stable with DTSTART early
    local block="$1"

    local uid="" summary="" description="" location=""
    local dtstart_raw="" dtend_raw="" duration_raw=""
    local rrule_raw=""
    local exdate_raw_list=()
    local alarm_trigger
    alarm_trigger=$(extract_compatible_display_alarm_trigger "$block")

    local in_alarm=0
    while IFS= read -r line; do
        case "$line" in
            "BEGIN:VALARM"*) in_alarm=1; continue ;;
            "END:VALARM"*) in_alarm=0; continue ;;
        esac
        [[ $in_alarm -eq 1 ]] && continue

        case "$line" in
            UID:*) uid="${line#UID:}" ;;
            SUMMARY:*) summary="${line#SUMMARY:}" ;;
            DESCRIPTION:*) [[ -z "$description" ]] && description="${line#DESCRIPTION:}" ;;
            LOCATION:*) location="${line#LOCATION:}" ;;
            DTSTART*) dtstart_raw="$line" ;;
            DTEND*) dtend_raw="$line" ;;
            DURATION:*) duration_raw="${line#DURATION:}" ;;
            RRULE:*) rrule_raw="${line#RRULE:}" ;;
            EXDATE*) exdate_raw_list+=("$line") ;;
            *) : ;;
        esac
    done < <(echo "$block" | tr -d '\r')

    # DTSTART parse + type
    local dtstart_val="$(echo "$dtstart_raw" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')"
    local is_allday=0
    if echo "$dtstart_raw" | grep -q "VALUE=DATE" || [[ "$dtstart_val" != *"T"* ]]; then
        is_allday=1
        dtstart_val="$(_ics_clean_date_value "$dtstart_val")"
    else
        dtstart_val="$(_ics_clean_datetime_value "$dtstart_val")"
    fi

    # DTEND parse
    local dtend_val=""
    if [[ -n "$dtend_raw" ]]; then
        dtend_val="$(echo "$dtend_raw" | sed 's/^DTEND[^:]*://' | tr -d '\r\n ')"
        if [[ $is_allday -eq 1 ]]; then
            dtend_val="$(_ics_clean_date_value "$dtend_val")"
        else
            dtend_val="$(_ics_clean_datetime_value "$dtend_val")"
        fi
    fi

    # RRULE: remove trailing Z from UNTIL if present (calcurse import is stricter)
    local rrule_out="$rrule_raw"
    if [[ -n "$rrule_out" ]]; then
        rrule_out="$(echo "$rrule_out" | sed -E 's/UNTIL=([0-9]{8}T[0-9]{6})Z/UNTIL=\1/g' | sed -E 's/UNTIL=([0-9]{8})Z/UNTIL=\1/g')"
    fi

    # EXDATE normalize (merge multiple EXDATE lines -> single line)
    local ex_out=""
    if [[ ${#exdate_raw_list[@]} -gt 0 ]]; then
        local merged=""
        for exl in "${exdate_raw_list[@]}"; do
            local v="$(echo "$exl" | sed 's/^EXDATE[^:]*://' | tr -d '\r\n ')"
            if [[ $is_allday -eq 1 ]]; then
                v="$(_ics_clean_date_value "$v")"
            else
                v="$(_ics_clean_datetime_value "$v")"
            fi
            [[ -z "$v" ]] && continue
            if [[ -z "$merged" ]]; then
                merged="$v"
            else
                merged="${merged},${v}"
            fi
        done
        # Deduplicate tokens
        if [[ -n "$merged" ]]; then
            IFS=',' read -ra toks <<< "$merged"
            local -A seen=()
            local uniq=""
            for t in "${toks[@]}"; do
                [[ -z "$t" ]] && continue
                if [[ -z "${seen[$t]}" ]]; then
                    seen[$t]=1
                    [[ -z "$uniq" ]] && uniq="$t" || uniq="${uniq},${t}"
                fi
            done
            if [[ -n "$uniq" ]]; then
                if [[ $is_allday -eq 1 ]]; then
                    ex_out="EXDATE;VALUE=DATE:${uniq}"
                else
                    ex_out="EXDATE:${uniq}"
                fi
            fi
        fi
    fi

    # Duration/End normalization:
    local duration_out=""
    local dtend_out=""

    if [[ -n "$duration_raw" ]]; then
        duration_out="DURATION:${duration_raw}"
    else
        if [[ $is_allday -eq 1 ]]; then
            [[ -n "$dtend_val" ]] && dtend_out="DTEND;VALUE=DATE:${dtend_val}"
        else
            if [[ -n "$dtend_val" && -n "$dtstart_val" ]]; then
                local dur="$(_ics_duration_from_dtstart_dtend "$dtstart_val" "$dtend_val" 2>/dev/null || true)"
                if [[ -n "$dur" ]]; then
                    duration_out="DURATION:${dur}"
                else
                    # Fallback: keep DTEND without params
                    dtend_out="DTEND:${dtend_val}"
                fi
            fi
        fi
    fi

    # Build sanitized event
    local out="BEGIN:VEVENT"$'\n'
    [[ -n "$uid" ]] && out+="UID:${uid}"$'\n'

    if [[ $is_allday -eq 1 ]]; then
        out+="DTSTART;VALUE=DATE:${dtstart_val}"$'\n'
        [[ -n "$dtend_out" ]] && out+="${dtend_out}"$'\n'
    else
        out+="DTSTART:${dtstart_val}"$'\n'
        [[ -n "$duration_out" ]] && out+="${duration_out}"$'\n'
        [[ -n "$dtend_out" ]] && out+="${dtend_out}"$'\n'
    fi

    [[ -n "$rrule_out" ]] && out+="RRULE:${rrule_out}"$'\n'
    [[ -n "$ex_out" ]] && out+="${ex_out}"$'\n'
    [[ -n "$summary" ]] && out+="SUMMARY:${summary}"$'\n'
    [[ -n "$location" ]] && out+="LOCATION:${location}"$'\n'
    [[ -n "$description" ]] && out+="DESCRIPTION:${description}"$'\n'
    if [[ $is_allday -eq 0 && -n "$alarm_trigger" ]]; then
        out+="BEGIN:VALARM"$'\n'
        out+="TRIGGER:${alarm_trigger}"$'\n'
        out+="ACTION:DISPLAY"$'\n'
        out+="END:VALARM"$'\n'
    fi
    out+="END:VEVENT"

    echo "$out"
}

sanitize_calendar_for_calcurse_import() {
    local input_file="$1"
    local output_file="$2"

    [[ -f "$input_file" ]] || return 1

    local tmp_events=$(mktemp)
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$input_file" | tr -d '\r' > "$tmp_events"

    {
        echo "BEGIN:VCALENDAR"
        echo "VERSION:2.0"
        echo "PRODID:-//calcurse-sync//Sanitized for calcurse//"
        local block="" in_event=0
        while IFS= read -r line; do
            if [[ "$line" == "BEGIN:VEVENT" ]]; then
                block="$line"
                in_event=1
            elif [[ "$line" == "END:VEVENT" ]]; then
                block+=$'\n'"$line"
                sanitize_vevent_for_calcurse "$block"
                in_event=0
                block=""
            elif (( in_event )); then
                block+=$'\n'"$line"
            fi
        done < "$tmp_events"
        echo "END:VCALENDAR"
    } > "$output_file"

    rm -f "$tmp_events"
}


count_vevents() {
    local input_file="$1"

    awk '
        {
            sub(/\r$/, "", $0)
            if ($0 == "BEGIN:VEVENT") {
                count++
            }
        }
        END {
            print count + 0
        }
    ' "$input_file"
}

replace_calcurse_events_atomically() {
    local input_file="$1"

    [[ -f "$input_file" ]] || {
        echo "❌ Atomic import source not found: $input_file" >&2
        return 1
    }
    [[ -d "$CALCURSE_DIR" ]] || {
        echo "❌ Calcurse data directory not found: $CALCURSE_DIR" >&2
        return 1
    }

    local staging_root
    staging_root=$(mktemp -d "${TMPDIR:-/tmp}/calcurse-sync.XXXXXX") || return 1

    local staging_dir="$staging_root/calcurse"
    local sanitized_file="$staging_root/import.ics"
    local staged_export="$staging_root/export.ics"
    local replacement_file=""

    mkdir -p "$staging_dir" || {
        rm -rf "$staging_root"
        return 1
    }

    if ! cp -a "$CALCURSE_DIR/." "$staging_dir/"; then
        echo "❌ Unable to create the temporary Calcurse database" >&2
        rm -rf "$staging_root"
        return 1
    fi

    : > "$staging_dir/apts" || {
        echo "❌ Unable to initialize the temporary appointment database" >&2
        rm -rf "$staging_root"
        return 1
    }

    if ! sanitize_calendar_for_calcurse_import "$input_file" "$sanitized_file"; then
        echo "❌ Unable to sanitize the calendar for the temporary import" >&2
        rm -rf "$staging_root"
        return 1
    fi

    local source_count sanitized_count imported_count
    source_count=$(count_vevents "$input_file")
    sanitized_count=$(count_vevents "$sanitized_file")

    if [[ "$source_count" -ne "$sanitized_count" ]]; then
        echo "❌ Sanitization changed the event count ($source_count → $sanitized_count)" >&2
        rm -rf "$staging_root"
        return 1
    fi

    echo "🧪 Importing and validating $source_count event(s) in a temporary database..."
    if ! calcurse -D "$staging_dir" -i "$sanitized_file"; then
        echo "❌ Temporary import failed; the original database was not changed" >&2
        rm -rf "$staging_root"
        return 1
    fi

    if ! calcurse -D "$staging_dir" --export > "$staged_export"; then
        echo "❌ Unable to validate the temporary Calcurse database" >&2
        rm -rf "$staging_root"
        return 1
    fi

    imported_count=$(count_vevents "$staged_export")
    if [[ "$imported_count" -ne "$source_count" ]]; then
        echo "❌ Temporary import validation failed: expected $source_count event(s), found $imported_count" >&2
        rm -rf "$staging_root"
        return 1
    fi

    # Notes are content-addressed. Copy them before the atomic apts switch;
    # at worst a failed switch leaves harmless, unreferenced note files.
    if [[ -d "$staging_dir/notes" ]]; then
        mkdir -p "$CALCURSE_DIR/notes" || {
            rm -rf "$staging_root"
            return 1
        }
        if ! cp -a "$staging_dir/notes/." "$CALCURSE_DIR/notes/"; then
            echo "❌ Unable to copy appointment notes from the temporary database" >&2
            rm -rf "$staging_root"
            return 1
        fi
    fi

    replacement_file=$(mktemp "$CALCURSE_DIR/.apts.calcurse-sync.XXXXXX") || {
        rm -rf "$staging_root"
        return 1
    }

    if ! cp "$staging_dir/apts" "$replacement_file"; then
        echo "❌ Unable to prepare the validated appointment database" >&2
        rm -f "$replacement_file"
        rm -rf "$staging_root"
        return 1
    fi

    if [[ -f "$CALCURSE_DIR/apts" ]]; then
        chmod --reference="$CALCURSE_DIR/apts" "$replacement_file" 2>/dev/null || true
    fi

    if ! mv -f "$replacement_file" "$CALCURSE_DIR/apts"; then
        echo "❌ Unable to activate the validated appointment database" >&2
        rm -f "$replacement_file"
        rm -rf "$staging_root"
        return 1
    fi

    rm -rf "$staging_root"
    echo "✅ Validated appointment database activated atomically"
}


# ----------------------------------------------------------------------
# PULIZIA RRULE PER COMPATIBILITÀ PROTON
# ----------------------------------------------------------------------

clean_rrule_for_proton() {
    local rrule="$1"
    local dtstart_line="${2:-}"

    # Remove elements that do not affect the supported daily/weekly forms.
    if [[ "$rrule" =~ FREQ=WEEKLY || "$rrule" =~ FREQ=DAILY ]]; then
        rrule=$(echo "$rrule" | sed 's/;BYMONTH=[0-9]*//g' | sed 's/BYMONTH=[0-9]*;//g')
    fi

    # These forms describe the same occurrence set as a weekly rule when the
    # interval is one and no additional monthly filter is present.
    local byday="" bymonth="" bymonthday="" bysetpos="" interval="1"
    local until_local="" has_month_filter=0 has_other_date_filter=0 component
    IFS=';' read -ra rrule_components <<< "$rrule"
    for component in "${rrule_components[@]}"; do
        case "$component" in
            BYDAY=*) byday="${component#BYDAY=}" ;;
            BYMONTH=*) bymonth="${component#BYMONTH=}"; has_month_filter=1 ;;
            BYMONTHDAY=*) bymonthday="${component#BYMONTHDAY=}"; has_month_filter=1 ;;
            BYSETPOS=*) bysetpos="${component#BYSETPOS=}"; has_month_filter=1 ;;
            BYYEARDAY=*|BYWEEKNO=*) has_other_date_filter=1 ;;
            INTERVAL=*) interval="${component#INTERVAL=}" ;;
            UNTIL=*)
                local until_value="${component#UNTIL=}"
                [[ "$until_value" =~ ^[0-9]{8}T[0-9]{6}$ ]] && until_local="$until_value"
                ;;
        esac
    done

    if [[ "$rrule" == *"FREQ=DAILY"* && -n "$byday" && "$interval" == "1" ]]; then
        rrule=${rrule/FREQ=DAILY/FREQ=WEEKLY}
    elif [[ "$rrule" == *"FREQ=MONTHLY"* && "$interval" == "1" && \
            $has_month_filter -eq 0 && \
            "$byday" =~ ^(MO|TU|WE|TH|FR|SA|SU)(,(MO|TU|WE|TH|FR|SA|SU))*$ ]]; then
        rrule=${rrule/FREQ=MONTHLY/FREQ=WEEKLY}
    fi

    # Calcurse can emit filters that merely restate DTSTART. Proton's native
    # simple monthly/yearly rules omit them, so remove only exact redundancies.
    local dtstart_value="${dtstart_line#*:}"
    dtstart_value="${dtstart_value%Z}"
    if [[ "$dtstart_value" =~ ^[0-9]{8}T ]]; then
        local start_month=$((10#${dtstart_value:4:2}))
        local start_monthday=$((10#${dtstart_value:6:2}))

        if [[ "$rrule" == *"FREQ=MONTHLY"* && -z "$byday" && -z "$bymonth" ]] &&
           [[ -z "$bysetpos" && $has_other_date_filter -eq 0 ]] &&
           [[ "$bymonthday" =~ ^[0-9]+$ ]] &&
           (( 10#$bymonthday == start_monthday )); then
            rrule=$(echo "$rrule" | sed "s/;BYMONTHDAY=$bymonthday//g" | sed "s/BYMONTHDAY=$bymonthday;//g")
        elif [[ "$rrule" == *"FREQ=YEARLY"* && -z "$byday" && -z "$bysetpos" ]] &&
             [[ $has_other_date_filter -eq 0 && "$bymonth" =~ ^[0-9]+$ ]] &&
             [[ "$bymonthday" =~ ^[0-9]+$ ]] &&
             (( 10#$bymonth == start_month && 10#$bymonthday == start_monthday )); then
            rrule=$(echo "$rrule" | sed "s/;BYMONTH=$bymonth//g" | sed "s/BYMONTH=$bymonth;//g")
            rrule=$(echo "$rrule" | sed "s/;BYMONTHDAY=$bymonthday//g" | sed "s/BYMONTHDAY=$bymonthday;//g")
        fi
    fi

    # Remove recurrence parts Proton does not accept. The conversion above is
    # deliberately completed before this cleanup so semantics are not inferred
    # from an already truncated rule.
    rrule=$(echo "$rrule" | sed 's/;BYSETPOS=[^;]*//g' | sed 's/BYSETPOS=[^;]*;//g')
    rrule=$(echo "$rrule" | sed 's/;BY\(SECOND\|MINUTE\|HOUR\)=[^;]*//g')
    rrule=$(echo "$rrule" | sed 's/;WKST=[^;]*//g' | sed 's/WKST=[^;]*;//g')

    # A date-time UNTIL paired with a TZID DTSTART must be expressed in UTC.
    local dtstart_params="${dtstart_line%%:*}"
    local tzid=""
    if [[ "$dtstart_params" == *"TZID="* ]]; then
        tzid="${dtstart_params#*TZID=}"
        tzid="${tzid%%;*}"
    fi

    if [[ -n "$until_local" && -n "$tzid" ]]; then
        local until_iso until_epoch until_utc
        until_iso="${until_local:0:4}-${until_local:4:2}-${until_local:6:2} ${until_local:9:2}:${until_local:11:2}:${until_local:13:2}"
        until_epoch=$(TZ="$tzid" date -d "$until_iso" +%s 2>/dev/null || true)
        if [[ -n "$until_epoch" ]]; then
            until_utc=$(date -u -d "@$until_epoch" +%Y%m%dT%H%M%SZ 2>/dev/null || true)
            [[ -n "$until_utc" ]] && rrule=${rrule/UNTIL=$until_local/UNTIL=$until_utc}
        fi
    fi

    echo "$rrule"
}

clean_event_rrules_for_proton() {
    local event_block="$1"
    local dtstart_line="" cleaned="" line

    while IFS= read -r line; do
        if [[ "$line" == DTSTART* && -z "$dtstart_line" ]]; then
            dtstart_line="$line"
        fi

        if [[ "$line" == RRULE:* ]]; then
            local cleaned_rrule
            cleaned_rrule=$(clean_rrule_for_proton "${line#RRULE:}" "$dtstart_line")
            cleaned+="RRULE:${cleaned_rrule}"$'\n'
        else
            cleaned+="${line}"$'\n'
        fi
    done <<< "$event_block"

    printf '%s' "${cleaned%$'\n'}"
}

# ----------------------------------------------------------------------
# ARRICCHIMENTO EVENTI PER COMPATIBILITÀ PROTON
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# ARRICCHIMENTO EVENTI PER COMPATIBILITÀ PROTON
# Converte RRULE:FREQ=DAILY;UNTIL in DTEND per eventi brevi (<= 90 giorni)
# Mantiene RRULE per eventi ricorrenti veri (settimanali, mensili, lunghi)

# ----------------------------------------------------------------------
# AGGIUNGI COLOR PER EVENTI BNB IN PROTON
# ----------------------------------------------------------------------
add_bnb_color() {
    local event_block="$1"
    local summary=""
    local color=""
    local result=""
    local in_event=0

    # Estrai SUMMARY per identificare l'appartamento
    summary=$(echo "$event_block" | grep "^SUMMARY:" | cut -d: -f2-)

    # Determina il colore basato sull'appartamento
    if echo "$summary" | grep -qi "Appartamento 1\|Apt 1\|Camera Matrimoniale"; then
        color="turquoise"
    elif echo "$summary" | grep -qi "Appartamento 2\|Apt 2\|Camera Doppia"; then
        color="crimson"
    elif echo "$summary" | grep -qi "Appartamento 3\|Apt 3\|Camera Tripla\|Camera Quadrupla"; then
        color="green"
    fi

    # Se abbiamo un colore, aggiungilo dopo UID
    if [ -n "$color" ]; then
        while IFS= read -r line; do
            result+="$line"$'\n'
            if [[ "$line" =~ ^UID: ]]; then
                result+="COLOR:$color"$'\n'
            fi
        done < <(echo "$event_block")
        echo "${result%$'\n'}"
    else
        # Nessun colore, restituisci così com'è
        echo "$event_block"
    fi
}

# ----------------------------------------------------------------------
enrich_event_for_proton() {
    local event_block="$1"
    local user_tz="${TZ:-Europe/Rome}"
    local result=""
    local has_dtstamp=0
    local has_sequence=0
    local dtstart="" dtend="" duration="" rrule=""
    local has_rrule=0

    # Prima passata: leggi e converti DURATION -> DTEND + RRULE:FREQ=DAILY;UNTIL -> DTEND (solo per eventi brevi)
    while IFS= read -r line; do
        if [[ "$line" =~ ^DTSTART ]]; then
            # Estrai DTSTART preservando VALUE=DATE se presente
            if [[ "$line" =~ VALUE=DATE ]]; then
                dtstart=$(echo "$line" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                result+="DTSTART;VALUE=DATE:$dtstart"$'\n'
            else
                dtstart=$(echo "$line" | sed 's/^DTSTART[^:]*://' | tr -d '\r\n ')
                result+="DTSTART;TZID=$user_tz:$dtstart"$'\n'
            fi
        elif [[ "$line" =~ ^EXDATE ]]; then
            local exdate_value
            exdate_value=$(echo "${line#*:}" | tr -d '\r\n ')
            if [[ "$line" == *"VALUE=DATE"* ]]; then
                result+="EXDATE;VALUE=DATE:$exdate_value"$'\n'
            elif [[ "$line" == *"TZID="* || "$exdate_value" == *Z* ]]; then
                result+="${line%$'\r'}"$'\n'
            else
                result+="EXDATE;TZID=$user_tz:$exdate_value"$'\n'
            fi
        elif [[ "$line" =~ ^RRULE: ]]; then
            rrule="${line#RRULE:}"

            # Converti SOLO se è un evento multi-day semplice (prenotazione)
            # Criteri: FREQ=DAILY;UNTIL=... senza altri parametri (no INTERVAL, COUNT, BYDAY)
            if [[ "$rrule" =~ ^FREQ=DAILY\;UNTIL=[0-9]{8}$ ]]; then
                # È un evento multi-day semplice, converti in DTEND
                local until_date=$(echo "$rrule" | sed -n 's/.*UNTIL=\([0-9]\{8\}\).*/\1/p')

                if [[ -n "$until_date" && -n "$dtstart" ]]; then
                    # Calcola durata per verificare che sia ragionevole (<= 90 giorni)
                    local start_epoch=$(date -d "${dtstart:0:4}-${dtstart:4:2}-${dtstart:6:2}" +%s 2>/dev/null)
                    local until_epoch=$(date -d "${until_date:0:4}-${until_date:4:2}-${until_date:6:2}" +%s 2>/dev/null)

                    if [[ -n "$start_epoch" && -n "$until_epoch" ]]; then
                        local duration_days=$(( (until_epoch - start_epoch) / 86400 ))

                        # Converti solo se durata <= 90 giorni (prenotazioni tipiche)
                        if [[ $duration_days -ge 0 && $duration_days -le 90 ]]; then
                            # UNTIL è l'ultimo giorno, DTEND deve essere il giorno DOPO
                            local dtend_date=$(date -d "${until_date:0:4}-${until_date:4:2}-${until_date:6:2} + 1 day" +%Y%m%d 2>/dev/null)

                            if [[ -z "$dtend_date" ]]; then
                                # Fallback per macOS
                                dtend_date=$(date -j -v+1d -f "%Y%m%d" "$until_date" +%Y%m%d 2>/dev/null)
                            fi

                            if [[ -n "$dtend_date" ]]; then
                                result+="DTEND;VALUE=DATE:$dtend_date"$'\n'
                                has_rrule=1
                            else
                                # Conversione fallita, mantieni RRULE
                                result+="$line"$'\n'
                            fi
                        else
                            # Durata troppo lunga, mantieni RRULE (evento ricorrente vero)
                            result+="$line"$'\n'
                        fi
                    else
                        # Calcolo epoch fallito, mantieni RRULE
                        result+="$line"$'\n'
                    fi
                else
                    # UNTIL o DTSTART mancante, mantieni RRULE
                    result+="$line"$'\n'
                fi
            else
                # Non è FREQ=DAILY;UNTIL semplice, mantieni RRULE originale
                # (eventi ricorrenti settimanali, mensili, o con altri parametri)
                result+="$line"$'\n'
            fi
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

    local dtstart="" summary="" description="" duration="" dtend=""
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            DTSTART*) [[ -z "$dtstart" ]] && dtstart="${line#*:}" ;;
            SUMMARY:*) [[ -z "$summary" ]] && summary="${line#SUMMARY:}" ;;
            DESCRIPTION:*) [[ -z "$description" ]] && description="${line#DESCRIPTION:}" ;;
            DURATION:*) [[ -z "$duration" ]] && duration="${line#DURATION:}" ;;
            DTEND*) [[ -z "$dtend" ]] && dtend="${line#*:}" ;;
        esac
    done <<< "$event_block"

    local uid_base="${source_system}|${dtstart}|${summary}|${description}|${duration}|${dtend}"
    local uid_hash
    uid_hash=$(printf '%s' "$uid_base" | sha256sum)
    uid_hash="${uid_hash%% *}"
    uid_hash="${uid_hash:0:16}"

    echo "CALCURSE-${uid_hash}@${HOSTNAME:-localhost}"
}

# ----------------------------------------------------------------------
# GENERA CHIAVE UNIVOCA PER IDENTIFICARE EVENTI
# Fix: risolve il bug degli eventi con stesso DTSTART
# ----------------------------------------------------------------------
generate_event_key() {
    local event_block="$1"

    local dtstart="" summary="" rrule="" uid="" line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            DTSTART*) [[ -z "$dtstart" ]] && dtstart="${line#*:}" ;;
            SUMMARY:*) [[ -z "$summary" ]] && summary="${line#SUMMARY:}" ;;
            RRULE:*) [[ -z "$rrule" ]] && rrule="${line#RRULE:}" ;;
            UID:*) [[ -z "$uid" ]] && uid="${line#UID:}" ;;
        esac
    done <<< "$event_block"

    dtstart="${dtstart//[[:space:]]/}"
    uid="${uid//[[:space:]]/}"
    [[ -n "$rrule" ]] && rrule=$(normalize_rrule_for_comparison "$rrule")

    if [[ -n "$uid" ]]; then
        echo "UID:${uid}"
    else
        echo "${dtstart}||${summary}||${rrule}"
    fi
}

build_event_identity_from_metadata() {
    local uid="$1"
    local dtstart="$2"
    local summary="$3"
    local rrule="$4"
    local key_result_name="$5"
    local signature_result_name="$6"
    local -n key_result="$key_result_name"
    local -n signature_result="$signature_result_name"

    local normalized_rrule=""
    local key_dtstart="${dtstart//[[:space:]]/}"
    local key_uid="${uid//[[:space:]]/}"

    if [[ -n "$rrule" ]]; then
        normalized_rrule=$(normalize_rrule_for_comparison "$rrule")
    fi

    if [[ -n "$key_uid" ]]; then
        key_result="UID:${key_uid}"
    else
        key_result="${key_dtstart}||${summary}||${normalized_rrule}"
    fi

    signature_result=""
    if [[ -n "$rrule" ]]; then
        local signature_dtstart
        signature_dtstart=$(_norm_dt_token_common "$dtstart")
        signature_result="${signature_dtstart}|${summary}|${normalized_rrule}"
    fi
}

export_calcurse_with_uids() {
    local destination="${1:-$EXPORT_FILE}"
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
            local conf_line
            while IFS= read -r conf_line; do
                if [[ "$conf_line" == notification.warning=* ]]; then
                    notification_warning="${conf_line#notification.warning=}"
                    break
                fi
            done < "$conf_path"
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
            event_block="${event_block//TRIGGER:-P300S/TRIGGER:-P${notification_warning}S}"

            if [[ "$event_block" != *$'\nUID:'* ]]; then
                local uid=$(generate_event_uid "$event_block" "calcurse")
                event_block="${event_block/BEGIN:VEVENT/BEGIN:VEVENT$'\n'UID:$uid}"
            fi
            printf '%s\n' "$event_block"
            in_event=0
            event_block=""
        elif [[ $in_event -eq 1 ]]; then
            event_block+=$'\n'"$line"
        else
            echo "$line"
        fi
    done < "$temp_export" > "$destination"

    rm -f "$temp_export"
    [[ -s "$destination" ]]
}

# ----------------------------------------------------------------------
# FUNZIONE DI NORMALIZZAZIONE RRULE
# ----------------------------------------------------------------------
normalize_rrule_for_comparison() {
    local rrule="$1"

    # Se vuoto, ritorna vuoto
    [[ -z "$rrule" ]] && return

    # Estrai i componenti e ordina alfabeticamente
    local freq="" byday="" bymonthday="" bymonth="" until="" interval="" count="" wkst=""

    IFS=';' read -ra components <<< "$rrule"
    for component in "${components[@]}"; do
        case "$component" in
            FREQ=*) freq="$component" ;;
            BYDAY=*) byday="$component" ;;
            BYMONTHDAY=*) bymonthday="$component" ;;
            BYMONTH=*) : ;; # Ignorato per compatibilita tra Calcurse e Proton
            UNTIL=*)
                if [[ "$component" =~ ^UNTIL=[0-9]{8}T[0-9]{6}Z?$ ]]; then
                    until="UNTIL=NORM"
                else
                    until="$component"
                fi
                ;;
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
    local dtstart="" dtend="" summary="" description="" duration=""
    local in_alarm=0 line

    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            BEGIN:VALARM) in_alarm=1; continue ;;
            END:VALARM) in_alarm=0; continue ;;
        esac

        [[ $in_alarm -eq 1 ]] && continue
        case "$line" in
            DTSTART*) [[ -z "$dtstart" ]] && dtstart="${line#*:}" ;;
            DTEND*) [[ -z "$dtend" ]] && dtend="${line#*:}" ;;
            SUMMARY:*) [[ -z "$summary" ]] && summary="${line#SUMMARY:}" ;;
            DESCRIPTION:*) [[ -z "$description" ]] && description="${line#DESCRIPTION:}" ;;
            DURATION:*) [[ -z "$duration" ]] && duration="${line#DURATION:}" ;;
        esac
    done <<< "$event_block"

    dtstart=$(_norm_dt_token_for_hash "$dtstart")
    dtend=$(_norm_dt_token_for_hash "$dtend")

    local duration_min=0
    if [[ -n "$duration" ]]; then
        local days=0 hours=0 minutes=0
        [[ $duration =~ P([0-9]+)D ]] && days=${BASH_REMATCH[1]}
        [[ $duration =~ ([0-9]+)H ]] && hours=${BASH_REMATCH[1]}
        [[ $duration =~ ([0-9]+)M ]] && minutes=${BASH_REMATCH[1]}
        duration_min=$((days * 1440 + hours * 60 + minutes))
    elif [[ -n "$dtend" ]]; then
        if [[ "$dtstart" =~ ^[0-9]{8}$ && "$dtend" =~ ^[0-9]{8}$ ]]; then
            local s="${dtstart:0:4}-${dtstart:4:2}-${dtstart:6:2}"
            local e="${dtend:0:4}-${dtend:4:2}-${dtend:6:2}"
            local s_epoch e_epoch
            s_epoch=$(date -d "$s" +%s 2>/dev/null || echo "")
            e_epoch=$(date -d "$e" +%s 2>/dev/null || echo "")
            if [[ -n "$s_epoch" && -n "$e_epoch" ]]; then
                local days_diff=$(( (e_epoch - s_epoch) / 86400 ))
                [[ $days_diff -le 0 ]] && days_diff=1
                duration_min=$((days_diff * 1440))
            else
                duration_min=1440
            fi
        elif [[ "$dtstart" =~ ^[0-9]{8}T[0-9]{6}$ && "$dtend" =~ ^[0-9]{8}T[0-9]{6}$ ]]; then
            local start_hour=${dtstart:9:2}
            local start_min=${dtstart:11:2}
            local end_hour=${dtend:9:2}
            local end_min=${dtend:11:2}
            local start_total=$((10#$start_hour * 60 + 10#$start_min))
            local end_total=$((10#$end_hour * 60 + 10#$end_min))
            duration_min=$((end_total - start_total))
            [[ $duration_min -lt 0 ]] && duration_min=$((duration_min + 1440))
        else
            duration_min=30
        fi
    elif [[ "$dtstart" =~ ^[0-9]{8}$ ]]; then
        duration_min=1440
    else
        duration_min=30
    fi

    local hash
    hash=$(printf '%s' "${dtstart}|${summary}|${description}|${duration_min}" | sha256sum)
    hash="${hash%% *}"
    echo "${hash:0:16}"
}

_norm_dt_token_for_hash() {
    local v="$1"
    v="${v%Z}"
    v="${v//[[:space:]]/}"
    v="${v//[!0-9T]/}"
    if [[ "$v" =~ ^[0-9]{8}T[0-9]{4}$ ]]; then
        v="${v}00"
    fi
    echo "$v"
}

# ----------------------------------------------------------------------
# HELPERS: normalizzazione EXDATE/DTSTART per confronto e import Calcurse
# ----------------------------------------------------------------------

_norm_dt_token_common() {
    local v="$1"
    v="${v%Z}"
    v="${v//[[:space:]]/}"
    v="${v//[!0-9T]/}"
    if [[ "$v" =~ ^[0-9]{8}T[0-9]{4}$ ]]; then
        v="${v}00"
    fi
    echo "$v"
}

extract_exdates_normalized() {
    local event_block="$1"
    local acc="" line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" == EXDATE* ]] || continue
        local payload="${line#*:}"
        payload="${payload//[[:space:]]/}"
        IFS=',' read -ra parts <<< "$payload"
        local p t
        for p in "${parts[@]}"; do
            t=$(_norm_dt_token_common "$p")
            [[ -n "$t" ]] && acc+="${t}"$'\n'
        done
    done <<< "$event_block"

    if [[ -z "$acc" ]]; then
        echo ""
        return 0
    fi

    local -a sorted=()
    mapfile -t sorted < <(printf '%s' "$acc" | sort -u)
    local IFS=,
    echo "${sorted[*]}"
}

generate_recurrence_signature() {
    local event_block="$1"
    local dtstart="" summary="" rrule="" line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            DTSTART*) [[ -z "$dtstart" ]] && dtstart="${line#*:}" ;;
            SUMMARY:*) [[ -z "$summary" ]] && summary="${line#SUMMARY:}" ;;
            RRULE:*) [[ -z "$rrule" ]] && rrule="${line#RRULE:}" ;;
        esac
    done <<< "$event_block"

    dtstart=$(_norm_dt_token_common "$dtstart")
    [[ -n "$rrule" ]] && rrule=$(normalize_rrule_for_comparison "$rrule")
    echo "${dtstart}|${summary}|${rrule}"
}

sanitize_event_block_for_calcurse() {
    # Backward-compatible wrapper:
    # older parts of the script call this function, so keep the name,
    # but delegate to the newer, stricter sanitizer.
    sanitize_vevent_for_calcurse "$1"
}

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
    declare -A proton_events_by_key
    declare -A proton_uid_by_key
    declare -A proton_summary_by_key
    declare -A proton_dtstart_by_key
    declare -A proton_hash_by_key
    declare -A calcurse_uid_by_key
    declare -A calcurse_summary_by_key
    declare -A calcurse_dtstart_by_key
    declare -A calcurse_hash_by_key

    local block="" in_event=0 proton_count=0
    local uid="" summary="" dtstart=""

    # Indicizzazione eventi Proton
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
            uid=""
            summary=""
            dtstart=""
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local hash=$(compute_event_hash "$block")
            local key=$(generate_event_key "$block")
            proton_hashes["$hash"]=1
            proton_hash_by_key["$key"]="$hash"
            proton_events_by_key["$key"]=1

            if [[ -n "$uid" ]]; then
                proton_uids["$uid"]=1
                proton_uid_by_key["$key"]="$uid"
            fi
            if [[ -n "$summary" ]]; then
                proton_summaries["$summary"]="$dtstart"
                proton_summary_by_key["$key"]="$summary"
            fi
            [[ -n "$dtstart" ]] && proton_dtstart_by_key["$key"]="$dtstart"

            ((proton_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
            case "$line" in
                UID:*)
                    [[ -z "$uid" ]] && uid="${line#UID:}"
                    uid="${uid//$'\r'/}"
                    uid="${uid// /}"
                    ;;
                SUMMARY:*)
                    [[ -z "$summary" ]] && summary="${line#SUMMARY:}"
                    summary="${summary//$'\r'/}"
                    ;;
                DTSTART*)
                    if [[ -z "$dtstart" ]]; then
                        dtstart="${line#*:}"
                        dtstart="${dtstart//$'\r'/}"
                        dtstart="${dtstart// /}"
                    fi
                    ;;
            esac
        fi
    done < "$proton_tmp"

    cat > "$out_tmp" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//calcurse-sync//Nuovi Eventi//
EOF

    local new_count=0
    block="" in_event=0
    uid="" summary="" dtstart=""

    # Ricerca nuovi eventi in Calcurse
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
            uid=""
            summary=""
            dtstart=""
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local is_duplicate=0

            # FIX: Check per chiave univoca PRIMA (priorità massima)
            local key=$(generate_event_key "$block")
            local hash=$(compute_event_hash "$block")
            calcurse_hash_by_key["$key"]="$hash"
            [[ -n "$uid" ]] && calcurse_uid_by_key["$key"]="$uid"
            [[ -n "$summary" ]] && calcurse_summary_by_key["$key"]="$summary"
            [[ -n "$dtstart" ]] && calcurse_dtstart_by_key["$key"]="$dtstart"
            if [[ -n "${proton_events_by_key[$key]}" ]]; then
                is_duplicate=1
            else
                # Fallback su hash se chiave non matcha
                if [[ -n "${proton_hashes[$hash]}" ]]; then
                    is_duplicate=1
                else
                    local cached_uid="${calcurse_uid_by_key[$key]}"
                    local cached_summary="${calcurse_summary_by_key[$key]}"
                    local cached_dtstart="${calcurse_dtstart_by_key[$key]}"
                    if [[ -n "$cached_uid" && -n "${proton_uids[$cached_uid]}" ]]; then
                        is_duplicate=1
                    else
                        if [[ -n "$cached_summary" && -n "${proton_summaries[$cached_summary]}" ]]; then
                            local proton_dtstart="${proton_summaries[$cached_summary]}"
                            if [[ "${cached_dtstart:0:8}" == "${proton_dtstart:0:8}" ]]; then
                                is_duplicate=1
                            fi
                        fi
                    fi
                fi
            fi

            if [[ $is_duplicate -eq 0 ]]; then
                local enriched_block=$(enrich_event_for_proton "$block")
                local cleaned_block
                cleaned_block=$(clean_event_rrules_for_proton "$enriched_block")

                local normalized_event=$(normalize_alarms "$cleaned_block" "proton")
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMTRIGGER/BEGIN:VALARM\nTRIGGER/g')
                normalized_event=$(echo "$normalized_event" | sed 's/BEGIN:VALARMACTION/BEGIN:VALARM\nACTION/g')

                echo "$normalized_event" >> "$out_tmp"
                ((new_count++))

                echo "➕ New event: $summary ($dtstart)"
            fi

            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
            case "$line" in
                UID:*)
                    [[ -z "$uid" ]] && uid="${line#UID:}"
                    uid="${uid//$'\r'/}"
                    uid="${uid// /}"
                    ;;
                SUMMARY:*)
                    [[ -z "$summary" ]] && summary="${line#SUMMARY:}"
                    summary="${summary//$'\r'/}"
                    ;;
                DTSTART*)
                    if [[ -z "$dtstart" ]]; then
                        dtstart="${line#*:}"
                        dtstart="${dtstart//$'\r'/}"
                        dtstart="${dtstart// /}"
                    fi
                    ;;
            esac
        fi
    done < "$calcurse_tmp"

    echo "END:VCALENDAR" >> "$out_tmp"

    sed '/^$/d' "$out_tmp" > "$output_file"
    rm -f "$proton_tmp" "$calcurse_tmp" "$out_tmp"
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

    local comparison_export="$EXPORT_FILE"
    local dry_run_export=""
    if [[ $DRY_RUN -eq 1 ]]; then
        dry_run_export=$(mktemp) || die "Unable to create temporary dry-run export"
        comparison_export="$dry_run_export"
    fi
    export_calcurse_with_uids "$comparison_export"

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
            rm -f "$dry_run_export"
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
                rm -f "$dry_run_export"
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
    awk '/^BEGIN:VEVENT/,/^END:VEVENT/' "$comparison_export" | tr -d '\r' > "$calcurse_tmp"

    # Indicizzazione Proton
    declare -A proton_events
    declare -A proton_blocks
    declare -A proton_uids_to_keys
    declare -A proton_uid_by_key
    declare -A proton_dtstart_line_by_key
    declare -A proton_recurrence_sig_by_key
    declare -A proton_alarm_state_key_by_key

    local block=""
    local in_event=0
    local proton_count=0
    local event_summary="" event_uid="" event_dtstart="" event_dtstart_line="" event_rrule=""

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
            event_summary=""
            event_uid=""
            event_dtstart=""
            event_dtstart_line=""
            event_rrule=""
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local key recurrence_sig
            build_event_identity_from_metadata "$event_uid" "$event_dtstart" "$event_summary" "$event_rrule" key recurrence_sig

            proton_events["$key"]="${event_summary}||${event_uid}"
            proton_blocks["$key"]="$block"
            proton_uid_by_key["$key"]="$event_uid"
            proton_dtstart_line_by_key["$key"]="$event_dtstart_line"
            proton_recurrence_sig_by_key["$key"]="$recurrence_sig"
            proton_alarm_state_key_by_key["$key"]="$(alarm_state_key "$block")"
            [[ -n "$event_uid" ]] && proton_uids_to_keys["$event_uid"]="$key"

            ((proton_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
            case "$line" in
                SUMMARY:*) [[ -z "$event_summary" ]] && event_summary="${line#SUMMARY:}" ;;
                UID:*) [[ -z "$event_uid" ]] && event_uid="${line#UID:}" ;;
                DTSTART*) [[ -z "$event_dtstart_line" ]] && {
                    event_dtstart_line="$line"
                    event_dtstart="${line#*:}"
                } ;;
                RRULE:*) [[ -z "$event_rrule" ]] && event_rrule="${line#RRULE:}" ;;
            esac
        fi
    done < "$proton_tmp"

    # Indicizzazione Calcurse
    declare -A calcurse_events
    declare -A calcurse_blocks
    declare -A calcurse_uids_to_keys
    declare -A calcurse_uid_by_key
    declare -A calcurse_dtstart_line_by_key
    declare -A calcurse_recurrence_sig_by_key

    block=""
    in_event=0
    local calcurse_count=0
    event_summary=""
    event_uid=""
    event_dtstart=""
    event_dtstart_line=""
    event_rrule=""

    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
            event_summary=""
            event_uid=""
            event_dtstart=""
            event_dtstart_line=""
            event_rrule=""
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local key recurrence_sig
            build_event_identity_from_metadata "$event_uid" "$event_dtstart" "$event_summary" "$event_rrule" key recurrence_sig

            calcurse_events["$key"]="${event_summary}||${event_uid}"
            calcurse_blocks["$key"]="$block"
            calcurse_uid_by_key["$key"]="$event_uid"
            calcurse_dtstart_line_by_key["$key"]="$event_dtstart_line"
            calcurse_recurrence_sig_by_key["$key"]="$recurrence_sig"
            [[ -n "$event_uid" ]] && calcurse_uids_to_keys["$event_uid"]="$key"

            ((calcurse_count++))
            in_event=0
            block=""
        elif (( in_event )); then
            block+=$'\n'"$line"
            case "$line" in
                SUMMARY:*) [[ -z "$event_summary" ]] && event_summary="${line#SUMMARY:}" ;;
                UID:*) [[ -z "$event_uid" ]] && event_uid="${line#UID:}" ;;
                DTSTART*) [[ -z "$event_dtstart_line" ]] && {
                    event_dtstart_line="$line"
                    event_dtstart="${line#*:}"
                } ;;
                RRULE:*) [[ -z "$event_rrule" ]] && event_rrule="${line#RRULE:}" ;;
            esac
        fi
    done < "$calcurse_tmp"

    echo "🔍 Pre-computing content hashes for fast comparison..."

    declare -A calcurse_hashes_map
    declare -A proton_hashes_map
    declare -A calcurse_hash_by_key
    declare -A proton_hash_by_key

    for key in "${!calcurse_events[@]}"; do
        local hash=$(compute_event_hash "${calcurse_blocks[$key]}")
        calcurse_hash_by_key["$key"]="$hash"
        calcurse_hashes_map["$hash"]="$key"
    done

    for key in "${!proton_events[@]}"; do
        local hash=$(compute_event_hash "${proton_blocks[$key]}")
        proton_hash_by_key["$key"]="$hash"
        proton_hashes_map["$hash"]="$key"
    done

    echo "✅ Hash maps created (${#calcurse_hashes_map[@]} + ${#proton_hashes_map[@]} entries)"
    echo ""

    # Array per tracciare le decisioni
    declare -a events_to_import_to_calcurse
    declare -a events_to_delete_from_calcurse
    declare -a events_to_export_to_proton
    local unresolved_difference_count=0
    # ============================================================
    # EXDATE: gestisci le eccezioni sulle ricorrenze (cancellazione singola occorrenza)
    # ============================================================
    declare -A exdate_conflicts_by_id
    local exdate_conflict_count=0
    local us=$'\x1f'

    # Mappa firma ricorrenza → key (fallback quando UID differisce)
    declare -A calcurse_sig_to_key
    for ckey in "${!calcurse_events[@]}"; do
        local csig="${calcurse_recurrence_sig_by_key[$ckey]}"
        [[ -n "$csig" ]] && calcurse_sig_to_key["$csig"]="$ckey"
    done

    # Reuse one canonical match for EXDATE and alarm decisions.
    declare -A proton_to_calcurse
    for pkey in "${!proton_events[@]}"; do
        local pblock="${proton_blocks[$pkey]}"
        local ckey="" puid=""

        if [[ -n "${calcurse_events[$pkey]}" ]]; then
            ckey="$pkey"
        else
            puid="${proton_uid_by_key[$pkey]}"
            if [[ -n "$puid" && -n "${calcurse_uids_to_keys[$puid]}" ]]; then
                ckey="${calcurse_uids_to_keys[$puid]}"
            fi
        fi

        local psig="${proton_recurrence_sig_by_key[$pkey]}"
        if [[ -z "$ckey" && -n "$psig" ]]; then
            [[ -n "${calcurse_sig_to_key[$psig]}" ]] && ckey="${calcurse_sig_to_key[$psig]}"
        fi

        if [[ -z "$ckey" ]]; then
            local proton_hash="${proton_hash_by_key[$pkey]}"
            [[ -n "${calcurse_hashes_map[$proton_hash]}" ]] && ckey="${calcurse_hashes_map[$proton_hash]}"
        fi

        [[ -n "$ckey" ]] && proton_to_calcurse["$pkey"]="$ckey"
    done

    declare -A previous_alarm_state
    declare -A alarm_state_overrides
    local alarm_state_loaded=0
    load_alarm_state previous_alarm_state
    local alarm_state_load_status=$?
    if [[ $alarm_state_load_status -eq 0 ]]; then
        alarm_state_loaded=1
    elif [[ $alarm_state_load_status -eq 2 ]]; then
        echo "⚠️  Alarm state is invalid and will be rebuilt without inferring removals."
    fi

    declare -A previous_event_state
    declare -A next_event_state
    local event_state_loaded=0
    load_event_state previous_event_state
    local event_state_load_status=$?
    if [[ $event_state_load_status -eq 0 ]]; then
        event_state_loaded=1
    elif [[ $event_state_load_status -eq 2 ]]; then
        echo "⚠️  Event state is invalid and will be rebuilt without inferring deletions."
    fi

    # Migration fallback for events exported before event-state.tsv existed.
    # A matching UID in the current Proton export confirms that the old export
    # was actually imported, so it is safe to offer the deletion workflow.
    declare -A previously_exported_uids
    if [[ -f "$NEW_EVENTS_FILE" ]]; then
        while IFS= read -r line; do
            line="${line%$'\r'}"
            [[ "$line" == UID:* ]] || continue
            local exported_uid="${line#UID:}"
            [[ -n "$exported_uid" ]] && previously_exported_uids["$exported_uid"]=1
        done < "$NEW_EVENTS_FILE"
    fi

    for pkey in "${!proton_to_calcurse[@]}"; do
        next_event_state["${proton_alarm_state_key_by_key[$pkey]}"]=1
    done

    for pkey in "${!proton_events[@]}"; do
        local pblock="${proton_blocks[$pkey]}"
        local psig="${proton_recurrence_sig_by_key[$pkey]}"
        [[ -n "$psig" ]] || continue

        local puid
        puid="${proton_uid_by_key[$pkey]}"
        local ckey="${proton_to_calcurse[$pkey]}"
        [[ -z "$ckey" ]] && continue

        local pex cex
        pex=$(extract_exdates_normalized "$pblock")
        cex=$(extract_exdates_normalized "${calcurse_blocks[$ckey]}")
        # --- FIX: Normalize both to pure dates (YYYYMMDD) for comparison ---
        # Remove T000000 (and any trailing garbage) to compare just the dates
        # This prevents false conflicts like "20251230" vs "20251230T000000"
        local pex_norm=$(echo "$pex" | sed 's/T[0-9]\{6\}//g' | sed 's/[^0-9,]//g')
        local cex_norm=$(echo "$cex" | sed 's/T[0-9]\{6\}//g' | sed 's/[^0-9,]//g')

        if [[ "$pex_norm" != "$cex_norm" ]]; then
            local id="$puid"
            [[ -z "$id" ]] && id="SIG:$psig"
            exdate_conflicts_by_id["$id"]="${pkey}${us}${ckey}${us}${pex}${us}${cex}"
            ((exdate_conflict_count++))
        fi
    done

    if [[ $exdate_conflict_count -gt 0 ]]; then
        echo "⚠️  Found $exdate_conflict_count recurring event(s) with different exclusions (EXDATE)"
        echo ""

        for id in "${!exdate_conflicts_by_id[@]}"; do
            local rec="${exdate_conflicts_by_id[$id]}"

            local pkey="${rec%%${us}*}"
            rec="${rec#*${us}}"
            local ckey="${rec%%${us}*}"
            rec="${rec#*${us}}"
            local proton_exdate="${rec%%${us}*}"
            local calcurse_exdate="${rec#*${us}}"

            # Recupera informazioni evento
            local pval="${proton_events[$pkey]}"
            local summary="${pval%%||*}"
            local proton_uid="${pval#*||}"

            local cval="${calcurse_events[$ckey]}"
            local calcurse_uid="${cval#*||}"

            # Data/ora di riferimento (DTSTART Proton)
            local event_datetime=""
            local dtstart_line
            dtstart_line="${proton_dtstart_line_by_key[$pkey]}"
            if [[ -n "$dtstart_line" ]]; then
                local v
                v=$(_norm_dt_token_common "${dtstart_line#*:}")
                if [[ "$v" =~ ^[0-9]{8}$ ]]; then
                    event_datetime=$(date -d "${v:0:4}-${v:4:2}-${v:6:2}" "+%d/%m/%Y" 2>/dev/null || echo "$v")
                elif [[ "$v" =~ ^[0-9]{8}T[0-9]{6}$ ]]; then
                    event_datetime=$(date -d "${v:0:4}-${v:4:2}-${v:6:2} ${v:9:2}:${v:11:2}" "+%d/%m/%Y %H:%M" 2>/dev/null || echo "$v")
                else
                    event_datetime="$v"
                fi
            fi

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "⚠️  Recurring event with different exclusions:"
            echo "   📝 Title: ${summary:-[No title]}"
            echo "   📅 Date/Time: ${event_datetime:-$pkey}"
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
                    # Sostituisci in Calcurse: elimina la serie Calcurse e importa quella Proton
                    events_to_delete_from_calcurse+=("$ckey")
                    events_to_import_to_calcurse+=("$pkey")
                    echo "   ✅ Will update Calcurse with Proton's exclusions"
                    ;;
                C)
                    # Esporta la versione Calcurse verso Proton (import manuale)
                    events_to_export_to_proton+=("$ckey")
                    echo "   ✅ Will update Proton with Calcurse's exclusions"
                    ;;
                *)
                    ((unresolved_difference_count++))
                    echo "   ⏭️  Skipped (no changes)"
                    ;;
            esac
        done
        echo ""
    fi

    # Confronto: eventi in Proton ma non in Calcurse
    local proton_only_count=0
    echo "🔍 Checking events present only in Proton..."

    for key in "${!proton_events[@]}"; do
        local found_in_calcurse=0

        # Check 1: Confronto diretto per chiave
        if [[ -n "${calcurse_events[$key]}" ]]; then
            found_in_calcurse=1
        else
            # Check 2: Cerca per UID (se chiave basata su UID o nel blocco)
            if [[ "$key" =~ ^UID: ]]; then
                local proton_uid="${key#UID:}"
                [[ -n "${calcurse_uids_to_keys[$proton_uid]}" ]] && found_in_calcurse=1
            else
                local proton_uid="${proton_uid_by_key[$key]}"
                [[ -n "$proton_uid" && -n "${calcurse_uids_to_keys[$proton_uid]}" ]] && found_in_calcurse=1
            fi

            # Check 3: OTTIMIZZATO - Hash lookup O(1)
            if [[ $found_in_calcurse -eq 0 ]]; then
                local proton_hash="${proton_hash_by_key[$key]}"
                [[ -n "${calcurse_hashes_map[$proton_hash]}" ]] && found_in_calcurse=1
            fi
        fi

        # Se NON trovato dopo tutti i check, è veramente nuovo
        if [[ $found_in_calcurse -eq 0 ]]; then
            local pval="${proton_events[$key]}"; local summary="${pval%%||*}"; local uid="${pval#*||}"
            ((proton_only_count++))
            # Estrai data/ora dal blocco evento
            local event_datetime=""
            local dtstart_line="${proton_dtstart_line_by_key[$key]}"
            if [[ -n "$dtstart_line" ]]; then
                if [[ "$dtstart_line" =~ VALUE=DATE ]]; then
                    # Evento giornata intera
                    local date_only=$(_norm_dt_token_common "${dtstart_line#*:}")
                    event_datetime=$(date -d "${date_only:0:8}" "+%d/%m/%Y" 2>/dev/null || echo "$date_only")
                else
                    # Evento con ora
                    local datetime=$(_norm_dt_token_common "${dtstart_line#*:}")
                    event_datetime=$(date -d "${datetime:0:8} ${datetime:9:2}:${datetime:11:2}" "+%d/%m/%Y %H:%M" 2>/dev/null || echo "$datetime")
                fi
            fi

            local event_state_key="${proton_alarm_state_key_by_key[$key]}"
            local was_previously_synchronized=0
            if [[ $event_state_loaded -eq 1 && -n "${previous_event_state[$event_state_key]}" ]] || \
               [[ -n "$uid" && -n "${previously_exported_uids[$uid]}" ]]; then
                was_previously_synchronized=1
                next_event_state["$event_state_key"]=1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            if [[ $was_previously_synchronized -eq 1 ]]; then
                echo "🗑️  Previously synchronized event no longer present in Calcurse:"
            else
                echo "📝 Event #$proton_only_count present in Proton but not in Calcurse:"
            fi
            echo "   📝 Title: ${summary:-[Senza titolo]}"
            echo "   📅 Date/Time: ${event_datetime:-$key}"
            echo "   🆔 UID: $uid"
            echo ""

            if [[ $was_previously_synchronized -eq 1 ]]; then
                echo "   R) Restore it by importing it into Calcurse"
                echo "   Press Enter to postpone and ask again next time"
                echo ""
                read -rp "   Choice (R, Enter to postpone): " deletion_choice

                if [[ "${deletion_choice^^}" == "R" ]]; then
                    events_to_import_to_calcurse+=("$key")
                    echo "   ✅ It will be restored in Calcurse"
                else
                    ((unresolved_difference_count++))
                    echo "   ⏭️  Decision postponed"
                fi
            else
                read -rp "   ➡️  Do you want to import it into Calcurse? (y/N): " import_choice

                if [[ "$import_choice" =~ ^[sSyY]$ ]]; then
                    events_to_import_to_calcurse+=("$key")
                    next_event_state["$event_state_key"]=1
                    echo "   ✅ It will be imported in Calcurse"
                else
                    ((unresolved_difference_count++))
                    echo "   ⏭️  Skipped (remains only in Proton)"
                fi
            fi
        fi
    done

    # Confronto: eventi in Calcurse ma non in Proton
    local calcurse_only_count=0
    echo ""
    #echo "🔍 Verifico eventi presenti solo in Calcurse..."

    for key in "${!calcurse_events[@]}"; do
        local found_in_proton=0

        # Check 1: Confronto diretto
        if [[ -n "${proton_events[$key]}" ]]; then
            found_in_proton=1
        else
            # Check 2: Cerca per UID
            if [[ "$key" =~ ^UID: ]]; then
                local calcurse_uid="${key#UID:}"
                [[ -n "${proton_uids_to_keys[$calcurse_uid]}" ]] && found_in_proton=1
            else
                local calcurse_uid="${calcurse_uid_by_key[$key]}"
                [[ -n "$calcurse_uid" && -n "${proton_uids_to_keys[$calcurse_uid]}" ]] && found_in_proton=1
            fi

            # Check 3: Hash lookup O(1)
            if [[ $found_in_proton -eq 0 ]]; then
                local calcurse_hash="${calcurse_hash_by_key[$key]}"
                [[ -n "${proton_hashes_map[$calcurse_hash]}" ]] && found_in_proton=1
            fi
        fi

        if [[ $found_in_proton -eq 0 ]]; then
            ((calcurse_only_count++))
            local cval="${calcurse_events[$key]}"; local summary="${cval%%||*}"; local uid="${cval#*||}"
            # Estrai data/ora dal blocco evento
			local event_datetime=""
			local dtstart_line="${calcurse_dtstart_line_by_key[$key]}"
			if [[ -n "$dtstart_line" ]]; then
				if [[ "$dtstart_line" =~ VALUE=DATE ]]; then
					# Evento giornata intera
					local date_only=$(_norm_dt_token_common "${dtstart_line#*:}")
					event_datetime=$(date -d "${date_only:0:8}" "+%d/%m/%Y" 2>/dev/null || echo "$date_only")
				else
					# Evento con ora
					local datetime=$(_norm_dt_token_common "${dtstart_line#*:}")
					event_datetime=$(date -d "${datetime:0:8} ${datetime:9:2}:${datetime:11:2}" "+%d/%m/%Y %H:%M" 2>/dev/null || echo "$datetime")
				fi
			fi

			echo ""
			echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
			echo "📝 Event #$calcurse_only_count present in Calcurse but not in Proton:"
			echo "   📝 Title: ${summary:-[Senza titolo]}"
			echo "   📅 Date/Time: ${event_datetime:-$key}"
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
                    local exported_event_state_key
                    exported_event_state_key=$(alarm_state_key "${calcurse_blocks[$key]}")
                    next_event_state["$exported_event_state_key"]=1
                    echo "   ✅ It will be added to Proton"
                    ;;
                *)
                    ((unresolved_difference_count++))
                    echo "   ⏭️  Skipped (no changes)"
                    ;;
            esac
        fi
    done

    # Find matched timed appointments that have a compatible Proton alarm but
    # no Calcurse notification. Events already scheduled for replacement are
    # excluded because importing the Proton block will carry the alarm.
    declare -A alarm_backfill_candidates
    declare -A alarm_backfills_to_apply
    declare -A scheduled_calcurse_deletions
    declare -A scheduled_proton_imports

    for ckey in "${events_to_delete_from_calcurse[@]}"; do
        scheduled_calcurse_deletions["$ckey"]=1
    done
    for pkey in "${events_to_import_to_calcurse[@]}"; do
        scheduled_proton_imports["$pkey"]=1
    done

    declare -A alarm_removal_candidates
    declare -A alarm_removals_to_apply

    if [[ $alarm_state_loaded -eq 1 ]]; then
        for pkey in "${!proton_events[@]}"; do
            local pblock="${proton_blocks[$pkey]}"
            event_is_timed "$pblock" || continue

            local state_key="${proton_alarm_state_key_by_key[$pkey]}"
            [[ "${previous_alarm_state[$state_key]}" == "1" ]] || continue

            local proton_alarm_trigger
            proton_alarm_trigger=$(extract_compatible_display_alarm_trigger "$pblock")
            [[ -z "$proton_alarm_trigger" ]] || continue

            local ckey="${proton_to_calcurse[$pkey]}"
            [[ -n "$ckey" ]] || continue
            [[ -z "${scheduled_calcurse_deletions[$ckey]}" ]] || continue
            [[ -z "${scheduled_proton_imports[$pkey]}" ]] || continue

            local calcurse_alarm_trigger
            calcurse_alarm_trigger=$(extract_compatible_display_alarm_trigger "${calcurse_blocks[$ckey]}")
            [[ -n "$calcurse_alarm_trigger" ]] || continue

            alarm_removal_candidates["$ckey"]="${pkey}${us}${state_key}"
        done
    fi

    if [[ ${#alarm_removal_candidates[@]} -gt 0 ]]; then
        echo ""
        echo "🔕 Found ${#alarm_removal_candidates[@]} appointment(s) whose Proton notification was removed"
        echo "   These removals were detected from the previous successful sync."

        for ckey in "${!alarm_removal_candidates[@]}"; do
            local candidate="${alarm_removal_candidates[$ckey]}"
            local candidate_pkey="${candidate%%${us}*}"
            local candidate_state_key="${candidate#*${us}}"
            local pval="${proton_events[$candidate_pkey]}"
            local candidate_summary="${pval%%||*}"
            local dtstart_line candidate_start
            dtstart_line="${proton_dtstart_line_by_key[$candidate_pkey]}"
            candidate_start=$(_norm_dt_token_common "${dtstart_line#*:}")

            echo ""
            echo "   📝 ${candidate_summary:-[No title]}"
            echo "   📅 $candidate_start"
            echo "   R) Remove the notification from Calcurse"
            echo "   K) Keep it in Calcurse and accept the difference"
            echo "   S) Postpone and ask again next time"
            read -rp "   Choice (R/K/S): " alarm_removal_choice

            case "${alarm_removal_choice^^}" in
                R)
                    alarm_removals_to_apply["$ckey"]=1
                    echo "   ✅ The Calcurse notification will be removed"
                    ;;
                K)
                    echo "   ✅ The Calcurse notification will be kept"
                    ;;
                *)
                    alarm_state_overrides["$candidate_state_key"]=1
                    ((unresolved_difference_count++))
                    echo "   ⏭️  Decision postponed"
                    ;;
            esac
        done
    fi

    for pkey in "${!proton_events[@]}"; do
        local pblock="${proton_blocks[$pkey]}"
        event_is_timed "$pblock" || continue

        local proton_alarm_trigger
        proton_alarm_trigger=$(extract_compatible_display_alarm_trigger "$pblock")
        [[ -n "$proton_alarm_trigger" ]] || continue

        local ckey="${proton_to_calcurse[$pkey]}"

        [[ -n "$ckey" ]] || continue
        [[ -z "${scheduled_calcurse_deletions[$ckey]}" ]] || continue
        [[ -z "${scheduled_proton_imports[$pkey]}" ]] || continue

        local calcurse_alarm_trigger
        calcurse_alarm_trigger=$(extract_compatible_display_alarm_trigger "${calcurse_blocks[$ckey]}")
        [[ -z "$calcurse_alarm_trigger" ]] || continue

        alarm_backfill_candidates["$ckey"]="${pkey}${us}${proton_alarm_trigger}"
    done

    if [[ ${#alarm_backfill_candidates[@]} -gt 0 ]]; then
        echo ""
        echo "🔔 Found ${#alarm_backfill_candidates[@]} matching appointment(s) with a missing Calcurse notification"
        echo "   Calcurse will use its global notification.warning value."
        echo ""
        echo "   A) Add all missing notifications"
        echo "   R) Review appointments individually"
        echo "   S) Skip notification backfill"
        echo ""
        read -rp "   Choice (A/R/S): " alarm_backfill_choice

        case "${alarm_backfill_choice^^}" in
            A)
                for ckey in "${!alarm_backfill_candidates[@]}"; do
                    local candidate="${alarm_backfill_candidates[$ckey]}"
                    alarm_backfills_to_apply["$ckey"]="${candidate#*${us}}"
                done
                ;;
            R)
                for ckey in "${!alarm_backfill_candidates[@]}"; do
                    local candidate="${alarm_backfill_candidates[$ckey]}"
                    local candidate_pkey="${candidate%%${us}*}"
                    local candidate_trigger="${candidate#*${us}}"
                    local pval="${proton_events[$candidate_pkey]}"
                    local candidate_summary="${pval%%||*}"
                    local dtstart_line
                    dtstart_line="${proton_dtstart_line_by_key[$candidate_pkey]}"
                    local candidate_start
                    candidate_start=$(_norm_dt_token_common "${dtstart_line#*:}")

                    echo ""
                    echo "   📝 ${candidate_summary:-[No title]}"
                    echo "   📅 $candidate_start"
                    read -rp "   Add Calcurse notification? (y/N): " add_alarm_choice
                    if [[ "$add_alarm_choice" =~ ^[sSyY]$ ]]; then
                        alarm_backfills_to_apply["$ckey"]="$candidate_trigger"
                    else
                        ((unresolved_difference_count++))
                    fi
                done
                ;;
            *)
                unresolved_difference_count=$((unresolved_difference_count + ${#alarm_backfill_candidates[@]}))
                echo "   ⏭️  Notification backfill skipped"
                ;;
        esac

        if [[ ${#alarm_backfills_to_apply[@]} -gt 0 ]]; then
            echo "   ✅ Will add ${#alarm_backfills_to_apply[@]} Calcurse notification(s)"
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Riepilogo decisioni
    if [[ ${#events_to_import_to_calcurse[@]} -eq 0 ]] && \
       [[ ${#events_to_delete_from_calcurse[@]} -eq 0 ]] && \
       [[ ${#events_to_export_to_proton[@]} -eq 0 ]] && \
       [[ ${#alarm_backfills_to_apply[@]} -eq 0 ]] && \
       [[ ${#alarm_removals_to_apply[@]} -eq 0 ]]; then
        if [[ $unresolved_difference_count -gt 0 ]]; then
            echo "ℹ️  No changes were selected."
            echo "⚠️  The calendars are not fully synchronized:"
            echo "   $unresolved_difference_count unresolved difference(s) remain."
        else
            echo "✅ No changes to apply. The calendars are synchronized!"
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "🧪 DRY RUN COMPLETE: no files, state, or Calcurse data were modified."
        else
            if ! save_alarm_state proton_blocks alarm_state_overrides proton_alarm_state_key_by_key; then
                warn "The alarm state could not be updated."
            fi
            if ! save_event_state next_event_state; then
                warn "The event state could not be updated."
            fi
        fi
        rm -f "$proton_tmp" "$calcurse_tmp" "$dry_run_export"
        return 0
    fi

    echo "📋 Summary of changes:"
    echo ""

    if [[ ${#events_to_import_to_calcurse[@]} -gt 0 ]]; then
        echo "📥 Events to import into Calcurse: ${#events_to_import_to_calcurse[@]}"
        for key in "${events_to_import_to_calcurse[@]}"; do
            local pval="${proton_events[$key]}"; local summary="${pval%%||*}"; local uid="${pval#*||}"
            local dtstart_display="${key%%::*}"
            echo "   • ${summary:-[Senza titolo]} ($dtstart_display)"
        done
        echo ""
    fi

    if [[ ${#events_to_delete_from_calcurse[@]} -gt 0 ]]; then
        echo "🗑️  Events to delete from Calcurse: ${#events_to_delete_from_calcurse[@]}"
        for key in "${events_to_delete_from_calcurse[@]}"; do
            local cval="${calcurse_events[$key]}"; local summary="${cval%%||*}"; local uid="${cval#*||}"
            local dtstart_display="${key%%::*}"
            echo "   • ${summary:-[Senza titolo]} ($dtstart_display)"
        done
        echo ""
    fi

    if [[ ${#events_to_export_to_proton[@]} -gt 0 ]]; then
        echo "📤 Events to export to Proton: ${#events_to_export_to_proton[@]}"
        for key in "${events_to_export_to_proton[@]}"; do
            local cval="${calcurse_events[$key]}"; local summary="${cval%%||*}"; local uid="${cval#*||}"
            local dtstart_display="${key%%::*}"
            echo "   • ${summary:-[Senza titolo]} ($dtstart_display)"
        done
        echo ""
    fi

    if [[ ${#alarm_backfills_to_apply[@]} -gt 0 ]]; then
        echo "🔔 Missing notifications to add: ${#alarm_backfills_to_apply[@]}"
        echo ""
    fi

    if [[ ${#alarm_removals_to_apply[@]} -gt 0 ]]; then
        echo "🔕 Notifications to remove from Calcurse: ${#alarm_removals_to_apply[@]}"
        echo ""
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "🧪 DRY RUN COMPLETE: the changes above were not applied."
        echo "   No files or Calcurse data were modified."
        rm -f "$proton_tmp" "$calcurse_tmp" "$dry_run_export"
        return 0
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

    # Apply every Calcurse-side decision as one validated database replacement.
    if [[ ${#events_to_delete_from_calcurse[@]} -gt 0 ]] || \
       [[ ${#events_to_import_to_calcurse[@]} -gt 0 ]] || \
       [[ ${#alarm_backfills_to_apply[@]} -gt 0 ]] || \
       [[ ${#alarm_removals_to_apply[@]} -gt 0 ]]; then
        echo ""
        echo "🔄 Preparing atomic Calcurse update..."

        declare -A to_delete
        declare -A to_import

        for key in "${events_to_delete_from_calcurse[@]}"; do
            to_delete["$key"]=1
        done
        for key in "${events_to_import_to_calcurse[@]}"; do
            to_import["$key"]=1
        done

        local target_calendar
        target_calendar=$(mktemp) || die "Unable to create temporary target calendar"

        echo "BEGIN:VCALENDAR" > "$target_calendar"
        echo "VERSION:2.0" >> "$target_calendar"
        echo "PRODID:-//calcurse-sync//Atomic target//" >> "$target_calendar"

        block=""
        in_event=0
        local event_count=0
        local kept_count=0
        local deleted_count=0
        local imported_count=0
        local backfilled_count=0
        local removed_notification_count=0

        while IFS= read -r line; do
            if [[ "$line" == "BEGIN:VEVENT" ]]; then
                block="$line"
                in_event=1
            elif [[ "$line" == "END:VEVENT" ]]; then
                block+=$'\n'"$line"
                ((event_count++))

                local current_key
                current_key=$(generate_event_key "$block")

                if [[ -z "${to_delete[$current_key]}" ]]; then
                    if [[ -n "${alarm_backfills_to_apply[$current_key]}" ]]; then
                        block=$(add_display_alarm_to_event "$block" "${alarm_backfills_to_apply[$current_key]}")
                        ((backfilled_count++))
                    fi
                    if [[ -n "${alarm_removals_to_apply[$current_key]}" ]]; then
                        block=$(remove_alarms_from_event "$block")
                        ((removed_notification_count++))
                    fi
                    printf '%s\n' "$block" >> "$target_calendar"
                    ((kept_count++))
                else
                    ((deleted_count++))
                fi

                in_event=0
                block=""
            elif (( in_event )); then
                block+=$'\n'"$line"
            fi
        done < "$calcurse_tmp"

        for key in "${!to_import[@]}"; do
            printf '%s\n' "${proton_blocks[$key]}" >> "$target_calendar"
            ((imported_count++))
        done

        echo "END:VCALENDAR" >> "$target_calendar"

        echo "Processing summary:"
        echo "  - Existing events processed: $event_count"
        echo "  - Existing events kept: $kept_count"
        echo "  - Existing events deleted: $deleted_count"
        echo "  - Proton events imported: $imported_count"
        echo "  - Notifications added: $backfilled_count"
        echo "  - Notifications removed: $removed_notification_count"

        if ! replace_calcurse_events_atomically "$target_calendar"; then
            rm -f "$target_calendar"
            die "Atomic Calcurse update failed; the original database is unchanged"
        fi

        rm -f "$target_calendar"
        echo "✅ Calcurse update completed"
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
            # Aggiungi COLOR per BnB
            event_block=$(add_bnb_color "$event_block")

            # Pulisci RRULE usando anche il contesto DTSTART/TZID.
            local cleaned_block
            cleaned_block=$(clean_event_rrules_for_proton "$event_block")

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
    if [[ ${#events_to_import_to_calcurse[@]} -gt 0 ]] || \
       [[ ${#events_to_delete_from_calcurse[@]} -gt 0 ]] || \
       [[ ${#alarm_backfills_to_apply[@]} -gt 0 ]] || \
       [[ ${#alarm_removals_to_apply[@]} -gt 0 ]]; then
        echo ""
        echo "🔄 Updating Calcurse export..."
        export_calcurse_with_uids
    fi

    if ! save_alarm_state proton_blocks alarm_state_overrides proton_alarm_state_key_by_key; then
        warn "Synchronization succeeded, but the alarm state could not be updated."
    fi
    if ! save_event_state next_event_state; then
        warn "Synchronization succeeded, but the event state could not be updated."
    fi

    # Pulizia
    clean_old_backups
    rm -f "$proton_tmp" "$calcurse_tmp"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ SELECTED CHANGES COMPLETED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 Summary:"
    echo "   • Events imported into Calcurse: ${#events_to_import_to_calcurse[@]}"
    echo "   • Events deleted from Calcurse: ${#events_to_delete_from_calcurse[@]}"
    echo "   • Notifications added to Calcurse: ${#alarm_backfills_to_apply[@]}"
    echo "   • Notifications removed from Calcurse: ${#alarm_removals_to_apply[@]}"
    echo "   • Events to import into Proton: ${#events_to_export_to_proton[@]}"
    echo ""
    if [[ $unresolved_difference_count -gt 0 ]]; then
        echo "⚠️  The calendars are not fully synchronized:"
        echo "   $unresolved_difference_count unresolved difference(s) remain."
    elif [[ ${#events_to_export_to_proton[@]} -gt 0 ]]; then
        echo "ℹ️  Synchronization will be complete after importing $NEW_EVENTS_FILE into Proton."
    else
        echo "✅ The calendars are synchronized."
    fi
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
    declare -A calcurse_events_by_key

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
            local key=$(generate_event_key "$block")
            calcurse_events_by_key["$key"]=1
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

    # Loop di confronto eventi da Proton
    while IFS= read -r line; do
        if [[ "$line" == "BEGIN:VEVENT" ]]; then
            block="$line"
            in_event=1
        elif [[ "$line" == "END:VEVENT" ]]; then
            block+=$'\n'"$line"

            local should_import=1

            # FIX: Check chiave univoca PRIMA (priorità massima)
            local key=$(generate_event_key "$block")
            if [[ -n "${calcurse_events_by_key[$key]}" ]]; then
                should_import=0
            else
                # Fallback su hash se chiave non matcha
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
        local new_events_sanitized=$(mktemp)
sanitize_calendar_for_calcurse_import "$new_events_for_calcurse" "$new_events_sanitized"
calcurse -D "$CALCURSE_DIR" -i "$new_events_sanitized" || die "Import failed"
rm -f "$new_events_sanitized"

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
    echo ""
    echo "⚠️  WARNING: This option is intended for INITIAL MIGRATION only!"
    echo "    • First time moving from Calcurse to Proton: ✅ Safe"
    echo "    • Already synced before: ❌ Will create DUPLICATES"
    echo "    • Modified recurring events (EXDATE): ❌ NOT handled"
    echo ""
    echo "    💡 For regular sync, use Option A (Interactive Sync) instead."
    echo ""
    read -rp "    Is this your FIRST export to Proton? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "❌ Export cancelled. Use Option A for regular synchronization."
        return 1
    fi
    echo ""
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
    echo ""
    echo "⚠️  WARNING: Same limitations as Option C:"
    echo "    • Intended for INITIAL/PARTIAL migration only"
    echo "    • Will create duplicates if events already in Proton"
    echo "    • Does NOT handle EXDATE modifications"
    echo "    • Filters to next 30 days only"
    echo ""
    echo "    💡 For regular sync, use Option A instead."
    echo ""
    read -rp "    Continue with filtered export? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "❌ Export cancelled."
        return 1
    fi
    echo ""
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
    echo ""
    echo "⚠️  WARNING: Same limitations as Option C/D:"
    echo "    • Intended for INITIAL/PARTIAL migration only"
    echo "    • Will create duplicates if events already in Proton"
    echo "    • Does NOT handle EXDATE modifications"
    echo ""
    echo "    💡 For regular sync, use Option A instead."
    echo ""
    read -rp "    Continue with custom export? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "❌ Export cancelled."
        return 1
    fi

    read -rp "Days in the future to include (default: 90): " days_future
    days_future=${days_future:-90}
    echo ""

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
    echo "🧹  COMPLETE SYNC: Proton → Calcurse"
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

    echo "📥 Importing and validating everything from Proton..."
    if ! replace_calcurse_events_atomically "$IMPORT_FILE"; then
        die "Complete synchronization failed; the original database is unchanged"
    fi

    export_calcurse_with_uids
    clean_old_backups

    echo "✅ Complete synchronization completed!"
    echo "📂 Backup saved: $BACKUP_FILE"
}

echo "🔔 REMEMBER: Make sure you have downloaded the UPDATED file from Proton Calendar"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "🧪 DRY RUN MODE: only guided sync analysis is available; nothing will be modified"
fi
echo "Choose an option:"
echo "A) 🔄 GUIDED BIDIRECTIONAL SYNC: Calcurse ↔ Proton + report"
echo "B) 🧹 COMPLETE SYNC: Proton → Calcurse (REPLACES everything)"
echo "---------"
echo "Q) ❌ Exit without operations"
echo ""

while true; do
    read -rp "Enter A, B or Q: " choice

    case "${choice^^}" in
        A) option_A; break ;;
        B|F)
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "❌ Complete sync is unavailable in dry-run mode. Choose A or Q."
                continue
            fi
            option_F
            break
            ;;  # 'F' kept as a legacy alias
        Q) echo "👋 Goodbye!"; exit 0 ;;
        *) echo "❌ Error: Invalid choice. Use A, B or Q." ;;
    esac
done
