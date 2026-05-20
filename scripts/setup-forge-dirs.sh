#!/bin/bash
set -euo pipefail

# Setup Forge data directories on the block volume
# Run on the OCI instance or remotely via: ssh oci-agent 'bash -s' < scripts/setup-forge-dirs.sh
#
# Prerequisites:
#   - Block volume mounted at /mnt/workspace (see scripts/setup-block-volume.sh)
#   - Run as opc user (or with sudo for ownership changes)

MOUNT_PATH="/mnt/workspace"
FORGE_DIR="$MOUNT_PATH/forge"
BACKUP_DIR="$MOUNT_PATH/backups/forge"

echo "=== Forge Directory Setup ==="

# --- Pre-flight checks ---

# Verify block volume is mounted
if ! mountpoint -q "$MOUNT_PATH"; then
    echo "ERROR: $MOUNT_PATH is not mounted. Run setup-block-volume.sh first."
    exit 1
fi

# --- Create directory structure ---

echo "Creating Forge directories..."
mkdir -p "$FORGE_DIR"
mkdir -p "$FORGE_DIR/data"
mkdir -p "$FORGE_DIR/workspaces"
mkdir -p "$BACKUP_DIR"

# --- Set ownership and permissions ---

echo "Setting ownership and permissions..."
sudo chown opc:opc "$FORGE_DIR"
sudo chmod 755 "$FORGE_DIR"
sudo chown opc:opc "$FORGE_DIR/data"
sudo chmod 755 "$FORGE_DIR/data"
sudo chown opc:opc "$FORGE_DIR/workspaces"
sudo chmod 755 "$FORGE_DIR/workspaces"
sudo chown opc:opc "$BACKUP_DIR"
sudo chmod 755 "$BACKUP_DIR"

# --- Summary ---

echo ""
echo "=== Verification ==="
ls -la "$FORGE_DIR/"
echo ""
echo "=== Forge directory setup complete ==="
echo ""
echo "Directories created:"
echo "  $FORGE_DIR"
echo "  $FORGE_DIR/data"
echo "  $FORGE_DIR/workspaces"
echo "  $BACKUP_DIR"
echo ""
echo "Next steps:"
echo "  Copy the env template to $FORGE_DIR/.env and populate secrets:"
echo "    cp config/forge.env.example $FORGE_DIR/.env"
