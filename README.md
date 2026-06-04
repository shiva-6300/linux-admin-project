# 🖥️ Linux Admin Toolkit

A production-ready set of Bash scripts for **server monitoring**, **automated backups**, and **log analysis** — with cron integration, alerting, and rotation.

---

## 📁 Project Structure

```
linux-admin-project/
├── monitor.sh          # CPU / Memory / Disk / Network / Services
├── backup.sh           # Compress, encrypt, rotate backups
├── log_analyzer.sh     # Parse logs for errors, security events, patterns
├── reports/            # Auto-generated reports & logs
│   ├── monitor_*.txt
│   ├── backup_*.txt
│   ├── analysis_*.txt
│   └── *.log
├── backups/            # Compressed backup archives
│   └── <label>/
└── README.md
```

---

## ⚡ Quick Start

```bash
# Make scripts executable
chmod +x monitor.sh backup.sh log_analyzer.sh

# Run server health check
./monitor.sh

# Run backup
./backup.sh

# Analyze logs
./log_analyzer.sh

# Analyze a specific log
./log_analyzer.sh --log /var/log/syslog

# Watch log live (colored by severity)
./log_analyzer.sh --watch --log /var/log/syslog
```

---

## 🔍 monitor.sh

Real-time server health snapshot with alerting.

### What it checks
| Category | Details |
|----------|---------|
| System | Hostname, OS, kernel, uptime, users |
| CPU | Usage %, load average, top 5 processes |
| Memory | RAM used/available, swap, top 5 processes |
| Disk | All filesystems, I/O stats |
| Network | Interface IPs, listening TCP ports |
| Services | Active/inactive status for listed services |
| Security | Failed SSH logins, top attacking IPs |

### Config (edit top of script)
```bash
CPU_THRESHOLD=85       # Alert if CPU > 85%
MEM_THRESHOLD=90       # Alert if RAM > 90%
DISK_THRESHOLD=80      # Warn if disk > 80% full
SERVICES="sshd nginx"  # Services to check
```

### Output
- Terminal: colored output with `[WARN]` / `[CRIT]` badges
- File: `reports/monitor_YYYY-MM-DD_HH-MM-SS.txt`

---

## 💾 backup.sh

Automated backup with compression, optional encryption, and retention rotation.

### Features
- ✅ Configurable source targets (label:path pairs)
- ✅ gzip compression (level 1–9)
- ✅ GPG symmetric encryption (`--encrypt`)
- ✅ Incremental backups via tar snapshots (`--incremental`)
- ✅ Dry-run mode (`--dry-run`)
- ✅ Auto-rotation (keep N backups per target)
- ✅ Archive integrity verification
- ✅ Manifest tracking in `backups/manifest.txt`

### Usage
```bash
./backup.sh                          # Full backup
./backup.sh --dry-run                # Preview without writing
./backup.sh --incremental            # Only changed files
./backup.sh --encrypt                # GPG encrypt (set ENCRYPT_PASSPHRASE)
./backup.sh --incremental --encrypt  # Combined
```

### Config (edit top of script)
```bash
BACKUP_TARGETS=(
  "reports:./reports"
  "home:/home/myuser"
  "etc:/etc"
  "www:/var/www/html"
)
RETENTION_COUNT=7    # Keep 7 backups per target
COMPRESS_LEVEL=6     # gzip level (1=fast, 9=max)
```

### Encryption
```bash
export ENCRYPT_PASSPHRASE="your-strong-passphrase"
./backup.sh --encrypt

# Decrypt later
gpg --decrypt backups/label/label_DATE.tar.gz.gpg > restored.tar.gz
tar -xzf restored.tar.gz
```

---

## 📊 log_analyzer.sh

Intelligent log parser for errors, security events, and anomaly detection.

### Features
- ✅ Severity classification (CRITICAL / ERROR / WARNING / INFO)
- ✅ Time-window filtering (`--hours N`)
- ✅ Most repeated message detection
- ✅ Process/service error attribution
- ✅ SSH brute-force detection (failed logins, attacker IPs)
- ✅ OOM / disk error / segfault detection
- ✅ Hourly activity timeline
- ✅ Live tail with color coding (`--watch`)
- ✅ CSV export (`--format csv`)

### Usage
```bash
# Analyze default system log (last 24h)
./log_analyzer.sh

# Analyze specific log
./log_analyzer.sh --log /var/log/nginx/access.log

# Last 6 hours only
./log_analyzer.sh --hours 6

# Export as CSV
./log_analyzer.sh --format csv > results.csv

# Live monitoring
./log_analyzer.sh --watch --log /var/log/syslog

# Top 20 results
./log_analyzer.sh --top 20
```

---

## ⏰ Cron Jobs

Add these to your crontab (`crontab -e`):

```cron
# ┌─ minute (0-59)
# │  ┌─ hour (0-23)
# │  │  ┌─ day of month (1-31)
# │  │  │  ┌─ month (1-12)
# │  │  │  │  ┌─ day of week (0-6, 0=Sun)
# │  │  │  │  │
# │  │  │  │  │
# Server health check every 15 minutes
*/15 *  *  *  *  /path/to/linux-admin-project/monitor.sh >> /dev/null 2>&1

# Full backup every day at 2 AM
0    2  *  *  *  /path/to/linux-admin-project/backup.sh >> /dev/null 2>&1

# Incremental backup every 6 hours
0   */6 *  *  *  /path/to/linux-admin-project/backup.sh --incremental >> /dev/null 2>&1

# Log analysis report every morning at 6 AM
0    6  *  *  *  /path/to/linux-admin-project/log_analyzer.sh >> /dev/null 2>&1

# Weekly full backup with encryption on Sundays at 1 AM
0    1  *  *  0  ENCRYPT_PASSPHRASE="mypass" /path/to/linux-admin-project/backup.sh --encrypt >> /dev/null 2>&1
```

Install with:
```bash
# Edit current user's crontab
crontab -e

# Or install as root for system-wide tasks
sudo crontab -e

# Verify installed jobs
crontab -l
```

---

## 🔧 Troubleshooting

### Scripts won't run
```bash
chmod +x monitor.sh backup.sh log_analyzer.sh
```

### monitor.sh: "permission denied" on logs
```bash
sudo ./monitor.sh
# Or add user to adm group
sudo usermod -aG adm $USER
```

### backup.sh: GPG encryption fails
```bash
# Make sure gpg is installed
sudo apt install gnupg   # Debian/Ubuntu
sudo yum install gnupg2  # RHEL/CentOS

# Test encryption
echo "test" | gpg --symmetric --cipher-algo AES256 --batch --passphrase "pass" > /dev/null && echo OK
```

### log_analyzer.sh: No logs found
```bash
# Check which logs exist
ls -la /var/log/

# Point directly at a log
./log_analyzer.sh --log /var/log/syslog
```

### Cron jobs not running
```bash
# Check cron daemon
systemctl status cron   # Debian/Ubuntu
systemctl status crond  # RHEL/CentOS

# Check cron logs
grep cron /var/log/syslog | tail -20

# Test script manually first
bash -x ./monitor.sh
```

---

## 📋 Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `bash` ≥ 4.0 | Script runtime | pre-installed |
| `tar` | Backup archives | pre-installed |
| `gzip` | Compression | pre-installed |
| `gpg` | Encryption (optional) | `apt install gnupg` |
| `ss` or `netstat` | Port listing | pre-installed / `apt install net-tools` |
| `iostat` | Disk I/O (optional) | `apt install sysstat` |
| `systemctl` | Service checks | pre-installed (systemd) |

---

## 📜 License

MIT — free to use, modify, and distribute.
