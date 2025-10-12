# csync

🔄 Proton Calendar ↔ Calcurse Sync Tool

A bash script for manual bidirectional synchronization of events between **Proton Calendar** and **Calcurse**, bridging the gap between modern cloud calendars and efficient terminal-based scheduling.

## ✨ Features

- 🔄 **Interactive Bidirectional Sync** - Main workflow with guided decision-making for each discrepancy
- 🎯 **Smart Recurring Event Handling** - Detects and manages exclusions (EXDATE) in recurring events
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

### Understanding Each Sync Option

> **💡 TL;DR - What Should I Use?**
> - **Daily use:** Option A (Interactive Sync) - handles everything correctly
> - **First time setup:** Option F (Complete Replacement) or Option A
> - **Reset/problems:** Option F (Complete Replacement)
> - **Options C/D/E:** ⚠️ Only for initial migration, then use A

---

#### 🎯 **Option A - Interactive Bidirectional Sync** ⭐ **RECOMMENDED FOR EVERYONE**

The most complete and safest synchronization method:
- ✅ Detects events missing in either calendar
- ✅ **Handles recurring event exclusions (EXDATE)**
- ✅ Detects when you delete a single occurrence of a recurring event
- ✅ Interactive: you decide what to do with each discrepancy
- ✅ Creates backup before making changes
- ✅ Bidirectional: works both ways (Proton ↔ Calcurse)
- ✅ Smart: prevents duplicates even with different UIDs

**Use this for:**
- ✅ Daily/weekly synchronization
- ✅ After modifying events in either calendar
- ✅ When you want to see exactly what will change
- ✅ When you've deleted occurrences of recurring events
- ✅ 99% of your sync needs

**EXDATE handling:** ✅ **Full support** - detects and lets you resolve differences

**Example workflow:**
```bash
# Every day/week:
1. Download fresh calendar from Proton
2. Run: ./calcurse-sync.sh → Choose A
3. Review changes → Confirm
4. Import generated file to Proton (if needed)
```

---

#### 📥 **Option B - Import from Proton (batch merge)**

