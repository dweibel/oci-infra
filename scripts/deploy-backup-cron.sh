#!/usr/bin/env bash
set -euo pipefail

# Deploy backup cron jobs (Wiki.js + Hermes + Forge) to the OCI instance.
#
# Prerequisites:
#   1. OCI Customer Secret Key (S3-compatible credentials) — create via:
#      OCI Console → Identity → Users → <your user> → Customer Secret Keys → Generate
#   2. Terraform must have created the backup bucket (module.backup)
#
# Usage:
#   ./deploy-backup-cron.sh --remote oci-agent                    # deploy via SSH
#   ./deploy-backup-cron.sh --remote oci-agent --schedule "0 */6 * * *"  # every 6h
#   ./deploy-backup-cron.sh --remote oci-agent --remove           # remove cron job
#   ./deploy-backup-cron.sh                                       # run locally on instance
#
# Required environment variables:
#   OCI_S3_ACCESS_KEY    OCI Customer Secret Key — access key
#   OCI_S3_SECRET_KEY    OCI Customer Secret Key — secret
#   OCI_NAMESPACE        Object Storage namespace (oci os ns get)
#   OCI_REGION           OCI region (default: us-ashburn-1)
#   OCI_BACKUP_BUCKET    Bucket name (default: agent-coder-dev-backups)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST=""
SCHEDULE="0 8 * * *"
REMOVE=false
OCI_REGION="${OCI_REGION:-us-ashburn-1}"
OCI_BACKUP_BUCKET="${OCI_BACKUP_BUCKET:-agent-coder-dev-backups}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)   REMOTE_HOST="$2"; shift 2 ;;
    --schedule) SCHEDULE="$2"; shift 2 ;;
    --remove)   REMOVE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

WIKIJS_BACKUP_SCRIPT="/home/opc/scripts/backup-wikijs.sh"
HERMES_BACKUP_SCRIPT="/home/opc/scripts/backup-hermes.sh"
FORGE_BACKUP_SCRIPT="/home/opc/scripts/backup-forge.sh"
WIKIJS_CRON_TAG="# wikijs-backup"
HERMES_CRON_TAG="# hermes-backup"
FORGE_CRON_TAG="# forge-backup"
WIKIJS_LOG_FILE="/mnt/workspace/backups/wikijs/backup.log"
HERMES_LOG_FILE="/mnt/workspace/backups/hermes/backup.log"
FORGE_LOG_FILE="/mnt/workspace/backups/forge/backup.log"

