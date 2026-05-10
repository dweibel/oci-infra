# Data Loss Mitigation

Actions to prevent data loss on the OCI Always Free instance, informed by the April 17, 2026 incident where a Terraform apply re-imaged the boot volume and destroyed all container data. The wiki database was not recoverable — all content must be recreated.

## 1. Stateful Data on Block Volume (done)

The 50 GB block volume (`/dev/sdb`, mounted at `/mnt/workspace`) survives boot volume re-images, instance stops, and instance terminations. All persistent container data uses bind mounts to this volume.

### Directory layout

```
/mnt/workspace/
├── wikijs/
│   ├── pgdata/          # PostgreSQL data directory (bind mount)
│   └── assets/          # Wiki.js uploads, content, cache (bind mount)
├── backups/
│   └── wikijs/          # Local backup staging + logs
└── containers/
    └── config/          # Persistent container config
```

### Bind mounts in deploy-wikijs.sh

```bash
podman run -d ... -v /mnt/workspace/wikijs/pgdata:/var/lib/postgresql/data:Z ...
podman run -d ... -v /mnt/workspace/wikijs/assets:/wiki/data:Z ...
```

The `:Z` suffix relabels the mount for SELinux (Oracle Linux enforcing mode).

### Block volume setup

Run `oci-infra/scripts/setup-block-volume.sh` on the instance (or via SSH). This script:
- Formats `/dev/sdb` as ext4 if not already formatted
- Mounts at `/mnt/workspace` and adds to `/etc/fstab`
- Creates the directory structure and sets ownership to `opc`

### Survival matrix

| Scenario | Boot volume | Block volume |
|---|---|---|
| Terraform re-images instance | Data lost | Data survives |
| Instance terminated (reclaimed) | Data lost | Data survives |
| Instance stopped and restarted | Data survives | Data survives |
| OS upgrade / cloud-init re-run | Data lost | Data survives |

## 2. Automated Backups to OCI Object Storage

Backups target OCI Object Storage via the S3-compatible API. The bucket (`agent-coder-dev-backups`) and IAM policy are managed by Terraform module `oci-backup`. The backup script uses the AWS CLI with a dedicated `oci` profile — no OCI CLI required.

### Schedule

Daily at 08:00 UTC (3:00 AM EST) via cron.

| What | Retention | Storage |
|---|---|---|
| PostgreSQL pg_dump (gzipped) | 30 days (lifecycle policy) | OCI Object Storage |
| Wiki.js assets tar.gz | 30 days (lifecycle policy) | OCI Object Storage |
| Local backup copy | 7 days (local prune) | Block volume |

### Deploy the cron job

```bash
source .env
./scripts/deploy-backup-cron.sh --remote oci-agent
```

### Manual backup before any infrastructure change

```bash
ssh oci-agent '/home/opc/scripts/backup-wikijs.sh'
```

### Local-only backup (no OCI credentials needed)

```bash
ssh oci-agent '/home/opc/scripts/backup-wikijs.sh --target local'
```

## 3. Terraform Safety Guards

### 3.1 Ignore source_details on compute instances (done)

```hcl
lifecycle {
  ignore_changes = [metadata, source_details, defined_tags, create_vnic_details[0].defined_tags]
}
```

### 3.2 Pin the image ID (to implement)

Replace the dynamic image lookup with a fixed OCID in `terraform.tfvars`. Only update when intentionally upgrading the OS.

```hcl
# variables.tf
variable "image_id" {
  description = "Fixed OCID of the Oracle Linux ARM64 image. Update deliberately."
  type        = string
  default     = ""
}

# oci-compute/main.tf
source_id = var.image_id != "" ? var.image_id : data.oci_core_images.oracle_linux_arm.images[0].id
```

### 3.3 Add prevent_destroy (to implement)

```hcl
resource "oci_core_instance" "main" {
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata, source_details, ...]
  }
}

resource "oci_core_volume" "workspace" {
  lifecycle {
    prevent_destroy = true
  }
}
```

### 3.4 Always plan before apply

```bash
terraform plan -out=plan.tfplan
# READ THE PLAN — look for any unexpected changes
terraform apply plan.tfplan
```

Never use `terraform apply -auto-approve` on infrastructure with stateful resources.

## 4. Block Volume Backup (OCI Native)

OCI provides free block volume backups (up to 5 in the Always Free tier). Use before major changes as a second layer of protection.

