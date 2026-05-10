# OCI Infrastructure Repository

A dedicated repository for managing Oracle Cloud Infrastructure (OCI) resources using Infrastructure as Code (IaC) principles. This repository consolidates all OCI-related Terraform modules, deployment scripts, and configuration templates with a focus on ARM64 architecture and cost optimization.

## Overview

This repository provides:

- **Modular Terraform infrastructure** with reusable components for compute, networking, logging, and monitoring
- **Automated deployment scripts** with robust error handling and retry logic
- **ARM64 architecture enforcement** to leverage OCI's Always Free tier
- **Persistent workspace storage** that survives instance terminations
- **Centralized logging and monitoring** infrastructure
- **Secure secret management** with verification tooling
- **Wiki.js deployment support** with PostgreSQL and MCP server

## Key Features

- **ARM64-Only Architecture**: All infrastructure enforces VM.Standard.A1.Flex shape for cost optimization
- **Automated Retry Logic**: Instance provisioning automatically retries across availability domains when capacity is limited
- **Secret Management**: Comprehensive .env-based configuration with verification to prevent credential leakage
- **Persistent Storage**: Workspace volumes that survive instance terminations
- **Comprehensive Logging**: Centralized log collection with OCI unified agent
- **Monitoring & Alerts**: Configurable alarms for CPU, memory, and disk usage

## Repository Structure

```
oci-infra/
├── terraform/          # Terraform modules and configurations
│   ├── modules/        # Reusable Terraform modules
│   │   ├── oci-compute/
│   │   ├── oci-network/
│   │   ├── oci-logging/
│   │   ├── oci-monitoring/
│   │   └── oci-backup/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── backend.tf
├── scripts/            # Deployment and management scripts
│   ├── oci-cleanup.sh
│   ├── oci-instance-retry.sh
│   ├── deploy-wikijs.sh
│   ├── deploy-keep-alive.sh
│   ├── backup-wikijs.sh
│   ├── deploy-backup-cron.sh
│   └── verify-secrets.sh
├── docs/               # Documentation
│   ├── architecture.md
│   ├── deployment-guide.md
│   └── migration-guide.md
├── .env.example        # Environment variable template (documented)
├── .env                # Your local secrets (git-ignored)
├── .gitignore          # Git ignore patterns
└── README.md           # This file
```

## Quick Start

### Prerequisites

