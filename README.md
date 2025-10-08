# csync

🔄 Proton Calendar ↔ Calcurse Sync Tool

A bash script for manual bidirectional synchronization of events between **Proton Calendar** and **Calcurse**, bridging the gap between modern cloud calendars and efficient terminal-based scheduling.

## ✨ Features

- 🔄 **Interactive Bidirectional Sync** - Main workflow with guided decision-making for each discrepancy
- 🚀 **Optimized Performance** - Uses hash-based comparisons (O(n) complexity) instead of nested loops
- 🚨 **Smart Alarm Conversion** - Normalizes reminders between systems
- 📅 **Flexible Time Ranges** - Sync all events or just future ones
- 💾 **Automatic Backups** - Never lose data with backup rotation (keeps last 3)
- 📊 **Detailed Reports** - See exactly what needs synchronization
- 🛡️ **Safe Operations** - Merge, import, or complete replacement options

## 🎯 Perfect For

Privacy-conscious users who want **Proton's security** with **Calcurse's terminal efficiency**

## 📦 Installation

### Prerequisites

- **Calcurse** installed on your system
- **Proton Calendar** account
- **Bash** shell environment

### Setup Steps

1. **Clone or download the script:**

```bash
# Create projects directory if it doesn't exist
mkdir -p ~/Projects/calendar
cd ~/Projects/calendar

# Download the sync script
wget -O calcurse-sync.sh https://github.com/rgc69/csync.git
chmod +x calcurse-sync.sh
```

2. **Configure the backup directory (optional):**

The script uses `~/Projects/calendar` by default. You can modify the `BACKUP_DIR` variable in the script if needed.

3. **Make the script easily accessible:**

```bash
# Create a symlink in your PATH (optional)
sudo ln -s ~/Projects/calendar/calcurse-sync.sh /usr/local/bin/csync
```

## 🚀 Usage

### Recommended Workflow

**The main workflow is the interactive bidirectional sync:**

1. **Download the latest calendar from Proton:**
   - Go to Proton Calendar → Settings → Export
   - Download your calendar as `.ics` file
   - Save it as `My Calendar-YYYY-MM-DD.ics` in your backup directory

2. **Run the interactive sync:**

```bash
cd ~/Projects/calendar
./calcurse-sync.sh

# or if you created the symlink:
csync
```

3. **Choose Option A - Interactive Bidirectional Sync**

The script will:
- Export current Calcurse events
- Compare both calendars using optimized hash-based algorithm
- Show you each discrepancy and ask what to do:
  - **Events in Proton but not in Calcurse**: Import to Calcurse?
  - **Events in Calcurse but not in Proton**: 
    - Delete from Calcurse (was already deleted in Proton)?
    - Keep and export to Proton (new event)?
    - Skip (leave as is)?
- Apply your decisions automatically
- Generate export file for Proton if needed

### Sync Options

```
🔔 REMEMBER: Make sure you have downloaded the UPDATED file from Proton Calendar

Choose an option:
A) 🔄 INTERACTIVE BIDIRECTIONAL SYNC: Calcurse ↔ Proton (RECOMMENDED)
B) Import events from Proton (merge - ONLY additions)
C) Export events to Proton (ONLY additions)
D) Export only future events (30 days)
E) Export with custom interval
---------
F) 🔄 COMPLETE SYNC: Proton → Calcurse (REPLACES everything)
---------
Q) ❌ Exit without operations
```

### Alternative Workflows

**For batch import from Proton (Option B):**
```bash
csync # Choose option B
# Imports all new events from Proton to Calcurse without interaction
```

**For exporting new Calcurse events (Options C/D/E):**
```bash
csync # Choose option C (all events), D (future events), or E (custom range)
# Generates a file to import into Proton Calendar manually
```

**For complete replacement (Option F - CAUTION):**
```bash
csync # Choose option F
# Completely replaces Calcurse with Proton content (creates backup first)
```

## ⚙️ File Structure

```
~/Projects/calendar/
├── calcurse-sync.sh                    # Main sync script
├── calendar.ics                        # Current Proton calendar data
├── calendario.ics                      # Current Calcurse export
├── nuovi-appuntamenti-calcurse.ics     # New events for Proton
└── backup_YYYYMMDD-HHMMSS.ics          # Automatic backups (last 3 kept)
```

