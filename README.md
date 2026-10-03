# csync

📅 **Proton Calendar ↔ Calcurse Sync Tool**

Manual synchronization between Proton Calendar and Calcurse (no official sync available).

## ✨ Main Features

| Feature | Description |
|---------|-------------|
| 🔄 **Guided Bidirectional Sync** | Interactive decisions for each discrepancy |
| 🎯 **Recurring Events Management** | Supports EXDATE (excluded occurrences) |
| 🚀 **Optimized Performance** | Hash-based O(n) comparison |
| 🚨 **Smart Alarm Conversion** | Normalizes reminders between systems |
| 🗑️ **Deletion Detection** | Recognizes events removed from Calcurse after synchronization |
| 💾 **Automatic Backups** | Rotation of the last 3 backups |
| 🛡️ **Safe by Default** | Option A is the recommended daily/weekly flow |

## 📦 Quick Setup

```bash
mkdir -p ~/Projects/calendar && cd ~/Projects/calendar
wget -O calcurse-sync.sh [URL_REPOSITORY]
chmod +x calcurse-sync.sh

# Optional: symbolic link
sudo ln -s ~/Projects/calendar/calcurse-sync.sh /usr/local/bin/csync
```

## 🚀 Usage

### Recommended Workflow (most common)

1. Download the updated calendar from Proton (`.ics`)
2. Run: `./calcurse-sync.sh` or `csync`
3. Choose **Option A** – Guided bidirectional sync
4. Confirm the changes
5. Import the generated file into Proton **only if** the script produced an export file

### Preview Without Changes

Run the guided analysis without modifying Calcurse or any calendar file:

```bash
./calcurse-sync.sh --dry-run
```

Choose Option A and answer the usual guided questions. The script displays the
complete change summary, but does not rename the Proton download, create a
backup, update Calcurse, write synchronization state, or generate a Proton
export. Complete sync (Option B) is disabled in this mode.

## 🧭 Menu Options

When you run `csync`, you’ll see:

- **A — 🔄 GUIDED BIDIRECTIONAL SYNC (Calcurse ↔ Proton + report)**  
  Interactive and safe. Best for regular use.

- **B — 🧹 COMPLETE SYNC (Proton → Calcurse, replaces everything)**  
  One-way “Proton is the master”. Destructive for Calcurse-only events.  
  *(Tip: some versions also accept `F` as input for this option, for compatibility.)*

- **Q — ❌ Exit without operations**

### ⚠️ Critical Warnings

- **Option B** is **DESTRUCTIVE**: it deletes everything in Calcurse that is not present in Proton.
- After initial setup, prefer **Option A** for routine sync to keep control and avoid surprises.

## 💡 Recommended Workflows

### 1) Bidirectional Use (Most Common)

```text
1. Download My Calendar-YYYY-MM-DD.ics from Proton
2. csync → Option A
3. Confirm changes
4. Import into Proton only if an export file was generated
```

✅ Full control | ✅ EXDATE management | ✅ No duplicates (with the guided flow)

### 2) Proton Master (One-Way)

```text
1. Download calendar from Proton
2. csync → Option B
```

✅ Fast | ✅ Calcurse always mirrors Proton | ⚠️ Calcurse-only events will be removed

## 🔧 Technical Notes

### Atomic Calcurse Updates

Before replacing Calcurse appointments, the script imports and validates the
complete target calendar in a temporary Calcurse database. The real `apts`
file is replaced only after a successful import with the expected event count.
Failed imports leave the existing appointments and TODO items unchanged.
The original ICS envelope and component nesting are checked before import.
An empty or malformed file is rejected; a valid empty calendar can still be
used for complete sync after confirmation. Duplicate event UIDs, `RDATE`, and
detached occurrences using `RECURRENCE-ID` are rejected explicitly because they
cannot currently be represented safely by this synchronization flow.

Proton exports are prepared and checked before applying the selected Calcurse
changes, then published with an atomic file replacement. A preparation failure
preserves Calcurse, the previous export, and synchronization state. Write and
state-save failures return a nonzero exit status instead of reporting success.

### Integration Tests

Run the isolated end-to-end suite with:

```bash
bash tests/run.sh
```

