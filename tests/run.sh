#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/calcurse-sync.sh"
FIXTURES="$ROOT_DIR/tests/fixtures"
CALCURSE_BIN=${CALCURSE_BIN:-calcurse}

pass_count=0
fail_count=0
suite_started=$SECONDS
work_root=$(mktemp -d "${TMPDIR:-/tmp}/calcurse-sync-tests.XXXXXX")

cleanup() {
    if [[ "${KEEP_TEST_TMP:-0}" == "1" ]]; then
        printf 'Temporary test data kept at %s\n' "$work_root"
    else
        rm -rf "$work_root"
    fi
}
trap cleanup EXIT

case_dir=""
test_home=""
calcurse_dir=""
backup_dir=""
output_file=""
sync_status=0

begin_case() {
    local name="$1"
    case_dir="$work_root/$name"
    test_home="$case_dir/home"
    calcurse_dir="$test_home/.local/share/calcurse"
    backup_dir="$test_home/Projects/calendar"
    output_file="$case_dir/sync.log"

    mkdir -p "$calcurse_dir" "$backup_dir" "$test_home/.config/calcurse"
    : > "$calcurse_dir/apts"
    : > "$calcurse_dir/todo"
    printf 'notification.warning=600\n' > "$test_home/.config/calcurse/conf"
}

seed_calcurse() {
    local fixture="$1"
    HOME="$test_home" \
    XDG_DATA_HOME="$test_home/.local/share" \
    XDG_CONFIG_HOME="$test_home/.config" \
    "$CALCURSE_BIN" -D "$calcurse_dir" -i "$FIXTURES/$fixture" \
        > "$case_dir/seed.log" 2>&1
}

install_proton_fixture() {
    local fixture="$1"
    cp "$FIXTURES/$fixture" "$backup_dir/My Calendar-test.ics"
}

run_sync() {
    local answers="$1"
    shift
    printf '%s' "$answers" | \
        env HOME="$test_home" \
            XDG_DATA_HOME="$test_home/.local/share" \
            XDG_CONFIG_HOME="$test_home/.config" \
            LC_ALL=C \
            bash "$SCRIPT" "$@" > "$output_file" 2>&1
    sync_status=${PIPESTATUS[1]}
}

export_raw_calcurse() {
    local destination="$1"
    HOME="$test_home" \
    XDG_DATA_HOME="$test_home/.local/share" \
    XDG_CONFIG_HOME="$test_home/.config" \
    "$CALCURSE_BIN" -D "$calcurse_dir" --export > "$destination"
}

count_lines() {
    local pattern="$1"
    local file="$2"
    awk -v pattern="$pattern" '$0 == pattern { count++ } END { print count + 0 }' "$file"
}

assert_status() {
    local expected="$1"
    if [[ "$sync_status" -ne "$expected" ]]; then
        printf 'Expected exit status %s, got %s\n' "$expected" "$sync_status" >&2
        return 1
    fi
}

assert_contains() {
    local file="$1"
    local text="$2"
    if ! grep -Fq -- "$text" "$file"; then
        printf 'Expected %s to contain: %s\n' "$file" "$text" >&2
        return 1
    fi
}

assert_not_contains() {
    local file="$1"
    local text="$2"
    if grep -Fq -- "$text" "$file"; then
        printf 'Expected %s not to contain: %s\n' "$file" "$text" >&2
        return 1
    fi
}

assert_state_value() {
    local expected="$1"
    local state_file="$test_home/.local/state/calcurse-sync/alarm-state.tsv"

    [[ -f "$state_file" ]] || {
        printf 'Alarm state file was not created: %s\n' "$state_file" >&2
        return 1
    }
    if ! awk -F '\t' -v expected="$expected" '
        NR == 1 { valid_header = ($1 == "calcurse-sync-alarm-state" && $2 == "1"); next }
        NF == 2 && $2 == expected { matches++ }
        END { exit(valid_header && matches == 1 ? 0 : 1) }
    ' "$state_file"; then
        printf 'Expected one alarm state entry with value %s\n' "$expected" >&2
        return 1
    fi
}

