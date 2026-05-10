# Cloudflared Migration Runbook

Migrate cloudflared from a Podman container (on `goose-network`) to a systemd service running directly on the OCI host.

## Pre-Migration State

Before migration, cloudflared runs as a Podman container on the `goose-network` (10.89.0.0/24):

```
┌─────────────────── goose-network (10.89.0.0/24) ──────────────┐
│                                                                │
│  ┌──────────────┐        ┌──────────────────┐                 │
│  │  goose-web   │        │   cloudflared    │                 │
│  │  :7681       │◄───────│   (container)    │◄── CF Edge      │
│  └──────────────┘        └──────────────────┘                 │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

- **cloudflared** runs as a Podman container named `cloudflared` on `goose-network`
- **Tunnel token** is stored as a Podman secret (`goose-tunnel-token`)
- **Dashboard routes** use container names as origins (e.g., `http://goose-web:7681`)
- **Problem**: Services on `localhost` (Hermes, Onyx) are unreachable from the container network

## Migration Steps

Execute these steps in order. The entire process takes ~5 minutes.

### Step 1: Update Dashboard Routes

Update routes in the Cloudflare Zero Trust dashboard to use `localhost` origins:

1. Go to **Cloudflare Zero Trust → Networks → Tunnels → \<tunnel\> → Configure → Public Hostname**
2. Update each route:

| Public Hostname | New Service Origin |
|---|---|
| `goose.dirkweibel.dev` | `http://localhost:7681` |
| `hermes.dirkweibel.dev` | `http://localhost:9119` |
| `hermes-api.dirkweibel.dev` | `http://localhost:8081` |

3. Save changes. Routes take effect immediately (no cloudflared restart needed).

### Step 2: Run the Migration Script

Obtain the tunnel token from: **Cloudflare Zero Trust → Networks → Connectors → \<tunnel\> → Configure**

Run the migration script from your local machine:

```bash
ssh oci-agent 'bash -s' < scripts/migrate-cloudflared.sh <TUNNEL_TOKEN>
```

The script performs these actions automatically:
1. Stops and removes the `cloudflared` Podman container
2. Removes the `goose-tunnel-token` Podman secret
3. Removes the `cloudflare/cloudflared` container image
4. Installs the `cloudflared` binary to `/usr/local/bin/cloudflared` (if not present)
5. Creates a systemd unit at `/etc/systemd/system/cloudflared.service`
6. Enables and starts the `cloudflared` systemd service
7. Verifies tunnel connections are registered (waits up to 10s)

### Step 3: Update Management Scripts

After migration, update the scripts in `goose-infra` to use systemd commands:

- `goose-infra/scripts/tunnel.sh` — rewrite to use `systemctl` instead of `podman`
- `goose-infra/scripts/start.sh` — remove cloudflared container startup section
- `goose-infra/scripts/validate.sh` — check systemd service instead of container

### Step 4: Verify

Run the full verification procedure (see [Post-Migration Verification](#post-migration-verification) below).

## Rollback Procedure

If the systemd service fails and cannot be fixed quickly, restore the container-based setup:

```bash
# 1. Stop and disable the systemd service
sudo systemctl stop cloudflared
sudo systemctl disable cloudflared

# 2. Re-deploy cloudflared as a Podman container
#    (same approach as the original goose-infra/scripts/tunnel.sh)
podman secret rm goose-tunnel-token 2>/dev/null || true
printf '%s' "<TUNNEL_TOKEN>" | podman secret create goose-tunnel-token -

podman pull docker.io/cloudflare/cloudflared:latest

CF_TOKEN=$(podman secret inspect goose-tunnel-token --showsecret \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['SecretData'])")

podman run -d --name cloudflared \
  --network goose-network \
  --restart unless-stopped \
  docker.io/cloudflare/cloudflared:latest \
  tunnel run --token "$CF_TOKEN"

# 3. Revert dashboard routes (if changed)
#    goose.dirkweibel.dev → http://goose-web:7681 (container name resolution)
```

Replace `<TUNNEL_TOKEN>` with the actual token from the Cloudflare Zero Trust dashboard.

After rollback, verify the container is running:

```bash
podman ps --filter name=cloudflared
podman logs cloudflared 2>&1 | grep "Registered tunnel connection"
```

## Post-Migration Verification

### Service Health

```bash
# Check systemd service is active
systemctl status cloudflared --no-pager

# Confirm tunnel connections are registered
journalctl -u cloudflared --no-pager -n 20 | grep "Registered tunnel connection"
```

### Route Verification

From your local machine, verify each route responds:

```bash
curl -s -o /dev/null -w '%{http_code}' https://goose.dirkweibel.dev
# Expected: 200 or 302 (Cloudflare Access redirect)

curl -s -o /dev/null -w '%{http_code}' https://hermes.dirkweibel.dev
# Expected: 200 or 302

curl -s -o /dev/null -w '%{http_code}' https://hermes-api.dirkweibel.dev
# Expected: valid HTTP response (200, 401, etc.)
```

### Validation Script

Run the goose-infra validation script (after it has been updated in Step 3):

```bash
./scripts/validate.sh
```

This checks:
- `systemctl is-active cloudflared` returns "active"
- Journal shows at least one "Registered tunnel connection"
- All public hostnames respond

### Cleanup Verification

Confirm the old container artifacts are gone:

```bash
# No cloudflared container should exist
podman ps -a --filter name=cloudflared

# No goose-tunnel-token secret should exist
podman secret ls | grep goose-tunnel-token

# No cloudflared image should remain
podman images | grep cloudflared
```

## Troubleshooting

| Symptom | Diagnosis | Resolution |
|---|---|---|
| Service not running | `systemctl status cloudflared` | `sudo systemctl restart cloudflared` |
| No tunnel connections | `journalctl -u cloudflared -n 50` | Check token validity, network connectivity |
| Route returns 502 | Target service not running on expected port | Check: `podman ps` or `ss -tlnp` |
| Route returns 1033 | Dashboard route misconfigured | Verify route in CF Zero Trust dashboard |
