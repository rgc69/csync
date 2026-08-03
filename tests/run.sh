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
    for friday in 20990904 20990911 20990918 20990925; do
        assert_contains "$backup_dir/calendario.ics" "$friday" || return 1
    done
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
run_test "Alarm backfill compatibility filters" test_alarm_backfill_filters
run_test "Dry-run preserves files and Calcurse data" test_dry_run_preserves_everything
run_test "Atomic failure preserves appointments/TODO" test_atomic_failure_preserves_data

printf '\nResult: %s passed, %s failed (%ss)\n' \
    "$pass_count" "$fail_count" "$((SECONDS - suite_started))"

[[ "$fail_count" -eq 0 ]]
