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
│   │   └── oci-monitoring/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── backend.tf
├── scripts/            # Deployment and management scripts
│   ├── oci-cleanup.sh
│   ├── oci-instance-retry.sh
│   ├── deploy-wikijs.sh
│   ├── refresh-ecr-login.sh
│   └── verify-secrets.sh
├── docs/               # Documentation
│   ├── architecture.md
│   ├── deployment-guide.md
│   └── migration-guide.md
├── .env.example        # Environment variable template
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

All sensitive configuration is managed through a `.env` file. Copy `.env.example` to `.env` and populate with your values:

```bash
# OCI Authentication
OCI_TENANCY_OCID=ocid1.tenancy.oc1...
OCI_USER_OCID=ocid1.user.oc1...
OCI_FINGERPRINT=xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx
OCI_PRIVATE_KEY_PATH=/path/to/oci_api_key.pem
OCI_REGION=us-ashburn-1

# Compartment Configuration
OCI_COMPARTMENT_OCID=ocid1.compartment.oc1...

# Wiki.js Configuration
WIKI_ADMIN_EMAIL=admin@example.com
WIKI_ADMIN_PASSWORD=secure_password_here
POSTGRES_PASSWORD=secure_db_password_here

# MCP Server Configuration
MCP_ADMIN_TOKEN=secure_token_here
MCP_ENABLE_WRITES=false
```

**Important**: Never commit the `.env` file to version control. It is included in `.gitignore` by default.

## ARM64 Architecture

This repository enforces ARM64 architecture for all OCI deployments to leverage the Always Free tier:

- **Compute Shape**: VM.Standard.A1.Flex only
- **Image Compatibility**: ARM64-compatible images validated before provisioning
- **Cost Optimization**: Always Free tier provides up to 4 OCPUs and 24GB RAM

Any attempt to use non-ARM64 shapes will be rejected with a descriptive error message.

## Documentation

- **[Architecture Guide](docs/architecture.md)**: System architecture and component interactions
- **[Deployment Guide](docs/deployment-guide.md)**: Detailed deployment instructions and examples
- **[Migration Guide](docs/migration-guide.md)**: Migrating from agent-infra repository

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

### deploy-wikijs.sh

Deploys Wiki.js with PostgreSQL and MCP server in a podman pod.

```bash
./scripts/deploy-wikijs.sh [OPTIONS]
  --remote-host       Deploy to remote OCI instance via SSH
  --port              Wiki.js port (default: 3000)
  --enable-writes     Enable write operations (requires admin token)
```

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
