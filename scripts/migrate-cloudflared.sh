#!/bin/bash
set -euo pipefail

# Migrate cloudflared from a Podman container to a systemd service on the OCI instance.
#
# This is a one-shot migration script that:
#   1. Tears down the existing cloudflared Podman container, secret, and image
#   2. Installs the cloudflared binary (if not already present)
#   3. Creates and starts a systemd service with the provided tunnel token
#
# Prerequisites:
#   - A Cloudflare tunnel token (from Zero Trust dashboard)
#   - The cloudflared container is currently running (or already removed — idempotent)
#
# Usage:
#   ssh oci-agent 'bash -s' < scripts/migrate-cloudflared.sh <TUNNEL_TOKEN>
#
# After migration:
#   systemctl status cloudflared          # check status
#   journalctl -u cloudflared -f          # follow logs
#   cloudflared tunnel info               # tunnel metadata

TUNNEL_TOKEN="${1:-}"

if [[ -z "$TUNNEL_TOKEN" ]]; then
    echo "ERROR: Tunnel token required."
    echo "Usage: $0 <TUNNEL_TOKEN>"
    echo ""
    echo "Get a token from: Cloudflare Zero Trust → Networks → Tunnels → <tunnel> → Configure"
    exit 1
fi

# --- Phase 1: Tear down Podman container ---

echo "=== Removing cloudflared container ==="

if podman ps -a --format '{{.Names}}' | grep -q '^cloudflared$'; then
    echo "Stopping cloudflared container..."
    podman stop cloudflared 2>/dev/null || true
    echo "Removing cloudflared container..."
    podman rm cloudflared
else
    echo "WARNING: cloudflared container not found (already removed?)"
fi

echo ""
echo "=== Removing Podman secret ==="

if podman secret ls --format '{{.Name}}' | grep -q '^goose-tunnel-token$'; then
    podman secret rm goose-tunnel-token
    echo "Removed goose-tunnel-token secret."
else
    echo "WARNING: goose-tunnel-token secret not found (already removed?)"
fi

echo ""
echo "=== Removing cloudflared container image ==="

if podman images --format '{{.Repository}}' | grep -q 'cloudflare/cloudflared'; then
    podman rmi docker.io/cloudflare/cloudflared --force
    echo "Removed cloudflare/cloudflared image."
else
    echo "WARNING: cloudflare/cloudflared image not found (already removed?)"
fi

# --- Phase 2: Install cloudflared binary ---

echo ""
echo "=== Installing cloudflared binary ==="

ARCH=$(uname -m)
case "$ARCH" in
    aarch64) CF_ARCH="arm64" ;;
    x86_64)  CF_ARCH="amd64" ;;
    *)       echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
esac

if command -v cloudflared &>/dev/null && cloudflared --version &>/dev/null; then
    echo "cloudflared already installed: $(cloudflared --version)"
else
    echo "Downloading cloudflared for ${CF_ARCH}..."
    DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    sudo curl -fsSL -o /usr/local/bin/cloudflared "$DOWNLOAD_URL"
    sudo chmod +x /usr/local/bin/cloudflared
    echo "Installed: $(cloudflared --version)"
fi

# --- Phase 3: Configure systemd service ---

echo ""
echo "=== Configuring systemd service ==="

sudo tee /etc/systemd/system/cloudflared.service > /dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5
TimeoutStartSec=0

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

# --- Phase 4: Verify tunnel connections ---

echo ""
echo "=== Verifying tunnel connections ==="

TIMEOUT=10
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if sudo journalctl -u cloudflared --no-pager -n 50 2>/dev/null | grep -q "Registered tunnel connection"; then
        echo "SUCCESS: cloudflared systemd service is running with active tunnel connections."
        echo ""
        sudo journalctl -u cloudflared --no-pager -n 10 | grep "Registered tunnel connection" || true
        echo ""
        echo "Migration complete. Container-based cloudflared has been replaced with systemd service."
        exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

# Tunnel didn't register connections within timeout
echo "ERROR: No tunnel connections registered within ${TIMEOUT}s."
echo ""
echo "Journal output:"
sudo journalctl -u cloudflared --no-pager -n 20
echo ""
echo "Troubleshooting:"
echo "  - Check token validity in Cloudflare Zero Trust dashboard"
echo "  - Verify network connectivity: curl -s https://cloudflare.com"
echo "  - Check service status: systemctl status cloudflared"
exit 1
