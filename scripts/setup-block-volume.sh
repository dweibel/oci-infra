#!/bin/bash
set -euo pipefail

# Setup block volume for Wiki.js data persistence
# Run on the OCI instance or remotely via: ssh oci-agent 'bash -s' < scripts/setup-block-volume.sh

DEVICE="/dev/sdb"
MOUNT_PATH="/mnt/workspace"

echo "=== Block Volume Setup ==="

# Check device
echo "Checking $DEVICE..."
sudo file -sL "$DEVICE"

# Format if needed (only if no filesystem detected)
if ! sudo blkid "$DEVICE" 2>/dev/null | grep -q ext4; then
    echo "No ext4 filesystem found. Formatting..."
    sudo mkfs.ext4 -F "$DEVICE"
else
    echo "ext4 filesystem already exists."
fi

# Mount
sudo mkdir -p "$MOUNT_PATH"
if ! mountpoint -q "$MOUNT_PATH"; then
    sudo mount "$DEVICE" "$MOUNT_PATH"
    echo "Mounted $DEVICE at $MOUNT_PATH"
else
    echo "Already mounted."
fi

# Add to fstab if not present
if ! grep -q "$MOUNT_PATH" /etc/fstab; then
    echo "$DEVICE $MOUNT_PATH ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
    echo "Added to /etc/fstab"
fi

# Set ownership first (fresh format is owned by root)
sudo chown -R opc:opc "$MOUNT_PATH"

# Create directory structure for Wiki.js
mkdir -p "$MOUNT_PATH/wikijs/pgdata"
mkdir -p "$MOUNT_PATH/wikijs/assets"
mkdir -p "$MOUNT_PATH/backups/wikijs"
mkdir -p "$MOUNT_PATH/containers/config"

# Fix ownership for container bind mounts (rootless podman user namespace)
# Wiki.js runs as node (uid 1000), PostgreSQL runs as postgres (uid 999)
podman unshare chown -R 1000:1000 "$MOUNT_PATH/wikijs/assets"

echo ""
echo "=== Verification ==="
df -h "$MOUNT_PATH"
echo ""
ls -la "$MOUNT_PATH/"
echo ""
ls -la "$MOUNT_PATH/wikijs/"
echo ""
echo "=== Block volume setup complete ==="