assert_event_state_count() {
    local expected="$1"
    local state_file="$test_home/.local/state/calcurse-sync/event-state.tsv"

    [[ -f "$state_file" ]] || {
        printf 'Event state file was not created: %s\n' "$state_file" >&2
        return 1
    }
    if ! awk -v expected="$expected" '
        NR == 1 { valid_header = ($0 == "calcurse-sync-event-state\t1"); next }
        length($0) == 32 && $0 ~ /^[0-9a-f]+$/ { matches++; next }
        NF { invalid = 1 }
        END { exit(valid_header && !invalid && matches == expected ? 0 : 1) }
    ' "$state_file"; then
        printf 'Expected %s synchronized event state entries\n' "$expected" >&2
        return 1
    fi
}

assert_line_count() {
    local expected="$1"
    local line="$2"
    local file="$3"
    local actual
    actual=$(count_lines "$line" "$file")
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'Expected %s occurrence(s) of %s in %s, got %s\n' \
            "$expected" "$line" "$file" "$actual" >&2
        return 1
    fi
}

event_has_line() {
    local file="$1"
    local summary="$2"
    local expected_line="$3"

    awk -v summary="SUMMARY:$summary" -v expected="$expected_line" '
        $0 == "BEGIN:VEVENT" { block = ""; in_event = 1 }
        in_event { block = block $0 ORS }
        $0 == "END:VEVENT" {
            if (index(block, summary ORS) && index(block, expected ORS)) {
                found = 1
            }
            in_event = 0
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

event_lacks_line() {
    local file="$1"
    local summary="$2"
    local unexpected_line="$3"

    awk -v summary="SUMMARY:$summary" -v unexpected="$unexpected_line" '
        $0 == "BEGIN:VEVENT" { block = ""; in_event = 1 }
        in_event { block = block $0 ORS }
        $0 == "END:VEVENT" {
            if (index(block, summary ORS)) {
                found = 1
                if (index(block, unexpected ORS)) {
                    bad = 1
                }
            }
            in_event = 0
        }
        END { exit(found && !bad ? 0 : 1) }
    ' "$file"
}

test_proton_import_and_idempotence() {
    begin_case proton_import
    install_proton_fixture proton-new.ics

    run_sync $'A\ny\ny\n'
    assert_status 0 || return 1
    assert_line_count 1 "BEGIN:VEVENT" "$backup_dir/calendario.ics" || return 1
    event_has_line "$backup_dir/calendario.ics" "Proton New Event" "BEGIN:VALARM" || return 1

    local before
    before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    run_sync $'A\ny\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "No changes to apply. The calendars are synchronized!" || return 1

    local after
    after=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    [[ "$before" == "$after" ]] || {
        printf 'The second synchronization changed the Calcurse database\n' >&2
        return 1
    }
}

test_calcurse_export() {
    begin_case calcurse_export
    seed_calcurse calcurse-new.ics || return 1
    install_proton_fixture empty.ics

    run_sync $'A\nB\ny\n'
    assert_status 0 || return 1
    assert_line_count 1 "BEGIN:VEVENT" "$backup_dir/nuovi-appuntamenti-calcurse.ics" || return 1
    assert_contains "$backup_dir/nuovi-appuntamenti-calcurse.ics" "SUMMARY:Calcurse New Event" || return 1
    assert_contains "$backup_dir/nuovi-appuntamenti-calcurse.ics" "UID:CALCURSE-" || return 1
}

test_proton_monthly_byday_normalization() {
    begin_case proton_monthly_byday
    seed_calcurse monthly-byday-calcurse.ics || return 1
    install_proton_fixture empty.ics

    run_sync $'A\nB\ny\n'
    assert_status 0 || return 1
    assert_line_count 1 "BEGIN:VEVENT" "$backup_dir/nuovi-appuntamenti-calcurse.ics" || return 1
    assert_contains "$backup_dir/nuovi-appuntamenti-calcurse.ics" \
        "RRULE:FREQ=WEEKLY;UNTIL=20261101T170000Z;BYDAY=MO" || return 1
}

test_recurring_exdate_and_alarm() {
    begin_case recurring_exdate
    seed_calcurse palestra-calcurse.ics || return 1
    install_proton_fixture palestra-proton-no-fridays.ics

    run_sync $'A\nP\ny\n'
    assert_status 0 || return 1
    assert_line_count 1 "BEGIN:VEVENT" "$backup_dir/calendario.ics" || return 1
    assert_line_count 1 "BEGIN:VALARM" "$backup_dir/calendario.ics" || return 1

    local friday
    for friday in 20300906 20300913 20300920 20300927; do
        assert_contains "$backup_dir/calendario.ics" "$friday" || return 1
    done
}

test_proton_recurrence_export_compatibility() {
    begin_case proton_recurrence_export
    seed_calcurse recurrence-series-proton-exdates.ics || return 1
    install_proton_fixture empty.ics

    run_sync $'A\nB\nB\nB\nB\ny\n'
    assert_status 0 || return 1

    local export_file="$backup_dir/nuovi-appuntamenti-calcurse.ics"
    assert_line_count 4 "BEGIN:VEVENT" "$export_file" || return 1
    if command -v icalendar >/dev/null 2>&1; then
        icalendar "$export_file" >/dev/null || {
            printf 'The generated Proton export is not parseable as iCalendar\n' >&2
            return 1
        }
    fi

    event_has_line "$export_file" "Daily Exclusions" "RRULE:FREQ=DAILY;UNTIL=20300110T080000Z" || return 1
    event_has_line "$export_file" "Weekly Exclusions" "RRULE:FREQ=WEEKLY;UNTIL=20300204T090000Z;BYDAY=MO,WE" || return 1
    event_has_line "$export_file" "Monthly Exclusions" "RRULE:FREQ=MONTHLY;UNTIL=20300615T160000Z" || return 1
    event_has_line "$export_file" "Yearly Exclusions" "RRULE:FREQ=YEARLY;UNTIL=20330220T110000Z" || return 1

    event_has_line "$export_file" "Daily Exclusions" "EXDATE;TZID=Europe/Rome:20300103T090000,20300107T090000,20300109T090000" || return 1
    event_has_line "$export_file" "Weekly Exclusions" "EXDATE;TZID=Europe/Rome:20300109T100000,20300114T100000,20300130T100000" || return 1
    event_has_line "$export_file" "Monthly Exclusions" "EXDATE;TZID=Europe/Rome:20300215T180000,20300515T180000" || return 1
    event_has_line "$export_file" "Yearly Exclusions" "EXDATE;TZID=Europe/Rome:20310220T120000,20330220T120000" || return 1

    if grep -Eq '^RRULE:.*(BYSETPOS|BYSECOND|BYMINUTE|BYHOUR|WKST)=' "$export_file"; then
        printf 'Proton export contains an unsupported recurrence component\n' >&2
        return 1
    fi
    if grep -Eq '(^|[^0-9])(19[0-6][0-9]|20(3[8-9]|[4-9][0-9]))[0-9]{4}' "$export_file"; then
        printf 'Proton export contains a date outside the 1970-2037 range\n' >&2
        return 1
    fi
}

test_alarm_backfill_filters() {
    begin_case alarm_backfill
    seed_calcurse alarm-calcurse.ics || return 1
    install_proton_fixture alarm-proton.ics

    run_sync $'A\nA\ny\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "Found 1 matching appointment(s) with a missing Calcurse notification" || return 1
    assert_line_count 1 "BEGIN:VALARM" "$backup_dir/calendario.ics" || return 1
    event_has_line "$backup_dir/calendario.ics" "Display Alarm" "BEGIN:VALARM" || return 1
    event_lacks_line "$backup_dir/calendario.ics" "Email Alarm" "BEGIN:VALARM" || return 1
    event_lacks_line "$backup_dir/calendario.ics" "All Day Alarm" "BEGIN:VALARM" || return 1
}

test_alarm_removal_state() {
    begin_case alarm_removal
    seed_calcurse proton-new.ics || return 1
    install_proton_fixture proton-new.ics

    run_sync $'A\n'
    assert_status 0 || return 1
    assert_state_value 1 || return 1

    local state_file="$test_home/.local/state/calcurse-sync/alarm-state.tsv"
    [[ "$(stat -c %a "$state_file")" == "600" ]] || return 1
    [[ "$(stat -c %a "$(dirname "$state_file")")" == "700" ]] || return 1

    install_proton_fixture proton-new-no-alarm.ics
    local apts_before state_before proton_file="$backup_dir/My Calendar-test.ics"
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    state_before=$(sha256sum "$state_file" | cut -d' ' -f1)

    run_sync $'A\nR\n' --dry-run
    assert_status 0 || return 1
    assert_contains "$output_file" "whose Proton notification was removed" || return 1
    assert_contains "$output_file" "Notifications to remove from Calcurse: 1" || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1
    [[ "$state_before" == "$(sha256sum "$state_file" | cut -d' ' -f1)" ]] || return 1
    [[ -f "$proton_file" ]] || return 1

    run_sync $'A\nR\ny\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "Notifications removed: 1" || return 1
    assert_state_value 0 || return 1
    event_lacks_line "$backup_dir/calendario.ics" "Proton New Event" "BEGIN:VALARM" || return 1
}

test_alarm_removal_postpone_and_keep() {
    begin_case alarm_removal_decisions
    seed_calcurse proton-new.ics || return 1
    install_proton_fixture proton-new.ics

    run_sync $'A\n'
    assert_status 0 || return 1
    assert_state_value 1 || return 1

    local apts_before
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)

    install_proton_fixture proton-new-no-alarm.ics
    run_sync $'A\nS\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "Decision postponed" || return 1
    assert_state_value 1 || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1

    install_proton_fixture proton-new-no-alarm.ics
    run_sync $'A\nK\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "notification will be kept" || return 1
    assert_state_value 0 || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1

    install_proton_fixture proton-new-no-alarm.ics
    run_sync $'A\n'
    assert_status 0 || return 1
    assert_not_contains "$output_file" "whose Proton notification was removed" || return 1
}

test_recurring_exdate_frequency_matrix() {
    begin_case recurring_exdate_frequency_matrix
    seed_calcurse recurrence-series-base.ics || return 1
    install_proton_fixture recurrence-series-base.ics

    run_sync $'A\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "No changes to apply. The calendars are synchronized!" || return 1

    install_proton_fixture recurrence-series-proton-exdates.ics
    local apts_before proton_file="$backup_dir/My Calendar-test.ics"
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)

    run_sync $'A\nP\nP\nP\nP\n' --dry-run
    assert_status 0 || return 1
    assert_contains "$output_file" "Found 4 recurring event(s) with different exclusions" || return 1
    assert_contains "$output_file" "Events to import into Calcurse: 4" || return 1
    assert_contains "$output_file" "Events to delete from Calcurse: 4" || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1
    [[ -f "$proton_file" ]] || return 1

    run_sync $'A\nP\nP\nP\nP\ny\n'
    assert_status 0 || return 1
    assert_line_count 4 "BEGIN:VEVENT" "$backup_dir/calendario.ics" || return 1
    assert_contains "$output_file" "Proton events imported: 4" || return 1

    event_has_line "$backup_dir/calendario.ics" "Daily Exclusions" "RRULE:FREQ=DAILY;UNTIL=20300110T090000" || return 1
    event_has_line "$backup_dir/calendario.ics" "Weekly Exclusions" "RRULE:FREQ=WEEKLY;UNTIL=20300204T100000;BYDAY=MO,WE" || return 1
    event_has_line "$backup_dir/calendario.ics" "Monthly Exclusions" "RRULE:FREQ=MONTHLY;UNTIL=20300615T180000;BYMONTHDAY=15" || return 1
    event_has_line "$backup_dir/calendario.ics" "Yearly Exclusions" "RRULE:FREQ=YEARLY;UNTIL=20330220T120000;BYMONTH=2;BYMONTHDAY=20" || return 1

    event_has_line "$backup_dir/calendario.ics" "Daily Exclusions" "EXDATE:20300103T090000,20300107T090000,20300109T090000" || return 1
    event_has_line "$backup_dir/calendario.ics" "Weekly Exclusions" "EXDATE:20300109T100000,20300114T100000,20300130T100000" || return 1
    event_has_line "$backup_dir/calendario.ics" "Monthly Exclusions" "EXDATE:20300215T180000,20300515T180000" || return 1
    event_has_line "$backup_dir/calendario.ics" "Yearly Exclusions" "EXDATE:20310220T120000,20330220T120000" || return 1

    install_proton_fixture recurrence-series-proton-exdates.ics
    run_sync $'A\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "No changes to apply. The calendars are synchronized!" || return 1
    assert_not_contains "$output_file" "with different exclusions" || return 1
}

