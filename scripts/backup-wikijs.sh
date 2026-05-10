#!/usr/bin/env bash
set -euo pipefail

# Wiki.js Backup Script — OCI Object Storage (S3-compatible API)
#
# Backs up:
#   1. PostgreSQL database (pg_dump, gzipped)
#   2. Wiki.js assets volume (uploads, content — tar.gz)
#
# Uses the AWS CLI with a dedicated OCI profile to talk to OCI Object Storage
# via its S3-compatible endpoint. No OCI CLI required.
#
# Usage:
#   ./backup-wikijs.sh                     # full backup (db + assets)
#   ./backup-wikijs.sh --db-only           # database only
#   ./backup-wikijs.sh --assets-only       # assets volume only
#   ./backup-wikijs.sh --list              # list existing backups
#   ./backup-wikijs.sh --restore-db <file> # restore database from backup
#
# Environment variables (override defaults):
#   WIKIJS_BACKUP_BUCKET        OCI bucket name
#   WIKIJS_BACKUP_ENDPOINT      S3-compatible endpoint URL
#   WIKIJS_BACKUP_PROFILE       AWS CLI profile name (default: oci)
#   WIKIJS_BACKUP_RETENTION     Days to keep local backups (default: 7)

# ─── Configuration ────────────────────────────────────────────────────────────
PG_CONTAINER="wikijs-postgres"
PG_USER="wiki"
PG_DB="wiki"
ASSETS_VOLUME="/mnt/workspace/wikijs/assets"

BACKUP_DIR="/mnt/workspace/backups/wikijs"
BUCKET="${WIKIJS_BACKUP_BUCKET:-agent-coder-dev-backups}"
ENDPOINT="${WIKIJS_BACKUP_ENDPOINT:-https://idxfevuczdaz.compat.objectstorage.us-ashburn-1.oraclecloud.com}"
AWS_PROFILE="${WIKIJS_BACKUP_PROFILE:-oci}"
LOCAL_RETENTION_DAYS="${WIKIJS_BACKUP_RETENTION:-7}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DB_FILE="wikijs-db-${TIMESTAMP}.sql.gz"
ASSETS_FILE="wikijs-assets-${TIMESTAMP}.tar.gz"

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
# Always pass --endpoint-url explicitly (aws s3 high-level commands
# don't reliably read endpoint_url from the config file in CLI 2.34+)
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

check_postgres() {
  if ! podman exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    log "ERROR" "${RED}PostgreSQL container '$PG_CONTAINER' is not ready${NC}"
    exit 1
  fi
}

# ─── Database backup ─────────────────────────────────────────────────────────
backup_db() {
  check_postgres
  mkdir -p "$BACKUP_DIR"

  log "INFO" "Dumping database '${PG_DB}'..."
  podman exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists \
    | gzip > "${BACKUP_DIR}/${DB_FILE}"

  local size
  size=$(du -h "${BACKUP_DIR}/${DB_FILE}" | cut -f1)
  log "INFO" "${GREEN}Database backup: ${DB_FILE} (${size})${NC}"

  if [ "$TARGET" != "local" ]; then
    log "INFO" "Uploading to s3://${BUCKET}/wikijs/db/${DB_FILE}..."
    # shellcheck disable=SC2046
    aws s3 cp "${BACKUP_DIR}/${DB_FILE}" \
      "s3://${BUCKET}/wikijs/db/${DB_FILE}" \
      $(s3_args) --quiet
    log "INFO" "${GREEN}Database upload complete.${NC}"
  fi
}

