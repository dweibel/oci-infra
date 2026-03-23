#!/bin/bash
set -e

echo "Building keep-alive container for ARM64..."
podman build --platform linux/arm64 -t keep-alive -f Dockerfile.keep-alive .

echo "Stopping existing keep-alive container if running..."
podman stop keep-alive 2>/dev/null || true
podman rm keep-alive 2>/dev/null || true

echo "Starting keep-alive container..."
podman run -d \
    --name keep-alive \
    --restart unless-stopped \
    keep-alive

echo "Keep-alive container deployed successfully"
podman ps | grep keep-alive