test_recurring_alarm_removal_preserves_recurrence() {
    begin_case recurring_alarm_removal
    seed_calcurse palestra-proton-no-fridays.ics || return 1
    install_proton_fixture palestra-proton-no-fridays.ics

    run_sync $'A\n'
    assert_status 0 || return 1
    assert_state_value 1 || return 1

    install_proton_fixture palestra-proton-no-fridays-no-alarm.ics
    local apts_before state_before
    local state_file="$test_home/.local/state/calcurse-sync/alarm-state.tsv"
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    state_before=$(sha256sum "$state_file" | cut -d' ' -f1)

    run_sync $'A\nR\n' --dry-run
    assert_status 0 || return 1
    assert_contains "$output_file" "whose Proton notification was removed" || return 1
    assert_contains "$output_file" "Notifications to remove from Calcurse: 1" || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1
    [[ "$state_before" == "$(sha256sum "$state_file" | cut -d' ' -f1)" ]] || return 1

    run_sync $'A\nR\ny\n'
    assert_status 0 || return 1
    assert_state_value 0 || return 1
    event_lacks_line "$backup_dir/calendario.ics" "Palestra" "BEGIN:VALARM" || return 1
    assert_contains "$backup_dir/calendario.ics" "RRULE:FREQ=WEEKLY" || return 1

    local friday
    for friday in 20300906 20300913 20300920 20300927; do
        assert_contains "$backup_dir/calendario.ics" "$friday" || return 1
    done

    install_proton_fixture palestra-proton-no-fridays-no-alarm.ics
    run_sync $'A\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "No changes to apply. The calendars are synchronized!" || return 1
    assert_not_contains "$output_file" "whose Proton notification was removed" || return 1
}

