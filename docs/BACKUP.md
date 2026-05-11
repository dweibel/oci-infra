# Backup and Restore

## Overview

Wiki.js and Hermes data are backed up daily to OCI Object Storage via the S3-compatible API. Wiki.js backups include the PostgreSQL database and assets volume. Hermes backups include the data directory and config files. Local copies are staged on the block volume.

All persistent data lives on the 50 GB block volume (`/mnt/workspace`), which survives boot volume re-images and instance terminations.

## What Gets Backed Up

| Data | Source | Backup format | Typical size |
|---|---|---|---|
| PostgreSQL database | `wikijs-postgres` container | `pg_dump` gzipped SQL | ~10 KB (fresh), grows with content |
| Wiki.js assets | `/mnt/workspace/wikijs/assets/` | tar.gz archive | Depends on uploads |
| Hermes data | `/mnt/workspace/hermes/` (entire dir, excl. `.env`) | tar.gz archive | Sessions, config, agent state |

## Storage

| Location | Retention | Purpose |
|---|---|---|
| OCI Object Storage (`agent-coder-dev-backups`) | 30 days (lifecycle policy) | Primary offsite backup |
| Block volume (`/mnt/workspace/backups/wikijs/`) | 7 days (local prune) | Fast local restore (Wiki.js) |
| Block volume (`/mnt/workspace/backups/hermes/`) | 7 days (local prune) | Fast local restore (Hermes) |

## Schedule

Daily at 08:00 UTC (3:00 AM EST) via cron on the `opc` user.

Verify the cron is installed:

```bash
ssh oci-agent "crontab -l"
# Expected:
# 0 8 * * * WIKIJS_BACKUP_BUCKET=agent-coder-dev-backups /home/opc/scripts/backup-wikijs.sh >> /mnt/workspace/backups/wikijs/backup.log 2>&1 # wikijs-backup
# 0 8 * * * HERMES_BACKUP_BUCKET=agent-coder-dev-backups /home/opc/scripts/backup-hermes.sh >> /mnt/workspace/backups/hermes/backup.log 2>&1 # hermes-backup
```

## Scripts

### backup-wikijs.sh

Located at `/home/opc/scripts/backup-wikijs.sh` on the instance and `scripts/backup-wikijs.sh` in the repo.

```bash
# Full backup (database + assets) to OCI Object Storage
/home/opc/scripts/backup-wikijs.sh

# Database only
/home/opc/scripts/backup-wikijs.sh --db-only

# Assets only
/home/opc/scripts/backup-wikijs.sh --assets-only

# Local backup only (no OCI upload, no credentials needed)
/home/opc/scripts/backup-wikijs.sh --target local

# List all backups (local + OCI)
/home/opc/scripts/backup-wikijs.sh --list

# Restore database from a local file
/home/opc/scripts/backup-wikijs.sh --restore-db /mnt/workspace/backups/wikijs/wikijs-db-YYYYMMDD-HHMMSS.sql.gz

# Restore database from OCI Object Storage
/home/opc/scripts/backup-wikijs.sh --restore-db s3://agent-coder-dev-backups/wikijs/db/wikijs-db-YYYYMMDD-HHMMSS.sql.gz
```

### backup-hermes.sh

Located at `/home/opc/scripts/backup-hermes.sh` on the instance and `scripts/backup-hermes.sh` in the repo.

