# csync

🔄 Proton Calendar ↔ Calcurse Sync Tool

A bash script that manually synchronizes events between **Proton Calendar** and **Calcurse**, bridging the gap between modern cloud calendars and efficient terminal-based scheduling.

## ✨ Features

- 🔄 **Bidirectional Sync** - Keep both calendars in sync manually
- 🚨 **Smart Alarm Conversion** - Normalizes reminders between systems
- 📅 **Flexible Time Ranges** - Sync all events or just future ones
- 💾 **Automatic Backups** - Never lose data with backup rotation
- 📊 **Interactive Reports** - See exactly what needs synchronization
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
wget -O calcurse-sync.sh https://codeberg.org/rgc/csync/src/branch/master/calcurse-sync.sh
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

### Basic Workflow

1. **Always start by downloading from Proton:**
   - Go to Proton Calendar → Settings → Export
   - Download your calendar as `.ics` file
   - Save it as `My Calendar-YYYY-MM-DD.ics` in your calendar directory

2. **Run the sync tool:**

```bash
cd ~/Projects/calendar
./calcurse-sync.sh

# or if you created the symlink:
csync
```

### Sync Options

```
🔔 RICORDA: Assicurati di avere scaricato il file AGGIORNATO da Proton Calendar

Scegli un'opzione:
A) Importa eventi da Proton (merge - SOLO aggiunte)
B) Sincronizza eventi con Proton (SOLO aggiunte)
C) Sincronizza solo eventi futuri (30 giorni)
D) Sincronizza con intervallo personalizzato
---------
E) 🧹 SYNC BIDIREZIONALE GUIDATA: Calcurse ↔ Proton + report
F) 🔄 SYNC COMPLETA: Proton → Calcurse (SOSTITUISCE tutto)
---------
Q) ❌ Esci senza operazioni
```

### Recommended Sync Strategy

**For regular use:**

```bash
# 1. First import any new events from Proton to Calcurse
csync # Choose option A

# 2. Then export any new Calcurse events to Proton
csync # Choose option B, C, or D

# 3. Import the generated file (nuovi-appuntamenti-calcurse.ics) into Proton Calendar manually
```

**For guided bidirectional sync with report:**

```bash
# Review changes before applying them
csync # Choose option E
```

**For complete resynchronization (replaces everything):**

```bash
# Complete replacement: Proton → Calcurse
csync # Choose option F
```

## ⚙️ File Structure

```
~/Projects/calendar/
├── calcurse-sync.sh                    # Main sync script
├── calendar.ics                        # Current Proton calendar data
├── calendario.ics                      # Current Calcurse export
├── nuovi-appuntamenti-calcurse.ics     # New events for Proton
├── sync-report.txt                     # Bidirectional sync report
└── backup_YYYYMMDD-HHMMSS.ics          # Automatic backups (last 3 kept)
```

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

### File Locations

- **Calcurse data:** `~/.local/share/calcurse/` or `~/.calcurse/`
- **Script directory:** `~/Projects/calendar/` (configurable)

## 🤝 Contributing

Feel free to submit issues and pull requests to improve the synchronization logic or add new features.

## 📄 License

This project is open source and available under the MIT License.
