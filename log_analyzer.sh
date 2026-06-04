#!/bin/bash
# =============================================================================
# log_analyzer.sh - Intelligent Log Analyzer
# Parses system logs for errors, patterns, anomalies, and security events
# Usage: ./log_analyzer.sh [--log FILE] [--hours N] [--format text|csv] [--watch]
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
ANALYZER_LOG="${REPORT_DIR}/analyzer.log"

# Default log files to analyze (first found wins, or override with --log)
DEFAULT_LOGS=(
  /var/log/syslog
  /var/log/messages
  /var/log/auth.log
  /var/log/secure
  /var/log/kern.log
  /var/log/nginx/access.log
  /var/log/apache2/access.log
)

# Analysis window (hours back from now)
HOURS_BACK=24

# Output format: text | csv
OUTPUT_FORMAT="text"

# Watch mode: tail log live
WATCH_MODE=false

# Severity pattern mappings
declare -A SEVERITY_PATTERNS=(
  [CRITICAL]="critical|panic|emergency|CRITICAL|PANIC"
  [ERROR]="error|ERROR|failed|FAILED|failure|FAILURE"
  [WARNING]="warning|WARNING|warn|WARN"
  [INFO]="info|INFO|notice|NOTICE"
)

# Top-N settings
TOP_N=10

# ── Arg parsing ───────────────────────────────────────────────────────────────
LOG_FILE_OVERRIDE=""
SPECIFIC_LOG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)       SPECIFIC_LOG="$2"; shift 2 ;;
    --hours)     HOURS_BACK="$2"; shift 2 ;;
    --format)    OUTPUT_FORMAT="$2"; shift 2 ;;
    --watch)     WATCH_MODE=true; shift ;;
    --top)       TOP_N="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo "  --log FILE      Analyze specific log file"
      echo "  --hours N       Look back N hours (default: 24)"
      echo "  --format FMT    Output format: text | csv (default: text)"
      echo "  --top N         Show top N results (default: 10)"
      echo "  --watch         Tail log file in real-time (Ctrl+C to stop)"
      exit 0 ;;
    *)  shift ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; MAGENTA=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$ANALYZER_LOG"; }
info() { echo -e "${CYAN}→${RESET} $*"; }

section() {
  echo ""
  echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${CYAN}│  $1${RESET}"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${RESET}"
}

find_log_file() {
  if [ -n "$SPECIFIC_LOG" ]; then
    if [ -f "$SPECIFIC_LOG" ]; then
      echo "$SPECIFIC_LOG"
    else
      echo ""
    fi
    return
  fi
  for f in "${DEFAULT_LOGS[@]}"; do
    [ -f "$f" ] && { echo "$f"; return; }
  done
  echo ""
}

count_pattern() {
  local file="$1" pattern="$2"
  grep -ciE "$pattern" "$file" 2>/dev/null || echo 0
}

get_time_filtered_content() {
  local file="$1"
  local cutoff
  cutoff=$(date -d "${HOURS_BACK} hours ago" '+%Y-%m-%dT%H:%M' 2>/dev/null \
           || date -v "-${HOURS_BACK}H" '+%Y-%m-%dT%H:%M' 2>/dev/null \
           || date '+%Y-%m-%dT%H:%M')  # fallback: no filter
  
  # Try to filter by time (works for ISO timestamp logs)
  awk -v cutoff="$cutoff" '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ { if ($1 >= cutoff) print; next }
    { print }
  ' "$file" 2>/dev/null || cat "$file"
}

severity_badge() {
  local level="$1"
  case "$level" in
    CRITICAL) echo -e "${RED}[CRITICAL]${RESET}" ;;
    ERROR)    echo -e "${RED}[ERROR]${RESET}   " ;;
    WARNING)  echo -e "${YELLOW}[WARN]${RESET}    " ;;
    INFO)     echo -e "${GREEN}[INFO]${RESET}    " ;;
    *)        echo "[$level]" ;;
  esac
}

# ── Watch mode ────────────────────────────────────────────────────────────────
watch_log() {
  local file="$1"
  echo -e "${BOLD}${CYAN}Watching: $file${RESET}  (Ctrl+C to stop)"
  echo ""
  tail -F "$file" 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -qiE "${SEVERITY_PATTERNS[CRITICAL]}"; then
      echo -e "${RED}${line}${RESET}"
    elif echo "$line" | grep -qiE "${SEVERITY_PATTERNS[ERROR]}"; then
      echo -e "${RED}${line}${RESET}"
    elif echo "$line" | grep -qiE "${SEVERITY_PATTERNS[WARNING]}"; then
      echo -e "${YELLOW}${line}${RESET}"
    else
      echo "$line"
    fi
  done
}

