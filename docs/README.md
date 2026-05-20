# Documentation Index

## Operational

- [SSH Commands Reference](SSH-COMMANDS.md) — Quick reference for connecting to the instance and interacting with all containers (wikijs, goose, keep-alive). Includes health checks, log viewing, database queries, pod management, and SSH tunnel commands.

- [Backup and Restore](BACKUP.md) — Backup schedule, OCI Object Storage configuration, restore procedures for database and assets, monitoring, and troubleshooting.

## Scripts

- `scripts/setup-forge-dirs.sh` — Provisions the Forge directory structure (`/mnt/workspace/forge/`) on the OCI block volume with correct ownership and permissions.
- `scripts/deploy-forge.sh` — Builds the Forge ARM64 container image locally, transfers it to the OCI instance via SCP, and performs a stop/start deployment of the Forge container.

## Architecture

- [Architecture Guide](architecture.md) — System architecture and component interactions.
- [Deployment Guide](deployment-guide.md) — Detailed deployment instructions and examples.
- [Migration Guide](migration-guide.md) — Migrating from the agent-infra repository.

## Foundry Core and Forge Integration

Foundry Core and Forge are co-located on the same OCI instance and communicate exclusively via localhost. Forge binds to `127.0.0.1:3100` and is not exposed externally.

- **Communication:** Foundry Core delegates coding tasks to Forge at `http://localhost:3100`. Both services run as Podman containers on the same host, so no network traversal or tunnel is involved.
- **Authentication:** Both services share a `FORGE_API_KEY` secret. Foundry Core includes this key as a `Bearer` token in the `Authorization` header when calling Forge endpoints. The same key is configured in Forge's `.env` and Foundry Core's environment.
- **No external access:** Forge has no Cloudflare tunnel route. It is accessible only by co-located services (Hermes and Foundry Core) on the same instance.

## Incident Response

- [Data Loss Mitigation](dataloss-mitigation.md) — Block volume strategy, Terraform safety guards, deployment process, and full recovery checklist. Tracks implementation status of all mitigation actions.

- [Data Loss Lessons Learned](dataloss-lessons-learned.md) — April 2026 incident postmortem. Root causes, what was lost, fixes applied, and rules going forward.
