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

### Event Normalization

The script normalizes events for accurate comparison:

```text
Proton:   FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20251020T215959Z
Calcurse: FREQ=WEEKLY;UNTIL=20251020T115000;BYDAY=TU,TH
          ↓
Both:     BYDAY=TH,TU;FREQ=WEEKLY;UNTIL=20251020
```

**Stored hashes:**
1. Normalized content (comparison)
2. Summary + UID (display)
3. Alarms rounded to 5min (comparison)

### Alarm Conversion

- **Proton → Calcurse**: `-P{seconds}S`
- **Calcurse → Proton**: rounded to standard intervals (5, 10, 15, 30, 60, 120, 1440 min)

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
