# csync

📅 **Proton Calendar ↔ Calcurse Sync Tool**

Manual bidirectional synchronization between Proton Calendar and Calcurse.

## ✨ Main Features

| Feature | Description |
|---------|-------------|
| 🔄 **Interactive Bidirectional Sync** | Guided decisions for each discrepancy |
| 🎯 **Recurring Events Management** | Full support for EXDATE (excluded occurrences) |
| 🚀 **Optimized Performance** | Hash-based O(n) comparison |
| 🚨 **Smart Alarm Conversion** | Normalization of reminders between systems |
| 💾 **Automatic Backups** | Rotation of the last 3 backups |
| 🛡️ **Safe Operations** | Merge, import, or full replacement |

## 📦 Quick Setup

```bash
mkdir -p ~/Projects/calendar && cd ~/Projects/calendar
wget -O calcurse-sync.sh [URL_REPOSITORY]
chmod +x calcurse-sync.sh

# Optional: symbolic link
sudo ln -s ~/Projects/calendar/calcurse-sync.sh /usr/local/bin/csync
```

## 🚀 Usage

### Recommended Workflow

1. Download the updated calendar from Proton (`.ics`)
2. Run: `./calcurse-sync.sh` or `csync`
3. Choose **Option A** - Interactive Sync
4. Confirm the changes
5. Import the generated file into Proton (if necessary)

## 📋 Sync Options Comparison

| Option | Description | EXDATE | Duplicates | Recommended Use |
|--------|-------------|--------|------------|-----------------|
| **A - Interactive Sync** ⭐ | Bidirectional with full control | ✅ Yes | ❌ No | **Daily/weekly use** |
| **B - Import from Proton** | Fast batch import | ❌ No | ⚠️ Possible | Bulk new events |
| **C/D/E - Export to Proton** ⚠️ | Generates .ics file for Proton | ❌ No | ⚠️ Yes | **INITIAL migration ONLY** |
| **F - Full Replacement** | Proton → Calcurse (one-way) | ✅ Yes | ❌ No | Proton as master |

### ⚠️ Critical Warnings

- **Options C/D/E**: Use **ONCE ONLY** for initial migration. Reuse = duplicates!
- **Option F**: **DESTRUCTIVE** - deletes everything in Calcurse not present in Proton
- **After initial setup**: ALWAYS use Option A

## 💡 Recommended Workflows

### 1. Bidirectional Use (Most Common)

```bash
# Every few days:
1. Download My Calendar-YYYY-MM-DD.ics from Proton
2. csync → Option A
3. Confirm changes
4. Import into Proton if necessary
```

✅ Full control | ✅ EXDATE management | ✅ No duplicates

### 2. Proton Master (One-Way)

```bash
# Weekly:
1. Download calendar from Proton
2. csync → Option F
```

✅ Fast | ✅ Calcurse always updated | ⚠️ Events only from Proton

## 🔧 Technical Features

### Event Normalization

The script normalizes events for accurate comparison:

```
Proton:  FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20251020T215959Z
Calcurse: FREQ=WEEKLY;UNTIL=20251020T115000;BYDAY=TU,TH
         ↓
Both: BYDAY=TH,TU;FREQ=WEEKLY;UNTIL=20251020
```

**Stored Hashes:**
1. Normalized content (comparison)
2. Summary + UID (display)
3. Alarms rounded to 5min (comparison)

### Alarm Conversion

- **Proton → Calcurse**: `-P{seconds}S`
- **Calcurse → Proton**: Rounding to standard intervals (5, 10, 15, 30, 60, 120, 1440 min)

## 📊 Example Option A (Interactive)

```
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
| Duplicate events | Do not use C/D/E after initial sync. Use A |
| "[Untitled]" events | Normal for Calcurse events without SUMMARY |

## 📁 File Paths

- **Calcurse**: `~/.local/share/calcurse/` or `~/.calcurse/`
- **Backup**: `~/Projects/calendar/` (configurable)
- **Export**: `~/Projects/calendar/calcurse-export-to-proton.ics`

## 🆕 Recent News

**v1.2** - EXDATE detection for recurring events
- Detects differences in exclusions (e.g., occurrence deleted in Proton)
- Interactive resolution: choose which version to keep

**v1.1** - Improved event matching
- Eliminated false positives
- Normalization of RRULE/DTSTART/UNTIL

***

**License**: MIT | **Privacy**: No data sent online
