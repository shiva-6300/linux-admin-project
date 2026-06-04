#!/bin/bash
# =============================================================================
# backup.sh - Automated Backup Script
# Supports: local dirs, incremental mode, compression, encryption, rotation
# Usage:    ./backup.sh [--dry-run] [--incremental] [--encrypt]
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="${REPORT_DIR}/backup.log"
BACKUP_MANIFEST="${BACKUP_DIR}/manifest.txt"

# What to back up: "label:source_path" pairs (space-separated)
BACKUP_TARGETS=(
  "reports:${SCRIPT_DIR}/reports"
  # "home:/home/username"
  # "etc:/etc"
  # "www:/var/www/html"
)

# Retention: keep this many backups per target
RETENTION_COUNT=7

# Compression level 1-9 (1=fast, 9=max compression)
COMPRESS_LEVEL=6

# Optional: set ENCRYPT_PASSPHRASE env var to enable GPG symmetric encryption
ENCRYPT_PASSPHRASE="${ENCRYPT_PASSPHRASE:-}"

# ── Flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
INCREMENTAL=false
ENCRYPT=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --incremental) INCREMENTAL=true ;;
    --encrypt)     ENCRYPT=true ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--incremental] [--encrypt]"
      echo "  --dry-run      Show what would be backed up, no files written"
      echo "  --incremental  Only backup files changed since last run"
      echo "  --encrypt      Encrypt archives with GPG (requires ENCRYPT_PASSPHRASE)"
      exit 0 ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "$msg" | tee -a "$LOG_FILE"; }
