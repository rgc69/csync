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

### Event Normalization

The script normalizes events for accurate comparison:

```text
Proton:   FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20251020T215959Z
Calcurse: FREQ=WEEKLY;UNTIL=20251020T115000;BYDAY=TU,TH
          ↓
Both:     BYDAY=TH,TU;FREQ=WEEKLY;UNTIL=20251020
```

**Comparison data:**
1. Normalized content hash, excluding alarms and `EXDATE`
2. Summary and UID for matching and display
3. `EXDATE` and compatible display-alarm presence handled separately

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
  batch or reviewed individually. This backfill only adds missing
  notifications; it does not remove or compare existing notification settings.

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

***

**License**: MIT | **Privacy**: No data sent online