# ── CSV output ────────────────────────────────────────────────────────────────
output_csv() {
  local file="$1"
  local report_csv="${REPORT_DIR}/analysis_${TIMESTAMP}.csv"
  
  echo "timestamp,level,count,source"
  for level in CRITICAL ERROR WARNING INFO; do
    count=$(count_pattern "$file" "${SEVERITY_PATTERNS[$level]}")
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$level,$count,$(basename "$file")"
  done | tee "$report_csv"
  
  echo "" >&2
  echo "CSV saved: $report_csv" >&2
}

# ── Core analysis ─────────────────────────────────────────────────────────────
analyze_log() {
  local file="$1"
  local report_file="${REPORT_DIR}/analysis_${TIMESTAMP}.txt"
  
  info "Analyzing: $file"
  info "Time window: last ${HOURS_BACK} hours"
  log "Analyzing $file (last ${HOURS_BACK}h)"
  
  # Get filtered content into temp file
  local tmp_content
  tmp_content=$(mktemp)
  get_time_filtered_content "$file" > "$tmp_content"
  local total_lines
  total_lines=$(wc -l < "$tmp_content")
  
  {
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           LOG ANALYSIS REPORT                           ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "Log File   : $file"
  echo "Analyzed   : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Time Window: Last ${HOURS_BACK} hours"
  echo "Total Lines: $total_lines"
  echo "File Size  : $(du -sh "$file" 2>/dev/null | cut -f1)"

  # ── Severity counts ──────────────────────────────────────────────────────
  section "SEVERITY SUMMARY"
  printf "  %-12s %8s\n" "Level" "Count"
  printf "  %-12s %8s\n" "────────────" "────────"
  
  declare -A counts
  for level in CRITICAL ERROR WARNING INFO; do
    counts[$level]=$(count_pattern "$tmp_content" "${SEVERITY_PATTERNS[$level]}")
    printf "  %-12s %8s\n" "$level" "${counts[$level]}"
  done

  # ── Critical & Error details ─────────────────────────────────────────────
  for level in CRITICAL ERROR; do
    if [ "${counts[$level]}" -gt 0 ]; then
      section "${level} MESSAGES (top ${TOP_N})"
      grep -iE "${SEVERITY_PATTERNS[$level]}" "$tmp_content" 2>/dev/null \
        | tail -n "$TOP_N" \
        | while IFS= read -r line; do echo "  $line"; done
    fi
  done

  # ── Warning sample ───────────────────────────────────────────────────────
  if [ "${counts[WARNING]:-0}" -gt 0 ]; then
    section "WARNING MESSAGES (sample ${TOP_N})"
    grep -iE "${SEVERITY_PATTERNS[WARNING]}" "$tmp_content" 2>/dev/null \
      | tail -n "$TOP_N" \
      | while IFS= read -r line; do echo "  $line"; done
  fi

  # ── Repeated messages ────────────────────────────────────────────────────
  section "MOST REPEATED MESSAGES (top ${TOP_N})"
  sort "$tmp_content" | uniq -c | sort -rn | head -n "$TOP_N" \
    | awk '{count=$1; $1=""; printf "  %6s × %s\n", count, $0}'

  # ── Unique error sources ─────────────────────────────────────────────────
  section "ERROR SOURCES — PROCESS/SERVICE (top ${TOP_N})"
  grep -iE "${SEVERITY_PATTERNS[ERROR]}|${SEVERITY_PATTERNS[CRITICAL]}" "$tmp_content" 2>/dev/null \
    | grep -oP '(?<=\]|\)| )[a-zA-Z0-9_/-]+(?=\[|\()' \
    | sort | uniq -c | sort -rn | head -n "$TOP_N" \
    | awk '{printf "  %6s × %s\n", $1, $2}' \
    || echo "  (unable to extract process names)"

  # ── Security events ──────────────────────────────────────────────────────
  section "SECURITY EVENTS"
  
  SSH_FAIL=$(grep -c "Failed password\|authentication failure\|Invalid user" "$tmp_content" 2>/dev/null || echo 0)
  SSH_OK=$(grep -c "Accepted password\|Accepted publickey" "$tmp_content" 2>/dev/null || echo 0)
  SUDO=$(grep -c "sudo\|SUDO" "$tmp_content" 2>/dev/null || echo 0)
  
  printf "  %-30s %s\n" "Failed logins"    "$SSH_FAIL"
  printf "  %-30s %s\n" "Successful logins" "$SSH_OK"
  printf "  %-30s %s\n" "Sudo commands"     "$SUDO"
  
  if [ "$SSH_FAIL" -gt 0 ]; then
    echo ""
    echo "  Top brute-force IPs:"
    grep -E "Failed password|Invalid user" "$tmp_content" 2>/dev/null \
      | grep -oP 'from \K[\d.]+' 2>/dev/null \
      | sort | uniq -c | sort -rn | head -5 \
      | awk '{printf "    %6s attempts from %s\n", $1, $2}' \
      || echo "    (none found)"
  fi

  # ── Disk/OOM events ──────────────────────────────────────────────────────
  section "SYSTEM EVENTS"
  
  OOM=$(grep -c "Out of memory\|OOM killer\|oom_kill" "$tmp_content" 2>/dev/null || echo 0)
  DISK_ERR=$(grep -c "I/O error\|disk error\|EXT4-fs error\|XFS.*error" "$tmp_content" 2>/dev/null || echo 0)
  SEGFAULT=$(grep -c "segfault\|segmentation fault" "$tmp_content" 2>/dev/null || echo 0)
  KERNEL=$(grep -c "kernel:" "$tmp_content" 2>/dev/null || echo 0)
  
  printf "  %-30s %s\n" "OOM kills"     "$OOM"
  printf "  %-30s %s\n" "Disk/IO errors" "$DISK_ERR"
  printf "  %-30s %s\n" "Segfaults"     "$SEGFAULT"
  printf "  %-30s %s\n" "Kernel messages" "$KERNEL"
  
  [ "$OOM" -gt 0 ]      && echo "  ⚠  OOM events detected! Check memory usage."
  [ "$DISK_ERR" -gt 0 ] && echo "  ⚠  Disk/IO errors detected! Inspect hardware."
  [ "$SEGFAULT" -gt 0 ] && echo "  ⚠  Segfaults detected! Check application logs."

  # ── Activity timeline ────────────────────────────────────────────────────
  section "ACTIVITY TIMELINE (errors per hour)"
  grep -iE "${SEVERITY_PATTERNS[ERROR]}|${SEVERITY_PATTERNS[CRITICAL]}" "$tmp_content" 2>/dev/null \
    | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}|\w{3} [ 0-9]\d \d{2}' \
    | sort | uniq -c \
    | awk '{printf "  %s  %s errors\n", $2, $1}' \
    | tail -24 \
    || echo "  (timestamp format not recognized for timeline)"

  # ── Footer ───────────────────────────────────────────────────────────────
  echo ""
  echo "════════════════════════════════════════════"
  echo "Report saved: $report_file"
  echo "────────────────────────────────────────────"
  
  } | tee "$report_file"
  
  rm -f "$tmp_content"
  log "Analysis report saved: $report_file"
}