log_ok()  { echo -e "${GREEN}✔${RESET}  $*"; log "OK: $*"; }
log_err() { echo -e "${RED}✘${RESET}  $*"; log "ERROR: $*"; }
log_inf() { echo -e "${CYAN}→${RESET}  $*"; log "INFO: $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; log "WARN: $*"; }

human_size() {
  local bytes=$1
  if   [ "$bytes" -ge $((1024**3)) ]; then echo "$(( bytes / 1024**3 )) GB"
  elif [ "$bytes" -ge $((1024**2)) ]; then echo "$(( bytes / 1024**2 )) MB"
  elif [ "$bytes" -ge 1024 ];         then echo "$(( bytes / 1024 )) KB"
  else echo "${bytes} B"; fi
}

check_deps() {
  local missing=()
  for cmd in tar gzip; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if $ENCRYPT; then
    command -v gpg &>/dev/null || missing+=("gpg")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    log_err "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

# ── Rotate old backups ────────────────────────────────────────────────────────
rotate_backups() {
  local label="$1"
  local target_backup_dir="${BACKUP_DIR}/${label}"
  
  # Count existing backups for this label
  local count
  count=$(find "$target_backup_dir" -maxdepth 1 -name "*.tar.gz*" 2>/dev/null | wc -l)
  
  if [ "$count" -ge "$RETENTION_COUNT" ]; then
    local to_delete=$(( count - RETENTION_COUNT + 1 ))
    log_inf "Rotating: removing $to_delete old backup(s) for '$label' (keeping ${RETENTION_COUNT})"
    
    find "$target_backup_dir" -maxdepth 1 -name "*.tar.gz*" \
      | sort | head -n "$to_delete" | while IFS= read -r old_file; do
        if $DRY_RUN; then
          echo "  [DRY-RUN] Would delete: $old_file"
        else
          rm -f "$old_file"
          log "Deleted old backup: $old_file"
        fi
      done
  fi
}

# ── Verify backup integrity ───────────────────────────────────────────────────
verify_backup() {
  local archive="$1"
  log_inf "Verifying integrity: $(basename "$archive")"
  
  if tar -tzf "$archive" &>/dev/null; then
    log_ok "Integrity check passed"
    return 0
  else
    log_err "Integrity check FAILED for $archive"
    return 1
  fi
}

# ── Main backup function ──────────────────────────────────────────────────────
do_backup() {
  local label="$1"
  local source="$2"
  local target_backup_dir="${BACKUP_DIR}/${label}"
  local archive_name="${label}_${TIMESTAMP}.tar.gz"
  local archive_path="${target_backup_dir}/${archive_name}"
  local incremental_snapshot="${target_backup_dir}/.snapshot"
  
  echo ""
  echo -e "${BOLD}${CYAN}── Backing up: ${label} ──────────────────────────────${RESET}"
  
  # Validate source
  if [ ! -e "$source" ]; then
    warn "Source not found, skipping: $source"
    return 1
  fi
  
  # Dry-run early exit
  if $DRY_RUN; then
    local src_size
    src_size=$(du -sb "$source" 2>/dev/null | awk '{print $1}' || echo 0)
    echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would backup: $source"
    echo -e "  ${YELLOW}[DRY-RUN]${RESET} Source size: $(human_size $src_size)"
    echo -e "  ${YELLOW}[DRY-RUN]${RESET} Archive: $archive_path"
    $INCREMENTAL && echo -e "  ${YELLOW}[DRY-RUN]${RESET} Mode: incremental"
    return 0
  fi
  
  mkdir -p "$target_backup_dir"
  
  # Rotate before creating new backup
  rotate_backups "$label"
  
  # Build tar options
  export GZIP="-${COMPRESS_LEVEL}"
  TAR_OPTS=(-czf "$archive_path")
  
  # Incremental mode
  if $INCREMENTAL; then
    TAR_OPTS+=(--listed-incremental="$incremental_snapshot")
    log_inf "Incremental mode using snapshot: $incremental_snapshot"
  fi
  
  # Create archive
  local start_ts=$SECONDS
  log_inf "Creating archive: $archive_path"
  
  if tar "${TAR_OPTS[@]}" -C "$(dirname "$source")" "$(basename "$source")" 2>>"$LOG_FILE"; then
    local duration=$(( SECONDS - start_ts ))
    local archive_size
    archive_size=$(stat -c%s "$archive_path" 2>/dev/null || stat -f%z "$archive_path" 2>/dev/null || echo 0)
    log_ok "Archive created in ${duration}s — size: $(human_size $archive_size)"
  else
    log_err "Failed to create archive: $archive_path"
    rm -f "$archive_path"
    return 1
  fi
  
  # Encrypt if requested
  if $ENCRYPT; then
    if [ -z "$ENCRYPT_PASSPHRASE" ]; then
      warn "ENCRYPT_PASSPHRASE not set; skipping encryption"
    else
      log_inf "Encrypting archive with GPG..."
      echo "$ENCRYPT_PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 \
        --symmetric --cipher-algo AES256 \
        --output "${archive_path}.gpg" "$archive_path" 2>>"$LOG_FILE"
      rm -f "$archive_path"
      archive_path="${archive_path}.gpg"
      log_ok "Encrypted: $(basename "$archive_path")"
    fi
  fi
  
  # Verify
  if [[ "$archive_path" != *.gpg ]]; then
    verify_backup "$archive_path"
  fi
  
  # Update manifest
  echo "${TIMESTAMP}|${label}|${source}|${archive_path}|$(stat -c%s "$archive_path" 2>/dev/null || echo 0)" \
    >> "$BACKUP_MANIFEST"
  
  echo "$archive_path"
}

# ── Generate backup report ────────────────────────────────────────────────────
generate_report() {
  local success_count="$1"
  local fail_count="$2"
  local total_size="$3"
  local duration="$4"
  local report_file="${REPORT_DIR}/backup_${TIMESTAMP}.txt"
  
  {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              BACKUP REPORT                              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host       : $(hostname)"
    echo "Mode       : $([ "$INCREMENTAL" = true ] && echo incremental || echo full)"
    echo "Encrypted  : $([ "$ENCRYPT" = true ] && echo yes || echo no)"
    echo "Dry Run    : $([ "$DRY_RUN" = true ] && echo yes || echo no)"
    echo ""
    echo "────────────────────────────────────────"
    echo "  Targets Total  : ${#BACKUP_TARGETS[@]}"
    echo "  Succeeded      : $success_count"
    echo "  Failed         : $fail_count"
    echo "  Total Size     : $(human_size $total_size)"
    echo "  Duration       : ${duration}s"
    echo "────────────────────────────────────────"
    echo ""
    echo "Recent Backups:"
    if [ -f "$BACKUP_MANIFEST" ]; then
      tail -20 "$BACKUP_MANIFEST" | while IFS='|' read -r ts lbl src arc sz; do
        printf "  [%s] %-15s %s\n" "$ts" "$lbl" "$(basename "$arc")"
      done
    fi
    echo ""
    echo "Disk space in $BACKUP_DIR:"
    du -sh "${BACKUP_DIR}"/* 2>/dev/null | head -20 || echo "  (empty)"
    echo ""
    echo "Report saved: $report_file"
  } | tee "$report_file"
  
  log "Backup report saved: $report_file"
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  mkdir -p "$BACKUP_DIR" "$REPORT_DIR"
  
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║   BACKUP AUTOMATION — $(date '+%Y-%m-%d %H:%M')         ║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"
  
  $DRY_RUN     && warn "DRY-RUN MODE: no files will be written"
  $INCREMENTAL && log_inf "INCREMENTAL MODE: only changed files will be archived"
  $ENCRYPT     && log_inf "ENCRYPTION MODE: archives will be GPG-encrypted"
  
  check_deps
  
  local success=0 fail=0 total_bytes=0
  local start_ts=$SECONDS
  
  for target in "${BACKUP_TARGETS[@]}"; do
    label="${target%%:*}"
    source="${target#*:}"
    
    if result=$(do_backup "$label" "$source"); then
      (( success++ )) || true
      if [ -f "$result" ] 2>/dev/null; then
        sz=$(stat -c%s "$result" 2>/dev/null || echo 0)
        total_bytes=$(( total_bytes + sz ))
      fi
    else
      (( fail++ )) || true
    fi
  done
  
  local duration=$(( SECONDS - start_ts ))
  echo ""
  generate_report "$success" "$fail" "$total_bytes" "$duration"
  
  if [ "$fail" -gt 0 ]; then
    log_err "$fail backup(s) failed"
    exit 1
  else
    log_ok "All $success backup(s) completed successfully"
  fi
}

main "$@"