test_invalid_alarm_state_is_safe() {
    begin_case invalid_alarm_state
    seed_calcurse proton-new.ics || return 1
    install_proton_fixture proton-new-no-alarm.ics

    local state_dir="$test_home/.local/state/calcurse-sync"
    local state_file="$state_dir/alarm-state.tsv"
    mkdir -p "$state_dir"
    printf 'invalid state\n' > "$state_file"

    local apts_before
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)

    run_sync $'A\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "Alarm state is invalid and will be rebuilt" || return 1
    assert_not_contains "$output_file" "whose Proton notification was removed" || return 1
    assert_state_value 0 || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1
}

test_proton_origin_deletion_report() {
    begin_case proton_origin_deletion
    install_proton_fixture proton-new.ics

    run_sync $'A\ny\ny\n'
    assert_status 0 || return 1
    assert_event_state_count 1 || return 1

    : > "$calcurse_dir/apts"
    install_proton_fixture proton-new.ics
    run_sync $'A\nS\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "Previously synchronized event no longer present in Calcurse" || return 1
    assert_contains "$output_file" "Decision postponed" || return 1
    assert_event_state_count 1 || return 1
    [[ ! -e "$backup_dir/eventi-da-cancellare-proton.txt" ]] || return 1

    install_proton_fixture proton-new.ics
    local state_file="$test_home/.local/state/calcurse-sync/event-state.tsv"
    local state_before
    state_before=$(sha256sum "$state_file" | cut -d' ' -f1)
    run_sync $'A\nD\n' --dry-run
    assert_status 0 || return 1
    assert_contains "$output_file" "Events to delete manually from Proton: 1" || return 1
    [[ "$state_before" == "$(sha256sum "$state_file" | cut -d' ' -f1)" ]] || return 1
    [[ ! -e "$backup_dir/eventi-da-cancellare-proton.txt" ]] || {
        printf 'Dry-run created the Proton deletion report\n' >&2
        return 1
    }

    run_sync $'A\nD\ny\n'
    assert_status 0 || return 1
    local report="$backup_dir/eventi-da-cancellare-proton.txt"
    [[ -f "$report" ]] || return 1
    [[ "$(stat -c %a "$report")" == "600" ]] || return 1
    assert_contains "$report" "Proton New Event" || return 1
    assert_contains "$report" "UID: proton-new@test" || return 1
    assert_contains "$report" "This is not an ICS import file" || return 1
    assert_event_state_count 1 || return 1

    install_proton_fixture empty.ics
    run_sync $'A\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "No changes to apply. The calendars are synchronized!" || return 1
    [[ ! -e "$report" ]] || {
        printf 'Confirmed Proton deletion left a stale report\n' >&2
        return 1
    }
    assert_event_state_count 0 || return 1
}