# ─── Assets backup ───────────────────────────────────────────────────────────
backup_assets() {
  mkdir -p "$BACKUP_DIR"

  local vol_path
  vol_path=$(podman volume inspect "$ASSETS_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || true)

  # Fall back to bind mount path if named volume doesn't exist
  if [ -z "$vol_path" ] && [ -d "$ASSETS_VOLUME" ]; then
    vol_path="$ASSETS_VOLUME"
  fi

  if [ -z "$vol_path" ]; then
    log "WARN" "${YELLOW}Assets volume/path '${ASSETS_VOLUME}' not found, skipping assets backup.${NC}"
    return
  fi

  # Check if there's anything worth backing up (skip if only empty dirs)
  local file_count
  file_count=$(find "$vol_path" -type f 2>/dev/null | wc -l)
  if [ "$file_count" -eq 0 ]; then
    log "INFO" "Assets volume is empty, skipping."
    return
  fi

  log "INFO" "Archiving assets volume (${file_count} files)..."
  tar -czf "${BACKUP_DIR}/${ASSETS_FILE}" -C "$vol_path" .

  local size
  size=$(du -h "${BACKUP_DIR}/${ASSETS_FILE}" | cut -f1)
  log "INFO" "${GREEN}Assets backup: ${ASSETS_FILE} (${size})${NC}"

  if [ "$TARGET" != "local" ]; then
    log "INFO" "Uploading to s3://${BUCKET}/wikijs/assets/${ASSETS_FILE}..."
    # shellcheck disable=SC2046
    aws s3 cp "${BACKUP_DIR}/${ASSETS_FILE}" \
      "s3://${BUCKET}/wikijs/assets/${ASSETS_FILE}" \
      $(s3_args) --quiet
    log "INFO" "${GREEN}Assets upload complete.${NC}"
  fi
}

# ─── Prune local backups ─────────────────────────────────────────────────────
prune_local() {
  local count
  count=$(find "$BACKUP_DIR" -name "wikijs-*.gz" -mtime +"$LOCAL_RETENTION_DAYS" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    log "INFO" "Pruning ${count} local backup(s) older than ${LOCAL_RETENTION_DAYS} days..."
    find "$BACKUP_DIR" -name "wikijs-*.gz" -mtime +"$LOCAL_RETENTION_DAYS" -delete
  fi
}

# ─── List backups ─────────────────────────────────────────────────────────────
list_backups() {
  preflight
  echo "=== Local backups ==="
  if [ -d "$BACKUP_DIR" ]; then
    ls -lh "$BACKUP_DIR"/wikijs-*.gz 2>/dev/null || echo "  (none)"
  else
    echo "  (none)"
  fi
  echo ""
  echo "=== OCI Object Storage backups (db) ==="
  # shellcheck disable=SC2046
  aws s3 ls "s3://${BUCKET}/wikijs/db/" $(s3_args) 2>/dev/null || echo "  (none)"
  echo ""
  echo "=== OCI Object Storage backups (assets) ==="
  # shellcheck disable=SC2046
  aws s3 ls "s3://${BUCKET}/wikijs/assets/" $(s3_args) 2>/dev/null || echo "  (none)"
}

# ─── Restore database ────────────────────────────────────────────────────────
restore_db() {
  local file="$1"
  preflight
  check_postgres

  # Download from OCI if it looks like an S3 path
  if [[ "$file" == s3://* ]]; then
    local local_file="${BACKUP_DIR}/$(basename "$file")"
    mkdir -p "$BACKUP_DIR"
    log "INFO" "Downloading ${file}..."
    # shellcheck disable=SC2046
    aws s3 cp "$file" "$local_file" $(s3_args)
    file="$local_file"
  fi

  if [ ! -f "$file" ]; then
    log "ERROR" "${RED}File not found: $file${NC}"
    exit 1
  fi

  log "INFO" "${YELLOW}Restoring from: $file${NC}"
  log "INFO" "${YELLOW}This will overwrite the current database!${NC}"
  if [ -t 0 ]; then
    read -rp "Continue? [y/N] " confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Aborted."; exit 0; }
  fi

  gunzip -c "$file" | podman exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" --quiet
  log "INFO" "${GREEN}Restore complete.${NC}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
DO_DB=true
DO_ASSETS=true
TARGET="oci"

case "${1:-}" in
  --list)
    list_backups
    exit 0
    ;;
  --restore-db)
    [ -n "${2:-}" ] || { log "ERROR" "Usage: $0 --restore-db <file|s3://...>"; exit 1; }
    restore_db "$2"
    exit 0
    ;;
  --db-only)
    DO_ASSETS=false
    ;;
  --assets-only)
    DO_DB=false
    ;;
  --target)
    TARGET="${2:-oci}"
    shift 2 || true
    ;;
  --help)
    echo "Usage: $0 [--db-only|--assets-only|--target oci|local|--list|--restore-db <file>]"
    exit 0
    ;;
esac

# Only require OCI credentials for non-local targets
if [ "$TARGET" != "local" ]; then
  preflight
fi

[ "$DO_DB" = true ] && backup_db
[ "$DO_ASSETS" = true ] && backup_assets
prune_local

log "INFO" "${GREEN}Backup complete.${NC}"
