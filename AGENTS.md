# OCI Infrastructure

Infrastructure-as-Code repository for **The Foundry** — managing all Oracle Cloud Infrastructure resources that host the distributed system via Terraform and deployment scripts.

## Ecosystem Context

See `foundry-core/docs/ECOSYSTEM.md` for the full system architecture and component relationships.

## Key Facts

- **Tools:** Terraform, Bash scripts
- **Compute shape:** VM.Standard.A1.Flex (ARM64, Always Free tier)
- **Terraform:** `cd terraform && terraform init && terraform plan && terraform apply`
- **State:** Remote backend; variables in `terraform.tfvars` (git-ignored)

## Project Structure

```
terraform/           Modules: oci-compute, oci-network, oci-logging, oci-monitoring, oci-backup
scripts/             Provisioning, deployment, backup, and migration scripts
container/           Container-related configurations
docs/                Architecture and migration guides
```

## Key Concepts

- ARM64-only architecture (OCI Always Free: 4 OCPUs, 24GB RAM)
- Automated retry across availability domains for capacity issues
- Persistent block volumes surviving instance terminations
- S3-compatible backups via OCI Object Storage
- Keep-alive container prevents free-tier reclamation

## Documentation

- [docs/](docs/) — architecture, deployment, and migration guides
- [scripts/](scripts/) — all operational scripts with inline documentation