install_local() {
  mkdir -p "$(dirname "$WIKIJS_BACKUP_SCRIPT")"
  mkdir -p "$(dirname "$WIKIJS_LOG_FILE")"
  mkdir -p "$(dirname "$HERMES_LOG_FILE")"
  mkdir -p "$(dirname "$FORGE_LOG_FILE")"

  # Copy Wiki.js backup script
  if [ -f "${SCRIPT_DIR}/backup-wikijs.sh" ]; then
    cp "${SCRIPT_DIR}/backup-wikijs.sh" "$WIKIJS_BACKUP_SCRIPT"
    chmod +x "$WIKIJS_BACKUP_SCRIPT"
    echo "Wiki.js backup script installed: $WIKIJS_BACKUP_SCRIPT"
  else
    echo "ERROR: backup-wikijs.sh not found in ${SCRIPT_DIR}"
    exit 1
  fi

  # Copy Hermes backup script
  if [ -f "${SCRIPT_DIR}/backup-hermes.sh" ]; then
    cp "${SCRIPT_DIR}/backup-hermes.sh" "$HERMES_BACKUP_SCRIPT"
    chmod +x "$HERMES_BACKUP_SCRIPT"
    echo "Hermes backup script installed: $HERMES_BACKUP_SCRIPT"
  else
    echo "ERROR: backup-hermes.sh not found in ${SCRIPT_DIR}"
    exit 1
  fi

  # Copy Forge backup script
  if [ -f "${SCRIPT_DIR}/backup-forge.sh" ]; then
    cp "${SCRIPT_DIR}/backup-forge.sh" "$FORGE_BACKUP_SCRIPT"
    chmod +x "$FORGE_BACKUP_SCRIPT"
    echo "Forge backup script installed: $FORGE_BACKUP_SCRIPT"
  else
    echo "ERROR: backup-forge.sh not found in ${SCRIPT_DIR}"
    exit 1
  fi

  # Configure AWS CLI 'oci' profile for S3-compatible access
  if [ -n "${OCI_S3_ACCESS_KEY:-}" ] && [ -n "${OCI_S3_SECRET_KEY:-}" ]; then
    local endpoint="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com"

    aws configure set aws_access_key_id "$OCI_S3_ACCESS_KEY" --profile oci
    aws configure set aws_secret_access_key "$OCI_S3_SECRET_KEY" --profile oci
    aws configure set region "$OCI_REGION" --profile oci
    aws configure set endpoint_url "$endpoint" --profile oci
    echo "AWS CLI 'oci' profile configured (endpoint: ${endpoint})"
  else
    echo "WARN: OCI_S3_ACCESS_KEY / OCI_S3_SECRET_KEY not set — skipping profile setup."
    echo "      Configure manually: aws configure --profile oci"
  fi

  if [ "$REMOVE" = true ]; then
    crontab -l 2>/dev/null | grep -v "$WIKIJS_CRON_TAG" | grep -v "$HERMES_CRON_TAG" | grep -v "$FORGE_CRON_TAG" | crontab -
    echo "Cron jobs removed."
    return
  fi

  # Install cron jobs (idempotent)
  local wikijs_env="WIKIJS_BACKUP_BUCKET=${OCI_BACKUP_BUCKET}"
  local wikijs_cron="${SCHEDULE} ${wikijs_env} ${WIKIJS_BACKUP_SCRIPT} >> ${WIKIJS_LOG_FILE} 2>&1 ${WIKIJS_CRON_TAG}"

  local hermes_env="HERMES_BACKUP_BUCKET=${OCI_BACKUP_BUCKET}"
  local hermes_cron="${SCHEDULE} ${hermes_env} ${HERMES_BACKUP_SCRIPT} >> ${HERMES_LOG_FILE} 2>&1 ${HERMES_CRON_TAG}"

  local forge_env="FORGE_BACKUP_BUCKET=${OCI_BACKUP_BUCKET}"
  local forge_cron="${SCHEDULE} ${forge_env} ${FORGE_BACKUP_SCRIPT} >> ${FORGE_LOG_FILE} 2>&1 ${FORGE_CRON_TAG}"

  (crontab -l 2>/dev/null | grep -v "$WIKIJS_CRON_TAG" | grep -v "$HERMES_CRON_TAG" | grep -v "$FORGE_CRON_TAG"; echo "$wikijs_cron"; echo "$hermes_cron"; echo "$forge_cron") | crontab -

  echo ""
  echo "Cron jobs installed:"
  echo "  Schedule: $SCHEDULE"
  echo "  Wiki.js:  $WIKIJS_BACKUP_SCRIPT → $WIKIJS_LOG_FILE"
  echo "  Hermes:   $HERMES_BACKUP_SCRIPT → $HERMES_LOG_FILE"
  echo "  Forge:    $FORGE_BACKUP_SCRIPT → $FORGE_LOG_FILE"
  echo "  Bucket:   $OCI_BACKUP_BUCKET"
  echo ""
  crontab -l
}

