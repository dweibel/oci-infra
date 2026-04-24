# SSH Commands Reference

Quick reference for connecting to the OCI instance and interacting with containers.

## Instance Access

```bash
# Connect to the instance
ssh oci-agent

# SSH config (in ~/.ssh/config):
# Host oci-agent
#     HostName 193.122.215.174
#     User opc
#     IdentityFile ~/.ssh/oci_agent_coder
```

## Container Status

```bash
# All containers
ssh oci-agent "podman ps -a --format 'table {{.Names}} {{.Image}} {{.Status}}'"

# Wiki.js pod only
ssh oci-agent "podman ps -a --filter pod=wikijs --format 'table {{.Names}} {{.Status}}'"
```

## Wiki.js Containers

### wikijs-app (Wiki.js web application)

```bash
# Logs
ssh oci-agent "podman logs wikijs-app --tail 20"

# Restart
ssh oci-agent "podman restart wikijs-app"

# Shell into container
ssh oci-agent "podman exec -it wikijs-app sh"

# Check if Wiki.js is in normal mode (not setup mode)
ssh oci-agent "podman logs wikijs-app 2>&1 | grep -E 'RUNNING|Setup'"

# Access Wiki.js web UI via SSH tunnel (browse http://localhost:3000)
ssh -L 3000:localhost:3000 oci-agent
```

### wikijs-postgres (PostgreSQL + pgvector)

```bash
# Check database is ready
ssh oci-agent "podman exec wikijs-postgres pg_isready -U wiki -d wiki"

# Interactive psql session
ssh oci-agent "podman exec -it wikijs-postgres psql -U wiki -d wiki"

# Page count
ssh oci-agent "podman exec wikijs-postgres psql -U wiki -d wiki -t -c 'SELECT COUNT(*) FROM pages;'"

# Embedding count
ssh oci-agent "podman exec wikijs-postgres psql -U wiki -d wiki -t -c 'SELECT COUNT(*) FROM wiki_embeddings;'"

# Database size
ssh oci-agent "podman exec wikijs-postgres psql -U wiki -d wiki -t -c \"SELECT pg_size_pretty(pg_database_size('wiki'));\""

# Logs
ssh oci-agent "podman logs wikijs-postgres --tail 20"

# Data location (block volume)
ssh oci-agent "sudo du -sh /mnt/workspace/wikijs/pgdata/"
```

### wikijs-gateway (REST API gateway)

```bash
# Health check
ssh oci-agent "curl -s http://localhost:3001/health"

# Logs (includes sync pipeline output)
ssh oci-agent "podman logs wikijs-gateway --tail 20"

# Restart
ssh oci-agent "podman restart wikijs-gateway"

# Check env vars
ssh oci-agent "podman exec wikijs-gateway env | grep -E 'GATEWAY_PORT|EMBEDDING_MODEL|SYNC_INTERVAL'"

# Test API with read-only key (source wikijs-infra/.env first for $API_KEY_RO)
ssh oci-agent "curl -s -H 'Authorization: Bearer <API_KEY_RO>' http://localhost:3001/api/pages"
```

### Wiki.js Pod Management

```bash
# Stop entire pod
ssh oci-agent "podman pod stop wikijs"

# Start entire pod
ssh oci-agent "podman pod start wikijs"

# Pod status
ssh oci-agent "podman pod ps --filter name=wikijs"

# Full redeploy (from wikijs-infra repo on instance)
ssh oci-agent "cd /home/opc/wikijs-infra && set -a && source .env && set +a && ./scripts/deploy-wikijs.sh destroy && ./scripts/deploy-wikijs.sh deploy"
```

## Goose Container

### goose-web (AI agent with web terminal)

```bash
# Logs
ssh oci-agent "podman logs goose-web --tail 20"

# Shell into container
ssh oci-agent "podman exec -it goose-web bash -l"

# Check wiki-cli works
ssh oci-agent "podman exec goose-web bash -lc 'wiki-cli list'"

# Check env vars
ssh oci-agent "podman exec goose-web env | grep -E 'WIKI_GATEWAY|GOOSE_MODE|GOOSE_MODEL'"

# Restart
ssh oci-agent "podman restart goose-web"

# Access web terminal via SSH tunnel (browse http://localhost:7681)
ssh -L 7681:localhost:7681 oci-agent

# Rebuild and redeploy (from local machine)
cd goose-infra
./scripts/build.sh
./scripts/restart.sh
```

## Keep-Alive Container

### keep-alive (prevents OCI instance reclaim)

```bash
# Process list (tini as PID 1, keep-alive.sh as child)
ssh oci-agent "podman exec keep-alive ps aux"

# Logs
ssh oci-agent "podman logs keep-alive --tail 10"

# Restart
ssh oci-agent "podman restart keep-alive"

# Patch script in-place and restart
ssh oci-agent 'bash -s' < scripts/deploy-keep-alive.sh
```

## Backup

```bash
# Run manual backup (db + assets to OCI Object Storage)
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh"

# Local-only backup (no OCI credentials needed)
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh --target local"

# List all backups
ssh oci-agent "/home/opc/scripts/backup-wikijs.sh --list"

# Check backup log
ssh oci-agent "tail -20 /mnt/workspace/backups/wikijs/backup.log"

# Check cron is installed
ssh oci-agent "crontab -l"
```

## GitHub Actions Runner

### Setup (after server rebuild)

```bash
# 1. Get a registration token from:
#    https://github.com/dweibel/gocoder/settings/actions/runners/new
# 2. Run the setup script remotely:
ssh oci-agent 'bash -s' < scripts/setup-github-runner.sh <TOKEN>
```

### Management

```bash
# Service status
ssh oci-agent "systemctl --user status actions-runner"

# Logs
ssh oci-agent "journalctl --user -u actions-runner --no-pager -n 30"

# Restart
ssh oci-agent "systemctl --user restart actions-runner"

# Stop
ssh oci-agent "systemctl --user stop actions-runner"
```

## System Health

```bash
# Instance uptime and load
ssh oci-agent "uptime"

# CPU and memory
ssh oci-agent "top -bn1 | head -5"

# Disk usage
ssh oci-agent "df -h / /mnt/workspace"

# Block volume contents
ssh oci-agent "du -sh /mnt/workspace/*"

# All container images
ssh oci-agent "podman images --format 'table {{.Repository}} {{.Tag}} {{.Size}}'"

# Podman secrets
ssh oci-agent "podman secret ls"
```