test_calcurse_origin_deletion_report() {
    begin_case calcurse_origin_deletion
    seed_calcurse calcurse-new.ics || return 1
    install_proton_fixture empty.ics

    run_sync $'A\nB\ny\n'
    assert_status 0 || return 1
    local proton_copy="$case_dir/calcurse-origin-proton.ics"
    cp "$backup_dir/nuovi-appuntamenti-calcurse.ics" "$proton_copy"

    cp "$proton_copy" "$backup_dir/My Calendar-test.ics"
    run_sync $'A\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "No changes to apply. The calendars are synchronized!" || return 1
    assert_event_state_count 1 || return 1

    : > "$calcurse_dir/apts"
    cp "$proton_copy" "$backup_dir/My Calendar-test.ics"
    run_sync $'A\nD\ny\n'
    assert_status 0 || return 1
    assert_contains "$output_file" "Previously synchronized event no longer present in Calcurse" || return 1

    local report="$backup_dir/eventi-da-cancellare-proton.txt"
    [[ -f "$report" ]] || return 1
    assert_contains "$report" "Calcurse New Event" || return 1
    assert_contains "$report" "UID: CALCURSE-" || return 1
}

test_dry_run_preserves_everything() {
    begin_case dry_run
    seed_calcurse calcurse-new.ics || return 1
    install_proton_fixture proton-new.ics

    local proton_file="$backup_dir/My Calendar-test.ics"
    local apts_before todo_before proton_before
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    todo_before=$(sha256sum "$calcurse_dir/todo" | cut -d' ' -f1)
    proton_before=$(sha256sum "$proton_file" | cut -d' ' -f1)

    run_sync $'A\ny\nB\n' --dry-run
    assert_status 0 || return 1
    assert_contains "$output_file" "DRY RUN COMPLETE: the changes above were not applied." || return 1
    assert_contains "$output_file" "Events to import into Calcurse: 1" || return 1
    assert_contains "$output_file" "Events to export to Proton: 1" || return 1

    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || {
        printf 'Dry-run changed appointments\n' >&2
        return 1
    }
    [[ "$todo_before" == "$(sha256sum "$calcurse_dir/todo" | cut -d' ' -f1)" ]] || {
        printf 'Dry-run changed TODO items\n' >&2
        return 1
    }
    [[ -f "$proton_file" ]] || {
        printf 'Dry-run moved or deleted the Proton download\n' >&2
        return 1
    }
    [[ "$proton_before" == "$(sha256sum "$proton_file" | cut -d' ' -f1)" ]] || {
        printf 'Dry-run changed the Proton download\n' >&2
        return 1
    }

    [[ ! -e "$backup_dir/calendar.ics" ]] || return 1
    [[ ! -e "$backup_dir/calendario.ics" ]] || return 1
    [[ ! -e "$backup_dir/nuovi-appuntamenti-calcurse.ics" ]] || return 1
    [[ ! -e "$test_home/.local/state/calcurse-sync/alarm-state.tsv" ]] || {
        printf 'Dry-run created alarm synchronization state\n' >&2
        return 1
    }
    [[ ! -e "$test_home/.local/state/calcurse-sync/event-state.tsv" ]] || {
        printf 'Dry-run created event synchronization state\n' >&2
        return 1
    }
    [[ ! -e "$backup_dir/eventi-da-cancellare-proton.txt" ]] || {
        printf 'Dry-run created a Proton deletion report\n' >&2
        return 1
    }
    local backups=("$backup_dir"/backup_*.ics)
    [[ ! -e "${backups[0]}" ]] || return 1

    run_sync $'B\nQ\n' --dry-run
    assert_status 0 || return 1
    assert_contains "$output_file" "Complete sync is unavailable in dry-run mode." || return 1
    [[ "$apts_before" == "$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)" ]] || return 1
    [[ -f "$proton_file" ]] || return 1
}

