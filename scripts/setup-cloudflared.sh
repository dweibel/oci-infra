#!/bin/bash
set -euo pipefail

# Install cloudflared and configure it as a systemd service on the OCI instance.
#
# Prerequisites:
#   - A Cloudflare tunnel token (from Zero Trust dashboard)
#
# Usage:
#   ssh oci-agent 'bash -s' < scripts/setup-cloudflared.sh <TUNNEL_TOKEN>
#
# After install:
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

echo "=== Installing cloudflared ==="

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) CF_ARCH="arm64" ;;
    x86_64)  CF_ARCH="amd64" ;;
    *)       echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Install cloudflared binary
if command -v cloudflared &>/dev/null; then
    echo "cloudflared already installed: $(cloudflared --version)"
else
    echo "Downloading cloudflared for ${CF_ARCH}..."
    DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    sudo curl -fsSL -o /usr/local/bin/cloudflared "$DOWNLOAD_URL"
    sudo chmod +x /usr/local/bin/cloudflared
    echo "Installed: $(cloudflared --version)"
fi

echo ""
echo "=== Configuring systemd service ==="

# Create systemd unit that runs the tunnel with the provided token.
# The token encodes the tunnel UUID, account, and ingress rules configured
# in the Cloudflare dashboard — no local config file needed.
sudo tee /etc/systemd/system/cloudflared.service > /dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run --token ${TUNNEL_TOKEN}
Restart=always
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

# Wait for it to come up
sleep 3

echo ""
echo "=== Verifying ==="

if systemctl is-active --quiet cloudflared; then
    echo "SUCCESS: cloudflared is running."
    sudo systemctl status cloudflared --no-pager --lines=5
else
    echo "ERROR: cloudflared failed to start."
    sudo journalctl -u cloudflared --no-pager -n 20
    exit 1
fi