if [ -n "$REMOTE_HOST" ]; then
  echo "Deploying to ${REMOTE_HOST} via SSH..."

  # Validate required env vars for remote deploy
  if [ -z "${OCI_S3_ACCESS_KEY:-}" ] || [ -z "${OCI_S3_SECRET_KEY:-}" ] || [ -z "${OCI_NAMESPACE:-}" ]; then
    echo "ERROR: Remote deploy requires OCI_S3_ACCESS_KEY, OCI_S3_SECRET_KEY, and OCI_NAMESPACE"
    echo ""
    echo "Create a Customer Secret Key in OCI Console:"
    echo "  Identity → Users → <your user> → Customer Secret Keys → Generate"
    echo ""
    echo "Get your namespace:"
    echo "  oci os ns get"
    exit 1
  fi

  # Copy backup scripts to remote
  scp "${SCRIPT_DIR}/backup-wikijs.sh" "${REMOTE_HOST}:/tmp/backup-wikijs.sh"
  scp "${SCRIPT_DIR}/backup-hermes.sh" "${REMOTE_HOST}:/tmp/backup-hermes.sh"
  scp "${SCRIPT_DIR}/backup-forge.sh" "${REMOTE_HOST}:/tmp/backup-forge.sh"

  # Export env vars and run install on remote
  ssh "$REMOTE_HOST" "
    export OCI_S3_ACCESS_KEY='${OCI_S3_ACCESS_KEY}'
    export OCI_S3_SECRET_KEY='${OCI_S3_SECRET_KEY}'
    export OCI_NAMESPACE='${OCI_NAMESPACE}'
    export OCI_REGION='${OCI_REGION}'
    export OCI_BACKUP_BUCKET='${OCI_BACKUP_BUCKET}'
    export REMOVE='${REMOVE}'

    mkdir -p $(dirname "$WIKIJS_BACKUP_SCRIPT") $(dirname "$WIKIJS_LOG_FILE") $(dirname "$HERMES_LOG_FILE") $(dirname "$FORGE_LOG_FILE")

    cp /tmp/backup-wikijs.sh ${WIKIJS_BACKUP_SCRIPT}
    chmod +x ${WIKIJS_BACKUP_SCRIPT}
    rm /tmp/backup-wikijs.sh
    echo 'Wiki.js backup script installed: ${WIKIJS_BACKUP_SCRIPT}'

    cp /tmp/backup-hermes.sh ${HERMES_BACKUP_SCRIPT}
    chmod +x ${HERMES_BACKUP_SCRIPT}
    rm /tmp/backup-hermes.sh
    echo 'Hermes backup script installed: ${HERMES_BACKUP_SCRIPT}'

    cp /tmp/backup-forge.sh ${FORGE_BACKUP_SCRIPT}
    chmod +x ${FORGE_BACKUP_SCRIPT}
    rm /tmp/backup-forge.sh
    echo 'Forge backup script installed: ${FORGE_BACKUP_SCRIPT}'

    # Configure AWS CLI oci profile
    ENDPOINT=\"https://\${OCI_NAMESPACE}.compat.objectstorage.\${OCI_REGION}.oraclecloud.com\"
    aws configure set aws_access_key_id \"\${OCI_S3_ACCESS_KEY}\" --profile oci
    aws configure set aws_secret_access_key \"\${OCI_S3_SECRET_KEY}\" --profile oci
    aws configure set region \"\${OCI_REGION}\" --profile oci
    aws configure set endpoint_url \"\${ENDPOINT}\" --profile oci
    echo \"AWS CLI 'oci' profile configured (endpoint: \${ENDPOINT})\"

    if [ \"\${REMOVE}\" = 'true' ]; then
      crontab -l 2>/dev/null | grep -v '${WIKIJS_CRON_TAG}' | grep -v '${HERMES_CRON_TAG}' | grep -v '${FORGE_CRON_TAG}' | crontab -
      echo 'Cron jobs removed.'
    else
      WIKIJS_CRON='${SCHEDULE} WIKIJS_BACKUP_BUCKET=${OCI_BACKUP_BUCKET} ${WIKIJS_BACKUP_SCRIPT} >> ${WIKIJS_LOG_FILE} 2>&1 ${WIKIJS_CRON_TAG}'
      HERMES_CRON='${SCHEDULE} HERMES_BACKUP_BUCKET=${OCI_BACKUP_BUCKET} ${HERMES_BACKUP_SCRIPT} >> ${HERMES_LOG_FILE} 2>&1 ${HERMES_CRON_TAG}'
      FORGE_CRON='${SCHEDULE} FORGE_BACKUP_BUCKET=${OCI_BACKUP_BUCKET} ${FORGE_BACKUP_SCRIPT} >> ${FORGE_LOG_FILE} 2>&1 ${FORGE_CRON_TAG}'
      (crontab -l 2>/dev/null | grep -v '${WIKIJS_CRON_TAG}' | grep -v '${HERMES_CRON_TAG}' | grep -v '${FORGE_CRON_TAG}'; echo \"\${WIKIJS_CRON}\"; echo \"\${HERMES_CRON}\"; echo \"\${FORGE_CRON}\") | crontab -
      echo ''
      echo 'Cron jobs installed: ${SCHEDULE}'
      echo 'Bucket: ${OCI_BACKUP_BUCKET}'
      echo ''
      crontab -l
    fi
  "
else
  install_local
fi
