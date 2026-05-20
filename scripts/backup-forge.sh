#!/usr/bin/env bash
set -euo pipefail

# Forge Backup Script — OCI Object Storage (S3-compatible API)
#
# Backs up the entire /mnt/workspace/forge/ directory (excluding .env).
# This captures:
#   - data/ (execution logs, state)
#   - workspaces/ (cloned repositories)
#   - Any other files written to the forge directory
#
# Note: .env is NOT backed up (contains secrets). Restore it manually from
# the template in oci-infra/config/forge.env.example.
#
# Uses the AWS CLI with a dedicated OCI profile to talk to OCI Object Storage
# via its S3-compatible endpoint. No OCI CLI required.
#
# Usage:
#   ./backup-forge.sh                     # full backup to OCI
#   ./backup-forge.sh --target local      # local backup only (no upload)
#   ./backup-forge.sh --list              # list existing backups
#
# Environment variables (override defaults):
#   FORGE_BACKUP_BUCKET        OCI bucket name
#   FORGE_BACKUP_ENDPOINT      S3-compatible endpoint URL
#   FORGE_BACKUP_PROFILE       AWS CLI profile name (default: oci)
#   FORGE_BACKUP_RETENTION     Days to keep local backups (default: 7)

# ─── Configuration ────────────────────────────────────────────────────────────
FORGE_DIR="/mnt/workspace/forge"

BACKUP_DIR="/mnt/workspace/backups/forge"
BUCKET="${FORGE_BACKUP_BUCKET:-agent-coder-dev-backups}"
ENDPOINT="${FORGE_BACKUP_ENDPOINT:-https://idxfevuczdaz.compat.objectstorage.us-ashburn-1.oraclecloud.com}"
AWS_PROFILE="${FORGE_BACKUP_PROFILE:-oci}"
LOCAL_RETENTION_DAYS="${FORGE_BACKUP_RETENTION:-7}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATA_FILE="forge-data-${TIMESTAMP}.tar.gz"

# S3 compat workaround for newer AWS CLI versions
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

# Colors (disabled in cron / non-interactive)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; NC=''
fi

log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"; }

# Build the endpoint arg for aws s3 commands
s3_args() {
  echo "--profile ${AWS_PROFILE} --endpoint-url ${ENDPOINT}"
}

# ─── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  if ! aws configure get aws_access_key_id --profile "$AWS_PROFILE" &>/dev/null; then
    log "ERROR" "${RED}AWS CLI profile '${AWS_PROFILE}' not configured.${NC}"
    log "ERROR" "Create it with your OCI Customer Secret Key:"
    log "ERROR" "  aws configure --profile oci"
    log "ERROR" "  Access Key: <OCI Customer Secret Key access key>"
    log "ERROR" "  Secret Key: <OCI Customer Secret Key secret>"
    log "ERROR" "  Region:     us-ashburn-1"
    exit 1
  fi
}

# ─── Data backup ─────────────────────────────────────────────────────────────
backup_data() {
  mkdir -p "$BACKUP_DIR"

  if [ ! -d "$FORGE_DIR" ]; then
    log "WARN" "${YELLOW}Forge directory '${FORGE_DIR}' not found, skipping data backup.${NC}"
    return
  fi

  # Check if there's anything worth backing up
  local file_count
  file_count=$(find "$FORGE_DIR" -type f 2>/dev/null | wc -l)
  if [ "$file_count" -eq 0 ]; then
    log "WARN" "${YELLOW}Forge directory is empty, skipping.${NC}"
    return
  fi

  log "INFO" "Archiving Forge data directory (${file_count} files)..."
  # Back up everything in /mnt/workspace/forge EXCEPT .env (contains secrets).
  # This covers: data/, workspaces/, and any other state.
  tar -czf "${BACKUP_DIR}/${DATA_FILE}" \
    --exclude='.env' \
    -C "$(dirname "$FORGE_DIR")" "$(basename "$FORGE_DIR")"

  local size
  size=$(du -h "${BACKUP_DIR}/${DATA_FILE}" | cut -f1)
  log "INFO" "${GREEN}Data backup: ${DATA_FILE} (${size})${NC}"

  if [ "$TARGET" != "local" ]; then
    log "INFO" "Uploading to s3://${BUCKET}/forge/data/${DATA_FILE}..."
    # shellcheck disable=SC2046
    if ! aws s3 cp "${BACKUP_DIR}/${DATA_FILE}" \
      "s3://${BUCKET}/forge/data/${DATA_FILE}" \
      $(s3_args) --quiet; then
      log "ERROR" "${RED}Upload failed. Local archive preserved at ${BACKUP_DIR}/${DATA_FILE}${NC}"
      exit 1
    fi
    log "INFO" "${GREEN}Data upload complete.${NC}"
  fi
}

# ─── Prune local backups ─────────────────────────────────────────────────────
prune_local() {
  local count
  count=$(find "$BACKUP_DIR" -name "forge-*.gz" -mtime +"$LOCAL_RETENTION_DAYS" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    log "INFO" "Pruning ${count} local backup(s) older than ${LOCAL_RETENTION_DAYS} days..."
    find "$BACKUP_DIR" -name "forge-*.gz" -mtime +"$LOCAL_RETENTION_DAYS" -delete
  fi
}

# ─── List backups ─────────────────────────────────────────────────────────────
list_backups() {
  preflight
  echo "=== Local backups ==="
  if [ -d "$BACKUP_DIR" ]; then
    ls -lh "$BACKUP_DIR"/forge-*.gz 2>/dev/null || echo "  (none)"
  else
    echo "  (none)"
  fi
  echo ""
  echo "=== OCI Object Storage backups ==="
  # shellcheck disable=SC2046
  aws s3 ls "s3://${BUCKET}/forge/data/" $(s3_args) 2>/dev/null || echo "  (none)"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
TARGET="oci"

case "${1:-}" in
  --list)
    list_backups
    exit 0
    ;;
  --target)
    TARGET="${2:-oci}"
    shift 2 || true
    ;;
  --help)
    echo "Usage: $0 [--target oci|local|--list]"
    exit 0
    ;;
esac

# Only require OCI credentials for non-local targets
if [ "$TARGET" != "local" ]; then
  preflight
fi

backup_data
prune_local

log "INFO" "${GREEN}Backup complete.${NC}"
