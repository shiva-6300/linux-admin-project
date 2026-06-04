#!/bin/bash
# =============================================================================
# monitor.sh - Linux Server Monitoring Script
# Tracks CPU, Memory, Disk, Network, and running services
# Generates timestamped reports in reports/
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
REPORT_FILE="${REPORT_DIR}/monitor_${TIMESTAMP}.txt"
LOG_FILE="${REPORT_DIR}/monitor.log"

# Alert thresholds
CPU_THRESHOLD=85       # % usage
MEM_THRESHOLD=90       # % usage
DISK_THRESHOLD=80      # % usage
LOAD_MULTIPLIER=2      # load avg > N * CPU cores = warning

# Services to monitor (space-separated)
SERVICES="sshd cron"

# Colors (only when stdout is a terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*" | tee -a "$LOG_FILE"; }
crit() { echo -e "${RED}[CRIT]${RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${RESET}   $*"; }

section() {
  local title="$1"
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $title${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}"
}

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"

{
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         SERVER MONITORING REPORT                        ║"
echo "║  Host: $(hostname -f 2>/dev/null || hostname)            "
echo "║  Date: $(date '+%A, %d %B %Y %H:%M:%S %Z')              "
echo "╚══════════════════════════════════════════════════════════╝"

# ── 1. System Info ────────────────────────────────────────────────────────────
section "SYSTEM INFORMATION"
echo "Hostname    : $(hostname -f 2>/dev/null || hostname)"
echo "OS          : $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || uname -s)"
echo "Kernel      : $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Uptime      : $(uptime -p 2>/dev/null || uptime)"
echo "Last Boot   : $(who -b 2>/dev/null | awk '{print $3, $4}' || uptime)"
echo "Users Online: $(who | wc -l)"

# ── 2. CPU ────────────────────────────────────────────────────────────────────
section "CPU USAGE"
CPU_CORES=$(nproc)
echo "CPU Cores   : $CPU_CORES"

# Load averages
LOAD=$(cat /proc/loadavg)
LOAD1=$(echo $LOAD  | awk '{print $1}')
LOAD5=$(echo $LOAD  | awk '{print $2}')
LOAD15=$(echo $LOAD | awk '{print $3}')
echo "Load Avg    : 1m=$LOAD1  5m=$LOAD5  15m=$LOAD15"

LOAD_WARN=$(echo "$LOAD1 $CPU_CORES $LOAD_MULTIPLIER" | awk '{if ($1 > $2 * $3) print "YES"; else print "NO"}')
[ "$LOAD_WARN" = "YES" ] && warn "High load average: $LOAD1 (threshold: $((CPU_CORES * LOAD_MULTIPLIER)))"

# CPU usage via /proc/stat (skip leading 'cpu' label)
read _LABEL CPU_A1 CPU_A2 CPU_A3 CPU_A4 REST < /proc/stat
sleep 1
read _LABEL CPU_B1 CPU_B2 CPU_B3 CPU_B4 REST < /proc/stat
IDLE_A=$CPU_A4; TOTAL_A=$((CPU_A1+CPU_A2+CPU_A3+CPU_A4))
IDLE_B=$CPU_B4; TOTAL_B=$((CPU_B1+CPU_B2+CPU_B3+CPU_B4))
CPU_USED=$(( (100 * (TOTAL_B - TOTAL_A - (IDLE_B - IDLE_A))) / (TOTAL_B - TOTAL_A) ))
echo "CPU Usage   : ${CPU_USED}%"

[ "$CPU_USED" -ge "$CPU_THRESHOLD" ] && crit "CPU usage ${CPU_USED}% exceeds threshold ${CPU_THRESHOLD}%"

# Top 5 CPU processes
echo ""
echo "Top 5 Processes by CPU:"
ps aux --sort=-%cpu 2>/dev/null | head -6 | awk 'NR==1{print} NR>1{printf "  %-10s %-6s %-6s %s\n", $1, $3, $4, $11}'

# ── 3. Memory ─────────────────────────────────────────────────────────────────
section "MEMORY USAGE"
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemFree  /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}' 2>/dev/null || echo $MEM_FREE)
MEM_BUFFERS=$(grep Buffers /proc/meminfo | awk '{print $2}')
MEM_CACHED=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE=$(grep SwapFree  /proc/meminfo | awk '{print $2}')

MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
MEM_TOTAL_MB=$((MEM_TOTAL / 1024))
MEM_USED_MB=$((MEM_USED   / 1024))
MEM_AVAIL_MB=$((MEM_AVAIL / 1024))