test_atomic_failure_preserves_data() {
    begin_case atomic_failure
    seed_calcurse atomic-seed.ics || return 1
    install_proton_fixture invalid-event.ics

    local apts_before todo_before
    apts_before=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    todo_before=$(sha256sum "$calcurse_dir/todo" | cut -d' ' -f1)

    run_sync $'B\nCONFIRM\n'
    [[ "$sync_status" -ne 0 ]] || {
        printf 'Expected the invalid complete import to fail\n' >&2
        return 1
    }
    assert_contains "$output_file" "the original database is unchanged" || return 1

    local apts_after todo_after raw_export="$case_dir/raw-export.ics"
    apts_after=$(sha256sum "$calcurse_dir/apts" | cut -d' ' -f1)
    todo_after=$(sha256sum "$calcurse_dir/todo" | cut -d' ' -f1)
    [[ "$apts_before" == "$apts_after" ]] || {
        printf 'Atomic failure changed appointments\n' >&2
        return 1
    }
    [[ "$todo_before" == "$todo_after" ]] || {
        printf 'Atomic failure changed TODO items\n' >&2
        return 1
    }

    export_raw_calcurse "$raw_export" || return 1
    assert_contains "$raw_export" "SUMMARY:Atomic Seed" || return 1
    assert_line_count 1 "BEGIN:VTODO" "$raw_export" || return 1
}

