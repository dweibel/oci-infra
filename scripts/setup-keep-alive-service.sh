#!/bin/bash
set -euo pipefail

# Setup systemd user service for keep-alive container auto-recovery on reboot.
#
# This creates a systemd user unit for the 'opc' user that starts the
# keep-alive Podman container on boot. Combined with loginctl linger (already
# enabled), this ensures the container survives reboots without manual intervention.
#
# Execution:
#   ssh oci-agent 'bash -s' < scripts/setup-keep-alive-service.sh
#
# Prerequisites:
#   - keep-alive container already created (podman ps -a shows it)
#   - loginctl linger enabled for opc (loginctl enable-linger opc)

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="keep-alive.service"
CONTAINER_NAME="keep-alive"

echo "=== Setting up keep-alive systemd user service ==="

# Verify the container exists
if ! podman inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "ERROR: Container '${CONTAINER_NAME}' not found. Create it first."
    exit 1
fi

# Verify linger is enabled
if [[ ! -f "/var/lib/systemd/linger/$(whoami)" ]]; then
    echo "WARNING: Linger not enabled for $(whoami). Enabling..."
    loginctl enable-linger "$(whoami)"
fi

# Create unit directory if needed
mkdir -p "$UNIT_DIR"

# Write the service unit
cat > "${UNIT_DIR}/${SERVICE_NAME}" << 'EOF'
[Unit]
Description=Keep-Alive Container (OCI free-tier reclamation prevention)
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
Restart=on-failure
RestartSec=10
ExecStart=/usr/bin/podman start keep-alive
ExecStop=/usr/bin/podman stop -t 30 keep-alive
TimeoutStartSec=30
TimeoutStopSec=45

[Install]
WantedBy=default.target
EOF

echo "Created ${UNIT_DIR}/${SERVICE_NAME}"

# Reload systemd user daemon
systemctl --user daemon-reload
echo "Reloaded systemd user daemon"

# Enable the service (creates symlink in default.target.wants)
systemctl --user enable "$SERVICE_NAME"
echo "Enabled ${SERVICE_NAME}"

# Start the service if the container isn't already running
local_state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not_found")
if [[ "$local_state" != "running" ]]; then
    systemctl --user start "$SERVICE_NAME"
    echo "Started ${SERVICE_NAME}"
else
    echo "Container already running — skipping start"
fi

# Verify
echo ""
echo "=== Verification ==="
systemctl --user status "$SERVICE_NAME" --no-pager 2>/dev/null | head -10
echo ""
echo "Container status: $(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"
echo ""
echo "Done. Keep-alive will auto-start on reboot via systemd user service."
