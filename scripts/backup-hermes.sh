#!/usr/bin/env bash
set -euo pipefail

# Hermes Agent Backup Script — OCI Object Storage (S3-compatible API)
#
# Backs up the entire /mnt/workspace/hermes/ directory (excluding .env).
# This is the container's $HOME (/opt/data) via the bind mount, so it captures:
#   - data/ (sessions, agent state)
#   - config.yaml
#   - auth.json
#   - .hermes/ (gateway state)
#   - Any other files the container writes to $HOME or /opt/data
#
# Note: .env is NOT backed up (contains secrets). Restore it manually from
# the template in hermes-infra/config/.env.example.
#
# Uses the AWS CLI with a dedicated OCI profile to talk to OCI Object Storage
# via its S3-compatible endpoint. No OCI CLI required.
#
# Usage:
#   ./backup-hermes.sh                     # full backup to OCI
#   ./backup-hermes.sh --target local      # local backup only (no upload)
#   ./backup-hermes.sh --list              # list existing backups
#
# Environment variables (override defaults):
#   HERMES_BACKUP_BUCKET        OCI bucket name
#   HERMES_BACKUP_ENDPOINT      S3-compatible endpoint URL
#   HERMES_BACKUP_PROFILE       AWS CLI profile name (default: oci)
#   HERMES_BACKUP_RETENTION     Days to keep local backups (default: 7)

# ─── Configuration ────────────────────────────────────────────────────────────
HERMES_DIR="/mnt/workspace/hermes"

BACKUP_DIR="/mnt/workspace/backups/hermes"
BUCKET="${HERMES_BACKUP_BUCKET:-agent-coder-dev-backups}"
ENDPOINT="${HERMES_BACKUP_ENDPOINT:-https://idxfevuczdaz.compat.objectstorage.us-ashburn-1.oraclecloud.com}"
AWS_PROFILE="${HERMES_BACKUP_PROFILE:-oci}"
LOCAL_RETENTION_DAYS="${HERMES_BACKUP_RETENTION:-7}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATA_FILE="hermes-data-${TIMESTAMP}.tar.gz"

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

  if [ ! -d "$HERMES_DIR" ]; then
    log "WARN" "${YELLOW}Hermes directory '${HERMES_DIR}' not found, skipping data backup.${NC}"
    return
  fi

  # Check if there's anything worth backing up
  local file_count
  file_count=$(find "$HERMES_DIR" -type f 2>/dev/null | wc -l)
  if [ "$file_count" -eq 0 ]; then
    log "INFO" "Hermes directory is empty, skipping."
    return
  fi

  log "INFO" "Archiving Hermes data directory (${file_count} files)..."
  # Back up everything in /mnt/workspace/hermes EXCEPT .env (contains secrets).
  # This covers: data/, config.yaml, auth.json, .hermes/, sessions, and any
  # other state the container writes to $HOME (/opt/data → /mnt/workspace/hermes).
  tar -czf "${BACKUP_DIR}/${DATA_FILE}" \
    --exclude='.env' \
    -C "$(dirname "$HERMES_DIR")" "$(basename "$HERMES_DIR")"

  local size
  size=$(du -h "${BACKUP_DIR}/${DATA_FILE}" | cut -f1)
  log "INFO" "${GREEN}Data backup: ${DATA_FILE} (${size})${NC}"

  if [ "$TARGET" != "local" ]; then
    log "INFO" "Uploading to s3://${BUCKET}/hermes/data/${DATA_FILE}..."
    # shellcheck disable=SC2046
    aws s3 cp "${BACKUP_DIR}/${DATA_FILE}" \
      "s3://${BUCKET}/hermes/data/${DATA_FILE}" \
      $(s3_args) --quiet
    log "INFO" "${GREEN}Data upload complete.${NC}"
  fi
}

# ─── Prune local backups ─────────────────────────────────────────────────────
prune_local() {
  local count
  count=$(find "$BACKUP_DIR" -name "hermes-*.gz" -mtime +"$LOCAL_RETENTION_DAYS" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    log "INFO" "Pruning ${count} local backup(s) older than ${LOCAL_RETENTION_DAYS} days..."
    find "$BACKUP_DIR" -name "hermes-*.gz" -mtime +"$LOCAL_RETENTION_DAYS" -delete
  fi
}

# ─── List backups ─────────────────────────────────────────────────────────────
list_backups() {
  preflight
  echo "=== Local backups ==="
  if [ -d "$BACKUP_DIR" ]; then
    ls -lh "$BACKUP_DIR"/hermes-*.gz 2>/dev/null || echo "  (none)"
  else
    echo "  (none)"
  fi
  echo ""
  echo "=== OCI Object Storage backups ==="
  # shellcheck disable=SC2046
  aws s3 ls "s3://${BUCKET}/hermes/data/" $(s3_args) 2>/dev/null || echo "  (none)"
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