run_test() {
    local description="$1"
    local test_function="$2"
    local started=$SECONDS

    printf 'TEST %-42s ' "$description"
    if "$test_function"; then
        printf 'PASS (%ss)\n' "$((SECONDS - started))"
        ((pass_count++))
    else
        printf 'FAIL (%ss)\n' "$((SECONDS - started))"
        ((fail_count++))
        if [[ -f "$output_file" ]]; then
            printf '%s\n' '--- sync output ---'
            tail -n 80 "$output_file"
            printf '%s\n' '-------------------'
        fi
    fi
}

if ! command -v "$CALCURSE_BIN" >/dev/null 2>&1; then
    printf 'calcurse is required to run this integration suite\n' >&2
    exit 2
fi

run_test "Proton import and second-pass idempotence" test_proton_import_and_idempotence
run_test "Calcurse-only event export" test_calcurse_export
run_test "Proton monthly BYDAY normalization" test_proton_monthly_byday_normalization
run_test "Recurring EXDATE update with alarm" test_recurring_exdate_and_alarm
run_test "Recurring EXDATE daily/weekly/monthly/yearly" test_recurring_exdate_frequency_matrix
run_test "Proton-compatible recurring EXDATE export" test_proton_recurrence_export_compatibility
run_test "Alarm backfill compatibility filters" test_alarm_backfill_filters
run_test "Alarm removal baseline and dry-run" test_alarm_removal_state
run_test "Alarm removal postpone and keep choices" test_alarm_removal_postpone_and_keep
run_test "Recurring alarm removal preserves recurrence" test_recurring_alarm_removal_preserves_recurrence
run_test "Invalid alarm state is rebuilt safely" test_invalid_alarm_state_is_safe
run_test "Proton-origin event deletion report" test_proton_origin_deletion_report
run_test "Calcurse-origin event deletion report" test_calcurse_origin_deletion_report
run_test "Dry-run preserves files and Calcurse data" test_dry_run_preserves_everything
run_test "Atomic failure preserves appointments/TODO" test_atomic_failure_preserves_data

printf '\nResult: %s passed, %s failed (%ss)\n' \
    "$pass_count" "$fail_count" "$((SECONDS - suite_started))"

[[ "$fail_count" -eq 0 ]]