# ── Multiple log analysis ─────────────────────────────────────────────────────
analyze_all_available() {
  local analyzed=0
  for f in "${DEFAULT_LOGS[@]}"; do
    if [ -f "$f" ] && [ -r "$f" ]; then
      analyze_log "$f"
      (( analyzed++ )) || true
    fi
  done
  [ "$analyzed" -eq 0 ] && echo "No readable log files found. Try running as root or use --log FILE"
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  mkdir -p "$REPORT_DIR"
  
  local target_log
  target_log=$(find_log_file)
  
  # Watch mode
  if $WATCH_MODE; then
    if [ -z "$target_log" ]; then
      echo "No log file found for watching. Use --log FILE"
      exit 1
    fi
    watch_log "$target_log"
    return
  fi
  
  # CSV mode
  if [ "$OUTPUT_FORMAT" = "csv" ]; then
    if [ -z "$target_log" ]; then
      echo "No log file found. Use --log FILE"
      exit 1
    fi
    output_csv "$target_log"
    return
  fi
  
  # Standard analysis
  if [ -n "$SPECIFIC_LOG" ]; then
    if [ ! -f "$SPECIFIC_LOG" ]; then
      echo "Log file not found: $SPECIFIC_LOG"
      exit 1
    fi
    analyze_log "$SPECIFIC_LOG"
  elif [ -n "$target_log" ]; then
    analyze_log "$target_log"
  else
    echo ""
    echo -e "${YELLOW}No standard log files found. Analyzing all available...${RESET}"
    analyze_all_available
  fi
}

main "$@"