## 🔧 Technical Details

### Performance Optimization

The script uses **hash-based event comparison** for optimal performance:
- **Time complexity**: O(n + m) instead of O(n × m)
- **Event identification**: Uses `DTSTART + RRULE` as composite primary key
- **Fast lookups**: Bash associative arrays for O(1) comparisons
- Handles hundreds of events efficiently

**Real-world performance example:**
- For 500 events in Calcurse and 500 events in Proton:
  - **Without optimization**: ~250,000 comparisons (nested loops)
  - **With hash-based indexing**: ~1,000 operations (index + lookup)
  - **Result**: 250x faster

Additionally, **export operations (C/D/E) include smart caching**: the script tracks the last modification time of your Calcurse database. If no changes are detected since the last export, you'll be prompted to skip the comparison entirely, saving even more time.

### Event Matching Strategy

Events are matched using:
1. **Composite primary key**: `DTSTART + RRULE` (handles recurring events correctly)
   - **DTSTART normalization**: Removes timezone info and parameters for consistent comparison
   - **RRULE normalization**: Components are sorted in standard order (FREQ → INTERVAL → COUNT → UNTIL → BYDAY → etc.)
   - **UNTIL normalization**: Different timestamp formats are normalized (e.g., `20251020T115000` and `20251020T215959Z` both become `UNTIL=NORM`)
2. **Stored metadata**: Summary and UID for display and verification
3. **Alarm normalization**: Reminders rounded to 5-minute intervals for comparison
4. **RRULE cleaning**: Automatically removes unsupported rules (e.g., `BYMONTH` in weekly recurrences)

**Why normalization matters**: Proton and Calcurse represent the same recurring event with slightly different formats:
- Proton might use `FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20251020T215959Z`
- Calcurse might use `FREQ=WEEKLY;UNTIL=20251020T115000;BYDAY=TU,TH`

The normalization ensures both are recognized as the same event.

### Alarm Conversion

- **Proton → Calcurse**: Converts to `-P{seconds}S` format
- **Calcurse → Proton**: Rounds to standard intervals (5, 10, 15, 30, 60, 120, 1440 minutes)
- Automatically adds required fields for Proton compatibility

## 🔧 Troubleshooting

### Common Issues

**"No Proton file found" error:**
- Ensure you've downloaded the `.ics` file from Proton Calendar
- The file should be named `My Calendar-YYYY-MM-DD.ics`

**Permission errors:**
- Make the script executable: `chmod +x calcurse-sync.sh`

**Calcurse not found:**
- Install calcurse:
  - `sudo apt install calcurse` (Ubuntu/Debian)
  - Or: `brew install calcurse` (macOS)

**Events show as "[Untitled]":**
- Some Calcurse events may not have a SUMMARY field
- They're matched by date/time, which is more reliable

### File Locations

- **Calcurse data:** `~/.local/share/calcurse/` or `~/.calcurse/`
- **Script directory:** `~/Projects/calendar/` (configurable)

## 🆕 Recent Improvements

### v1.1 - Enhanced Event Matching
- **Fixed duplicate event detection**: Events that are identical in both calendars are now correctly recognized
- **RRULE normalization**: Components are sorted alphabetically to handle different ordering between Proton and Calcurse
- **DTSTART normalization**: Timezone parameters are stripped for consistent comparison
- **UNTIL normalization**: Different timestamp formats in recurring events are now matched correctly

**Impact**: Eliminates false positives where the same event appeared as "missing" in both calendars during interactive sync.

## 🤝 Contributing

Feel free to submit issues and pull requests to improve the synchronization logic or add new features.

## 📄 License

This project is open source and available under the MIT License.

---

## 💡 Tips

- **Always download fresh Proton calendar** before syncing
- **Use Option A** (Interactive Sync) as your main workflow - it prevents accidental re-addition of deleted events
- **Check the backup directory** - the script keeps the last 3 backups automatically
- **Review changes carefully** during interactive sync before confirming
- **Keep Proton Calendar updated** by importing the generated `.ics` file after each sync