1. **OCI Account**: Active Oracle Cloud Infrastructure account
2. **OCI CLI**: Installed and configured ([Installation Guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm))
3. **Terraform**: Version 1.5.0 or later ([Download](https://www.terraform.io/downloads))
4. **OCI API Key**: Generated and configured in your OCI account

### Initial Setup

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd oci-infra
   ```

2. **Configure environment variables**:
   ```bash
   cp .env.example .env
   # Edit .env with your OCI credentials and configuration
   ```

3. **Verify no secrets are committed**:
   ```bash
   ./scripts/verify-secrets.sh --fail-on-detect
   ```

4. **Initialize Terraform**:
   ```bash
   cd terraform
   terraform init
   ```

5. **Provision infrastructure**:
   ```bash
   # Use retry script for automatic availability domain failover
   ../scripts/oci-instance-retry.sh --compartment-id <your-compartment-ocid>
   ```

### Deploy Wiki.js

```bash
# Deploy Wiki.js with PostgreSQL and MCP server
./scripts/deploy-wikijs.sh --port 3000
```

### Cleanup

```bash
# Remove all OCI resources
./scripts/oci-cleanup.sh --compartment-id <your-compartment-ocid>
```

## Environment Configuration

All sensitive configuration is managed through a `.env` file at the repository root. This file is git-ignored and should never be committed.

```bash
cp .env.example .env
# Edit .env with your values
```

The `.env` file contains four groups of settings:

### OCI Instance Connection

| Variable | Description | Default |
|---|---|---|
| `OCI_INSTANCE_IP` | Public IP of the OCI compute instance | _(required)_ |
| `OCI_SSH_KEY` | Path to SSH private key | `~/.ssh/oci_agent_coder` |
| `OCI_SSH_USER` | SSH username | `opc` |

### OCI Object Storage (Backup)

| Variable | Description | Default |
|---|---|---|
| `OCI_NAMESPACE` | Object Storage namespace (tenancy-level) | _(required)_ |
| `OCI_REGION` | OCI region | `us-ashburn-1` |
| `OCI_S3_ACCESS_KEY` | Customer Secret Key — access key | _(required for backups)_ |
| `OCI_S3_SECRET_KEY` | Customer Secret Key — secret | _(required for backups)_ |
| `OCI_BACKUP_BUCKET` | Backup bucket name | `agent-coder-dev-backups` |

To create a Customer Secret Key: OCI Console → Identity → Users → your user → Customer Secret Keys → Generate.

To find your namespace: `oci os ns get --query 'data' --raw-output`

### AWS Credentials (Instance)

Credentials used on the OCI instance for ECR image pulls, S3 workspace storage, and Bedrock API access. Must be re-deployed after any boot volume re-image.

| Variable | Description | Default |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key | _(required)_ |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key | _(required)_ |
| `AWS_REGION` | AWS region for ECR and Bedrock | `us-east-1` |
| `AWS_ECR_REGISTRY` | ECR registry URL | _(required)_ |
| `AWS_S3_BUCKET` | S3 bucket for workspace storage | _(required)_ |

Deploy to the instance:

```bash
source .env
ssh oci-agent "aws configure set aws_access_key_id '${AWS_ACCESS_KEY_ID}'"
ssh oci-agent "aws configure set aws_secret_access_key '${AWS_SECRET_ACCESS_KEY}'"
ssh oci-agent "aws configure set region '${AWS_REGION}'"
```

### Wiki.js Configuration

Wiki.js-specific secrets (admin credentials, API keys, OpenRouter key, database password) live in the `wikijs-infra` repository's `.env` file. See `wikijs-infra/.env.example` for details.
| `API_KEY_RW` | Read-write API gateway key | _(optional)_ |
| `WIKI_ADMIN_TOKEN` | Wiki.js admin JWT | _(required if RW set)_ |

Terraform has its own configuration in `terraform/terraform.tfvars` (see `terraform/terraform.tfvars.example`).

**Important**: Never commit `.env` or `terraform.tfvars` to version control. Both are included in `.gitignore`.

## SSH Access

All remote operations use key-based SSH authentication. The default configuration:

| Setting       | Value                          |
|---------------|--------------------------------|
| User          | `opc`                          |
| Host          | `<OCI_INSTANCE_IP>`            |
| Key           | `~/.ssh/oci_agent_coder`       |

Example connection:

```bash
ssh -i ~/.ssh/oci_agent_coder opc@<OCI_INSTANCE_IP>
```

To run the keep-alive patch remotely:

```bash
ssh -i ~/.ssh/oci_agent_coder opc@<OCI_INSTANCE_IP> 'bash -s' < scripts/deploy-keep-alive.sh
```

**Tip**: Add an entry to `~/.ssh/config` to simplify access:

```
Host oci-agent
    HostName <OCI_INSTANCE_IP>
    User opc
    IdentityFile ~/.ssh/oci_agent_coder
```

Then connect with just `ssh oci-agent`.

## ARM64 Architecture

This repository enforces ARM64 architecture for all OCI deployments to leverage the Always Free tier:

- **Compute Shape**: VM.Standard.A1.Flex only
- **Image Compatibility**: ARM64-compatible images validated before provisioning
- **Cost Optimization**: Always Free tier provides up to 4 OCPUs and 24GB RAM

Any attempt to use non-ARM64 shapes will be rejected with a descriptive error message.

## Documentation

See [docs/README.md](docs/README.md) for the full documentation index.

- [SSH Commands Reference](docs/SSH-COMMANDS.md) — Container access, health checks, log viewing, SSH tunnels
- [Backup and Restore](docs/BACKUP.md) — Backup schedule, restore procedures, troubleshooting
- [Data Loss Mitigation](docs/dataloss-mitigation.md) — Block volume strategy, Terraform safety guards, recovery checklist
- [Data Loss Lessons Learned](docs/dataloss-lessons-learned.md) — April 2026 incident postmortem
- [Architecture Guide](docs/architecture.md) — System architecture and component interactions
- [Deployment Guide](docs/deployment-guide.md) — Detailed deployment instructions and examples
- [Migration Guide](docs/migration-guide.md) — Migrating from agent-infra repository

## Scripts

### oci-instance-retry.sh

Automated retry script for instance provisioning across availability domains.

```bash
./scripts/oci-instance-retry.sh [OPTIONS]
  --compartment-id    OCI compartment OCID (required)
  --shape             Compute shape (default: VM.Standard.A1.Flex)
  --max-retries       Maximum retry attempts (default: unlimited)
  --wait-interval     Wait time between retries in seconds (default: 60)
```

### oci-cleanup.sh

Comprehensive cleanup script for OCI resources.

```bash
./scripts/oci-cleanup.sh [OPTIONS]
  --compartment-id    OCI compartment OCID (required)
  --force             Skip confirmation prompt
  --sweep             Scan for orphaned resources
```

### deploy-keep-alive.sh

Patches the running keep-alive container in-place without rebuilding or affecting other containers. Handles containers in any state (created, stopped, running).

```bash
# Run locally on the OCI instance
./scripts/deploy-keep-alive.sh

# Run remotely via SSH
ssh -i ~/.ssh/oci_agent_coder opc@<OCI_INSTANCE_IP> 'bash -s' < scripts/deploy-keep-alive.sh
```

### deploy-wikijs.sh

Deploys Wiki.js with PostgreSQL and MCP server in a podman pod.

```bash
./scripts/deploy-wikijs.sh [OPTIONS]
  --remote-host       Deploy to remote OCI instance via SSH
  --port              Wiki.js port (default: 3000)
  --enable-writes     Enable write operations (requires admin token)
```

### backup-wikijs.sh

Backs up the Wiki.js PostgreSQL database and assets volume to OCI Object Storage via the S3-compatible API. Uses the AWS CLI with a dedicated `oci` profile — no OCI CLI required.

```bash
./scripts/backup-wikijs.sh                     # full backup (db + assets)
./scripts/backup-wikijs.sh --db-only           # database only
./scripts/backup-wikijs.sh --assets-only       # assets volume only
./scripts/backup-wikijs.sh --list              # list existing backups
./scripts/backup-wikijs.sh --restore-db <file> # restore from backup
```

Backups are stored in the OCI Object Storage bucket under `wikijs/db/` and `wikijs/assets/`. The bucket lifecycle policy auto-deletes backups older than 30 days. Local backups are pruned after 7 days.

### deploy-backup-cron.sh

Deploys the backup script and installs a daily cron job on the OCI instance. Configures the AWS CLI `oci` profile with your Customer Secret Key for S3-compatible access.

```bash
# Source .env and deploy remotely
source .env
./scripts/deploy-backup-cron.sh --remote oci-agent

# Custom schedule (every 6 hours)
./scripts/deploy-backup-cron.sh --remote oci-agent --schedule "0 */6 * * *"

# Remove the cron job
./scripts/deploy-backup-cron.sh --remote oci-agent --remove
```

Requires `OCI_S3_ACCESS_KEY`, `OCI_S3_SECRET_KEY`, and `OCI_NAMESPACE` from `.env`.

### refresh-ecr-login.sh

Manages ECR authentication token refresh.

```bash
./scripts/refresh-ecr-login.sh [OPTIONS]
  --remote-host       Refresh on remote OCI instance via SSH
  --install-cron      Install cron job for periodic refresh
```

### verify-secrets.sh

Scans repository for accidentally committed secrets.

```bash
./scripts/verify-secrets.sh [OPTIONS]
  --fail-on-detect    Exit with error if secrets found
  --patterns-file     Custom patterns file (default: built-in)
```

## Security

- **Secret Management**: All credentials stored in `.env` file (never committed)
- **Secret Verification**: Automated scanning for accidentally committed secrets
- **SSH Access**: Key-based authentication only
- **Network Security**: Configurable security lists and CIDR blocks
- **IAM Policies**: Least-privilege access for OCI resources

## Support

For issues, questions, or contributions, please refer to the documentation in the `docs/` directory.

## License

[Specify your license here]