Backs up the entire `/mnt/workspace/hermes/` directory (the container's `$HOME`/`/opt/data` bind mount), excluding `.env`. This captures `data/`, `config.yaml`, `auth.json`, `.hermes/`, and any other state the container writes.

```bash
# Full backup to OCI Object Storage
/home/opc/scripts/backup-hermes.sh

# Local backup only (no OCI upload, no credentials needed)
/home/opc/scripts/backup-hermes.sh --target local

# List all backups (local + OCI)
/home/opc/scripts/backup-hermes.sh --list
```

### deploy-backup-cron.sh

Installs both backup scripts and cron jobs on the instance. Configures the AWS CLI `oci` profile for S3-compatible access.

```bash
source .env
./scripts/deploy-backup-cron.sh --remote oci-agent

# Custom schedule
./scripts/deploy-backup-cron.sh --remote oci-agent --schedule "0 */6 * * *"

# Remove the cron jobs
./scripts/deploy-backup-cron.sh --remote oci-agent --remove
```

## OCI Object Storage Configuration

Backups use the S3-compatible API with an AWS CLI profile named `oci`.

| Setting | Value |
|---|---|
| Bucket | `agent-coder-dev-backups` |
| Namespace | `idxfevuczdaz` |
| Endpoint | `https://idxfevuczdaz.compat.objectstorage.us-ashburn-1.oraclecloud.com` |
| Auth | OCI Customer Secret Key (stored in AWS CLI `oci` profile) |
| Lifecycle | Auto-delete objects under `wikijs/` and `hermes/` after 30 days |

The bucket and IAM policy are managed by Terraform (`module.backup`).

## Manual Backup

Run before any infrastructure change (Terraform apply, OS update, etc.):

```bash
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh"
ssh oci-agent "/home/opc/scripts/backup-hermes.sh"
```

## Restore Procedures

### Wiki.js — Restore database from OCI Object Storage

```bash
# List available backups
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh --list"

# Restore (interactive — prompts for confirmation)
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh --restore-db s3://agent-coder-dev-backups/wikijs/db/wikijs-db-YYYYMMDD-HHMMSS.sql.gz"
```

### Wiki.js — Restore database from local backup

```bash
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh --restore-db /mnt/workspace/backups/wikijs/wikijs-db-YYYYMMDD-HHMMSS.sql.gz"
```

### Wiki.js — Restore assets

Assets are backed up as tar.gz archives. To restore:

```bash
# Download from OCI
ssh oci-agent "export AWS_REQUEST_CHECKSUM_CALCULATION=when_required && export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required && aws s3 cp s3://agent-coder-dev-backups/wikijs/assets/wikijs-assets-YYYYMMDD-HHMMSS.tar.gz /tmp/ --profile oci --endpoint-url https://idxfevuczdaz.compat.objectstorage.us-ashburn-1.oraclecloud.com"

# Extract to the assets volume
ssh oci-agent "tar -xzf /tmp/wikijs-assets-YYYYMMDD-HHMMSS.tar.gz -C /mnt/workspace/wikijs/assets/"
```

### Hermes — Restore

```bash
# List available backups
ssh oci-agent "/home/opc/scripts/backup-hermes.sh --list"

# Download from OCI
ssh oci-agent "export AWS_REQUEST_CHECKSUM_CALCULATION=when_required && export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required && aws s3 cp s3://agent-coder-dev-backups/hermes/data/hermes-data-YYYYMMDD-HHMMSS.tar.gz /tmp/ --profile oci --endpoint-url https://idxfevuczdaz.compat.objectstorage.us-ashburn-1.oraclecloud.com"

# Stop Hermes container before restoring
ssh oci-agent "podman stop hermes-agent"

# Extract (restores entire hermes/ directory)
ssh oci-agent "tar -xzf /tmp/hermes-data-YYYYMMDD-HHMMSS.tar.gz -C /mnt/workspace/"

# Recreate .env from hermes-infra/config/.env.example (not included in backup)
# Then restart Hermes
ssh oci-agent "podman start hermes-agent"
```

### Full recovery after instance re-image

See [dataloss-mitigation.md](dataloss-mitigation.md) section 7 for the complete recovery checklist.

## Monitoring

Check the backup logs:

```bash
ssh oci-agent "tail -20 /mnt/workspace/backups/wikijs/backup.log"
ssh oci-agent "tail -20 /mnt/workspace/backups/hermes/backup.log"
```

Verify the latest backups exist in OCI:

```bash
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh --list"
ssh oci-agent "/home/opc/scripts/backup-hermes.sh --list"
```

## Troubleshooting

### Cron not running

```bash
# Check cron is installed
ssh oci-agent "crontab -l"

# Check cron daemon is running
ssh oci-agent "systemctl status crond"

# Run manually to test
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh"
```

### Upload fails with SignatureDoesNotMatch

The AWS CLI `oci` profile may be misconfigured. Verify:

```bash
ssh oci-agent "aws configure get aws_access_key_id --profile oci"
ssh oci-agent "aws configure get aws_secret_access_key --profile oci"
```

Reconfigure if needed using the Customer Secret Key from `oci-infra/.env`:

```bash
source .env
ssh oci-agent "aws configure set aws_access_key_id '${OCI_S3_ACCESS_KEY}' --profile oci"
ssh oci-agent "aws configure set aws_secret_access_key '${OCI_S3_SECRET_KEY}' --profile oci"
ssh oci-agent "aws configure set region '${OCI_REGION}' --profile oci"
```

### PostgreSQL container not running

The backup script will fail with "PostgreSQL container 'wikijs-postgres' is not ready". Check:

```bash
ssh oci-agent "podman ps -a --filter name=wikijs-postgres"
ssh oci-agent "podman logs wikijs-postgres --tail 20"
```