The suite requires `calcurse` and creates a separate temporary home and data
directory for every scenario. It never reads or modifies the user's Calcurse
database or synchronization state, including when `XDG_STATE_HOME` is set in
the calling environment. Tests use `Europe/Rome` explicitly. Set
`KEEP_TEST_TMP=1` to retain the temporary files after a run.

Covered flows include guided import and export, second-pass idempotence,
folded ICS properties with CRLF input, daily, weekly, monthly, and yearly
`EXDATE` updates, Proton-compatible
recurrence export, compatible alarm backfill and removal, persistent-state
decisions, deletion detection for events originating in either Proton or
Calcurse, recurring alarm removal without `RRULE`/`EXDATE` loss, dry-run
preservation, unsupported alarm filters, and atomic failure preservation for
appointments and TODO items.
Additional regressions cover malformed and empty calendars, detached
occurrences, UTC and foreign-timezone appointments, UTC exclusions, overnight
and multi-day durations, DST transitions, changed event content and recurrence
rules, cancellation, export failures, and inherited state-directory isolation.

### ICS Parsing

Before comparison, physical ICS lines are unfolded into complete logical
properties and trailing CR characters are removed. This is performed in one
linear `awk` pass while extracting `VEVENT` blocks. That pass also checks the
calendar envelope and balanced components and rejects unsupported detached
occurrences. It is a lightweight structural check, not a complete RFC validator.
The optional external parser remains confined to the integration suite.

### Event Normalization

The script normalizes events for accurate comparison:

```text
Proton:   FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20251020T215959Z
Calcurse: FREQ=WEEKLY;UNTIL=20251020T115000;BYDAY=TU,TH
          ↓
Both:     BYDAY=TH,TU;FREQ=WEEKLY;UNTIL=20251020
```

**Comparison data:**
1. UID and normalized content are used to identify potential matches.
2. Matched events are also compared for content and normalized recurrence rules;
   matching UIDs alone do not imply equal events. Recurrence end dates and
   meaningful filters are retained in this comparison.
3. Content conflicts offer `P` (use Proton), `C` (export the Calcurse version),
   or `S` (postpone). Postponed differences prevent the synchronized message.
   Exports updating an existing Proton event retain its Proton UID.
4. `EXDATE` and compatible display-alarm presence are handled separately when
   there is no content conflict requiring a choice of the complete event.

### Timezones and Durations

- Single appointments expressed in UTC or a known IANA timezone are converted
  to the local synchronization timezone. `DTEND`, `EXDATE`, and UTC `UNTIL` are
  converted consistently. All-day dates remain dates.
- The synchronization timezone is `${TZ:-Europe/Rome}` and is also passed to
  Calcurse. Recurring events whose `DTSTART` uses another timezone are currently
  rejected: differing daylight-saving transitions prevent a general conversion
  to Calcurse's local recurrence representation.
- Exported end times account for date rollover, multi-day durations, and
  daylight-saving transitions.

### Proton Recurrence Compatibility

- Calcurse can export `FREQ=MONTHLY` with an unnumbered `BYDAY` even when the
  resulting occurrences are simply weekly. When no additional monthly filter
  is present and the interval is one, the Proton export converts this safely to
  `FREQ=WEEKLY`.
- Date-time `UNTIL` values are converted from the event's `TZID` to UTC and
  written with the required trailing `Z`.
- `DAILY` with plain `BYDAY`, interval one, and no additional date filters is
  also converted to the equivalent weekly rule.
- Filters such as `BYMONTH` and `BYSETPOS` are never dropped simply to make a
  rule importable. If a rule cannot be normalized safely to a supported export
  form, the export is stopped with the offending rule displayed. This includes
  `DAILY` with `BYDAY` and an interval greater than one.

### Proton Recurrence Test Constraints