echo "Total RAM   : ${MEM_TOTAL_MB} MB"
echo "Used        : ${MEM_USED_MB} MB  (${MEM_PCT}%)"
echo "Available   : ${MEM_AVAIL_MB} MB"

if [ "$SWAP_TOTAL" -gt 0 ]; then
  SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
  SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
  echo "Swap Total  : $((SWAP_TOTAL / 1024)) MB"
  echo "Swap Used   : $((SWAP_USED  / 1024)) MB  (${SWAP_PCT}%)"
else
  echo "Swap        : none"
fi

[ "$MEM_PCT" -ge "$MEM_THRESHOLD" ] && crit "Memory usage ${MEM_PCT}% exceeds threshold ${MEM_THRESHOLD}%"

echo ""
echo "Top 5 Processes by Memory:"
ps aux --sort=-%mem 2>/dev/null | head -6 | awk 'NR==1{print} NR>1{printf "  %-10s %-6s %-6s %s\n", $1, $3, $4, $11}'

# ── 4. Disk ───────────────────────────────────────────────────────────────────
section "DISK USAGE"
echo "Filesystem Usage:"
df -hT 2>/dev/null | grep -v tmpfs | grep -v udev | awk '
  NR==1 { print; next }
  {
    use = $6; gsub(/%/,"",use)
    if (use+0 >= '"$DISK_THRESHOLD"')
      printf "  ⚠ %s\n", $0
    else
      printf "    %s\n", $0
  }
'

echo ""
echo "Disk I/O (if available):"
if command -v iostat &>/dev/null; then
  iostat -d 1 1 2>/dev/null | grep -v "^$" | tail -n +3 | head -10
else
  cat /proc/diskstats 2>/dev/null | awk '$3 ~ /^(sd|nvme|vd)/ {print "  "$3": reads="$4" writes="$8}' | head -5
fi

# ── 5. Network ────────────────────────────────────────────────────────────────
section "NETWORK"
echo "Interfaces:"
ip -br addr 2>/dev/null || ifconfig 2>/dev/null | grep -E "^[a-z]|inet " || echo "  (ip/ifconfig not available)"

echo ""
echo "Listening Ports (TCP):"
ss -tlnp 2>/dev/null | grep LISTEN | awk '{printf "  %-25s %s\n", $4, $6}' | head -20 \
  || netstat -tlnp 2>/dev/null | grep LISTEN | head -20 \
  || echo "  (ss/netstat not available)"

# ── 6. Services ───────────────────────────────────────────────────────────────
section "SERVICE STATUS"
for svc in $SERVICES; do
  if command -v systemctl &>/dev/null; then
    STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
  else
    STATUS=$(service "$svc" status &>/dev/null && echo "active" || echo "inactive")
  fi
  if [ "$STATUS" = "active" ]; then
    echo "  [UP]   $svc"
  else
    echo "  [DOWN] $svc  ← $STATUS"
    warn "Service '$svc' is $STATUS"
  fi
done

# ── 7. Failed Systemd Units ───────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
  section "FAILED SYSTEMD UNITS"
  FAILED=$(systemctl --failed --no-legend 2>/dev/null | head -10)
  if [ -z "$FAILED" ]; then
    echo "  No failed units."
  else
    echo "$FAILED" | while IFS= read -r line; do
      warn "Failed: $line"
    done
  fi
fi

# ── 8. Recent Auth Failures ───────────────────────────────────────────────────
section "SECURITY - RECENT AUTH FAILURES (last 24h)"
AUTH_LOG=""
for f in /var/log/auth.log /var/log/secure; do
  [ -f "$f" ] && AUTH_LOG="$f" && break
done

if [ -n "$AUTH_LOG" ]; then
  FAILURES=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | \
    awk -v d="$(date -d '24 hours ago' '+%b %e %H:%M:%S' 2>/dev/null || date '+%b %e %H:%M:%S')" '$0 > d' | \
    wc -l 2>/dev/null || echo 0)
  echo "  Failed SSH logins (24h): $FAILURES"
  echo "  Top attacking IPs:"
  grep "Failed password" "$AUTH_LOG" 2>/dev/null | \
    grep -oP 'from \K[\d.]+' | sort | uniq -c | sort -rn | head -5 | \
    awk '{printf "    %s attempts from %s\n", $1, $2}' || echo "    (none)"
else
  echo "  Auth log not found (may need root)"
fi

# ── Footer ────────────────────────────────────────────────────────────────────
section "SUMMARY"
echo "Report generated : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Report saved to  : $REPORT_FILE"
echo ""
echo "════════════════ END OF REPORT ════════════════"

} | tee "$REPORT_FILE"

log "Monitor report saved: $REPORT_FILE"