Quick batch import of new events from Proton to Calcurse:
- ✅ Fast: imports new events without interaction
- ✅ Safe: doesn't delete anything from Calcurse
- ❌ Does NOT update existing events
- ❌ **Does NOT handle EXDATE changes** (won't sync deleted occurrences)
- ❌ May create duplicates if UIDs don't match

**Use this for:**
- 📅 You added many new events in Proton web and want quick import
- 🎫 You imported an external calendar into Proton (concerts, holidays)
- 🔄 First-time import of a new Proton calendar

**Don't use this for:**
- ❌ Regular synchronization (use A instead)
- ❌ When you've modified recurring events (use A instead)
- ❌ When you've deleted event occurrences (use A instead)

**EXDATE handling:** ❌ **Not supported** - use Option A if you deleted occurrences

```bash
csync # Choose option B
# Imports all new events from Proton to Calcurse without interaction
```

---

#### 📤 **Options C/D/E - Export to Proton** ⚠️ **USE ONLY ONCE**

Generate a file to import into Proton Calendar:
- ✅ Exports events from Calcurse to a .ics file
- ✅ Option D: filters to next 30 days
- ✅ Option E: custom date range
- ❌ Does NOT update existing events
- ❌ **Does NOT handle EXDATE changes**
- ❌ **Creates DUPLICATES if you've synced before** (Proton changes UIDs on import)

**⚠️ CRITICAL WARNING:**
These options are designed for **ONE-TIME INITIAL MIGRATION** only. If you've already synced events to Proton before, using these options again will create duplicates because Proton assigns new UIDs when importing.

**Use these ONLY for:**
- 🆕 **First time:** Moving all your Calcurse events to a new Proton calendar
- 🔄 **Migration:** Switching from another system to Proton
- 📊 **Export/backup:** Creating a .ics file for external use

**After initial migration, ALWAYS use Option A for synchronization.**

**EXDATE handling:** ❌ **Not supported** - use Option A for recurring events

**Why duplicates happen:**
```
First sync:
  Calcurse event: UID=CALCURSE-abc123@hostname
  Export to Proton → Proton assigns new UID=xyz789@proton.me
  
Second sync (using C/D/E):
  Calcurse still has: UID=CALCURSE-abc123@hostname
  Script thinks it's a new event → Exports again
  Proton assigns another new UID → DUPLICATE ❌
  
Solution: Use Option A - it matches by content, not just UID ✅
```

```bash
# ONLY for first-time migration:
csync # Choose option C (all events), D (30 days), or E (custom range)
# After this, ALWAYS use Option A
```

---

#### 🔄 **Option F - Complete Replacement** ⚠️ **DESTRUCTIVE**

Replaces ALL Calcurse content with Proton (one-way sync):
- ✅ Perfect one-way sync: Calcurse becomes exact copy of Proton
- ✅ Handles EXDATE correctly (by replacing everything)
- ✅ Fast: no interaction needed
- ✅ Clean: no duplicates, no conflicts
- ❌ **DELETES everything in Calcurse not in Proton**
- ❌ One-way only: Proton → Calcurse

**Use this for:**
- 🔄 **Proton is master:** You only edit in Proton web, use Calcurse for viewing
- 🆕 **First time setup:** Initial population of Calcurse from Proton
- 🐛 **Reset after problems:** Calcurse got corrupted, start fresh
- 🔧 **Regular workflow:** You prefer Proton web and want terminal read-only access

**Don't use this if:**
- ❌ You add/edit events in Calcurse (they'll be lost)
- ❌ You want bidirectional sync (use A instead)

**EXDATE handling:** ✅ **Works** (by complete replacement)

```bash
csync # Choose option F
# Completely replaces Calcurse with Proton content (creates backup first)
```

---

### 💡 Recommended Workflows

#### **Workflow 1: Bidirectional Sync (Most Common)** ⭐

You use both Proton Calendar and Calcurse actively.

```bash
# Every few days:
1. Download fresh "My Calendar-YYYY-MM-DD.ics" from Proton
2. ./calcurse-sync.sh → Option A
3. Review and confirm changes
4. Import generated file to Proton (if needed)
```

**Benefits:**
- ✅ Full control over changes
- ✅ Handles deleted occurrences correctly
- ✅ No duplicates
- ✅ Safe and reversible

---

#### **Workflow 2: Proton Master (One-Way)**

You only edit in Proton web, use Calcurse for terminal viewing.

```bash
# Weekly:
1. Download fresh calendar from Proton
2. ./calcurse-sync.sh → Option F
3. Done! Calcurse is updated
```

**Benefits:**
- ✅ Very fast (no interaction)
- ✅ Calcurse always matches Proton exactly
- ✅ Simple workflow

**Warning:** Any events added in Calcurse will be deleted!

---

#### **Workflow 3: Initial Setup**

First time using the script.

```bash
# Option A (Recommended - gives you control):
1. Download Proton calendar
2. ./calcurse-sync.sh → Option A
3. Review what will be added/removed
4. Confirm changes

# OR Option F (Faster - if Proton has all events):
1. Download Proton calendar
2. ./calcurse-sync.sh → Option F
3. Calcurse now matches Proton

# After initial setup, always use Option A or F based on your workflow
```

---

### ⚠️ Common Mistakes to Avoid

**❌ Using Option C/D/E repeatedly:**
```bash
# Day 1: Export with Option C → Import to Proton ✅
# Day 2: Export with Option C again → DUPLICATES ❌

# Solution: Use Option A after initial migration ✅
```

**❌ Using Option B for recurring event changes:**
```bash
# You delete Oct 15 occurrence in Proton
# Option B → Doesn't import the deletion ❌
# Calcurse still shows Oct 15

# Solution: Use Option A - it detects EXDATE changes ✅
```

**❌ Using Option F with a bidirectional workflow:**
```bash
# You add events in Calcurse
# Option F → All your Calcurse events deleted ❌

# Solution: Use Option A for bidirectional sync ✅
```

---

### 📊 Quick Reference Table

| Option | Use Case | EXDATE Support | Duplicates Risk | Best For |
|--------|----------|----------------|-----------------|----------|
| **A** | Daily sync | ✅ Full | ❌ No | Everyone (99% of use) |
| **B** | Batch import | ❌ None | ⚠️ Possible | External calendar import |
| **C/D/E** | Export | ❌ None | ⚠️ High | One-time migration only |
| **F** | Replace all | ✅ Works | ❌ No | One-way sync, reset |

---

### 🎯 Final Recommendation

**For most users:**
- Use **Option A** for all synchronization needs
- It handles everything correctly: new events, deletions, EXDATE changes
- Takes a bit longer but prevents all problems

**For Proton-primary users:**
- Use **Option F** for one-way sync (Proton → Calcurse)
- Faster but only if you never edit in Calcurse

**Avoid:**
- Using C/D/E more than once (creates duplicates)
- Using B for recurring event changes (doesn't handle EXDATE)

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

### v1.2 - EXDATE Detection for Recurring Events
- **Smart exclusion detection**: The script now detects when the same recurring event has different exclusions (EXDATE) between Proton and Calcurse
- **Interactive resolution**: When exclusions differ, you can choose which version to keep:
  - Use Proton's exclusions (update Calcurse)
  - Use Calcurse's exclusions (update Proton)
  - Skip and leave both as is
- **Common use case**: If you delete a single occurrence of a recurring event in Proton, the script will now correctly detect that Calcurse still has that occurrence and ask you what to do

**Example scenario:**
- You have a monthly recurring event "Recharge Vodafone" starting Jan 15, 2023
- You delete the October 15, 2025 occurrence in Proton
- Proton adds `EXDATE:20251015T100000` to the event
- Calcurse still has all occurrences
- The script detects the difference and asks if you want to sync the deletion

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