The daily/weekly/monthly/yearly `EXDATE` fixtures use Proton's documented
[daily, weekly, monthly, and yearly frequencies](https://proton.me/support/protoncalendar-create-update-and-delete-recurring-events).
Their dates stay between 2030 and 2033 and every series has fewer than 49
occurrences, within Proton Calendar's current
[import date range](https://proton.me/support/how-to-import-calendar-to-proton-calendar)
and custom recurrence limits. Timed `EXDATE` values are exported with the same
`TZID` as `DTSTART`, date-time `UNTIL` values are emitted in UTC, and simple
monthly/yearly rules match the forms found in Proton's own exports.
Compatibility is checked locally against the generated ICS; the suite does
not access Proton accounts or perform live imports. Fixtures for unsupported
forms verify explicit rejection rather than successful export.

### Event Deletion Detection

- The first successful Option A run creates an event baseline without inferring
  deletions. It stores only hashed identifiers for events known to be present in
  both calendars, imported into Calcurse, or confirmed for export to Proton
  during that run.
- The mechanism is independent of event origin: it works after both
  Calcurse → Proton and Proton → Calcurse synchronization. Events confirmed for
  export are recorded immediately; for exports created before this baseline was
  introduced, the UID in the latest `nuovi-appuntamenti-calcurse.ics` is used as
  a migration fallback when the same UID is found in Proton.
- If a baseline event is later present only in Proton, Option A offers to
  restore it into Calcurse (`R`). Pressing Enter leaves Calcurse unchanged,
  reports that the calendars are not fully synchronized, and asks again on the
  next run while the event still exists in Proton.
- If the event is deleted manually from Proton, it disappears from the next
  Proton export; Option A then removes it from the baseline, stops asking, and
  can report the calendars as synchronized again.
- The baseline is stored at
  `${XDG_STATE_HOME:-$HOME/.local/state}/calcurse-sync/event-state.tsv` and is
  updated only after a successful normal Option A run. Cancellation, failure,
  and `--dry-run` leave it unchanged.

### Alarm Conversion

- **Proton → Calcurse**: keeps the first compatible `ACTION:DISPLAY` alarm
  for each timed appointment and converts its relative trigger to seconds.
- Additional alarms and `ACTION:EMAIL` are ignored. Calcurse does not retain
  alarms on all-day events.
- Calcurse stores a notification flag per appointment and applies the global
  `notification.warning` value, so Proton's per-event lead times are not
  preserved.
- **Calcurse → Proton**: exports one display alarm rounded to a standard
  interval (5, 10, 15, 30, 60, 120, or 1440 minutes).
- During **Option A**, matching timed appointments that have a compatible
  Proton display alarm but no Calcurse notification can be backfilled in one
  batch or reviewed individually.
- The first successful Option A run creates an alarm baseline without inferring
  removals. On later runs, when a compatible Proton display alarm has
  disappeared but the matching Calcurse notification remains, the script asks
  whether to remove it (`R`), keep it and accept the difference (`K`), or
  postpone the decision until the next synchronization (`S`).
- Alarm removal is never automatic. The state is updated only after a successful
  normal Option A run; cancellation, failure, and `--dry-run` leave it
  unchanged.
- The state file is stored at
  `${XDG_STATE_HOME:-$HOME/.local/state}/calcurse-sync/alarm-state.tsv`.
  It contains only hashed event identifiers and alarm-presence flags, not event
  titles, descriptions, or dates.

## 📊 Example (Option A)

```text
🔍 Analyzing discrepancies...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📥 EVENTS IN PROTON BUT NOT IN CALCURSE (3)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Event: Team Meeting
Date: 2025-10-20 14:00
Import to Calcurse? (Y/n/s): y

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔄 RECURRING EVENTS WITH DIFFERENT EXDATE (1)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Event: Monthly Review
Proton excludes: 2025-10-15
Calcurse excludes: (none)

Keep version:
  [P] Proton (update Calcurse)
  [C] Calcurse (update Proton)
  [S] Skip
Choice: P

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Summary:
  Imported: 3
  Updated EXDATE: 1
  Exported for Proton: 0
```

## 🛠️ Troubleshooting

| Problem | Solution |
|---------|----------|
| "No Proton file found" | Download `.ics` from Proton, name: `My Calendar-YYYY-MM-DD.ics` |
| "[Untitled]" events | Normal for Calcurse events without SUMMARY |

## 📁 File Paths

- **Calcurse**: `~/.local/share/calcurse/` or `~/.calcurse/`
- **Backup**: `~/Projects/calendar/` (configurable)
- **Export**: `~/Projects/calendar/calcurse-export-to-proton.ics`
- **Alarm state**:
  `${XDG_STATE_HOME:-$HOME/.local/state}/calcurse-sync/alarm-state.tsv`
- **Event baseline**:
  `${XDG_STATE_HOME:-$HOME/.local/state}/calcurse-sync/event-state.tsv`

***

**License**: MIT | **Privacy**: No data sent online