```bash
oci bv backup create \
  --volume-id <workspace-volume-ocid> \
  --display-name "wikijs-pre-change-$(date +%Y%m%d)" \
  --type INCREMENTAL
```

## 5. AWS Credentials Management

AWS credentials (for ECR, S3, Bedrock) are stored in `oci-infra/.env` and deployed to the instance. They survive container restarts but not boot volume re-images.

```bash
source .env
ssh oci-agent "aws configure set aws_access_key_id '${AWS_ACCESS_KEY_ID}'"
ssh oci-agent "aws configure set aws_secret_access_key '${AWS_SECRET_ACCESS_KEY}'"
ssh oci-agent "aws configure set region '${AWS_REGION}'"
```

## 6. Environment Variable Split

| Repository | .env contains | Used by |
|---|---|---|
| `oci-infra` | Instance IP, SSH config, OCI Object Storage credentials, AWS credentials | Backup scripts, infrastructure management |
| `wikijs-infra` | Wiki.js admin credentials, OpenRouter API key, API gateway keys, database password | deploy-wikijs.sh, wiki-api-gateway |

## 7. Deployment Process

### Fresh instance (after re-image or reclaim)

```bash
# 1. Re-run cloud-init if errored
ssh oci-agent 'sudo cloud-init clean && sudo cloud-init init && sudo cloud-init modules --mode=config && sudo cloud-init modules --mode=final'

# 2. Install podman if cloud-init failed to
ssh oci-agent 'sudo dnf install -y podman jq git'

# 3. Setup block volume (format, mount, create directories)
ssh oci-agent 'bash -s' < oci-infra/scripts/setup-block-volume.sh

# 4. Deploy AWS credentials
source oci-infra/.env
ssh oci-agent "aws configure set aws_access_key_id '${AWS_ACCESS_KEY_ID}'"
ssh oci-agent "aws configure set aws_secret_access_key '${AWS_SECRET_ACCESS_KEY}'"
ssh oci-agent "aws configure set region '${AWS_REGION}'"

# 5. Copy wikijs-infra to instance
rsync -av --exclude='.git' --exclude='node_modules' --exclude='.env' wikijs-infra/ oci-agent:/home/opc/wikijs-infra/
scp wikijs-infra/.env oci-agent:/home/opc/wikijs-infra/.env

# 6. Deploy Wiki.js (uses bind mounts on block volume)
ssh oci-agent 'cd /home/opc/wikijs-infra && set -a && source .env && set +a && ./scripts/deploy-wikijs.sh deploy'

# 7. Deploy backup cron
source oci-infra/.env
./oci-infra/scripts/deploy-backup-cron.sh --remote oci-agent

# 8. Deploy keep-alive
ssh oci-agent 'bash -s' < oci-infra/scripts/deploy-keep-alive.sh

# 9. Restore from backup (if available)
ssh oci-agent '/home/opc/scripts/backup-wikijs.sh --restore-db s3://agent-coder-dev-backups/wikijs/db/<latest>.sql.gz'

# 10. Verify
ssh oci-agent 'curl -s http://localhost:3001/health'
ssh oci-agent '/home/opc/scripts/backup-wikijs.sh --target local'
```

### Existing instance (redeploy Wiki.js only)

```bash
rsync -av --exclude='.git' --exclude='node_modules' --exclude='.env' wikijs-infra/ oci-agent:/home/opc/wikijs-infra/
scp wikijs-infra/.env oci-agent:/home/opc/wikijs-infra/.env
ssh oci-agent 'cd /home/opc/wikijs-infra && set -a && source .env && set +a && ./scripts/deploy-wikijs.sh update'
```

## Implementation Status

| Action | Status |
|---|---|
| Move pgdata + assets to block volume bind mounts | Done |
| Block volume setup script | Done |
| deploy-wikijs.sh updated for bind mounts | Done |
| Backup script (local + OCI Object Storage) | Done |
| OCI Object Storage bucket (Terraform) | Done |
| OCI Customer Secret Key created | Done |
| Backup to OCI Object Storage tested | Done |
| `source_details` in lifecycle ignore_changes | Done |
| `prevent_destroy` on instance + volume | Done |
| Pin image ID in terraform.tfvars | Done |
| .env split (oci-infra / wikijs-infra) | Done |
| AWS credentials in oci-infra/.env | Done |
| Deploy backup cron to OCI Object Storage | Done |
