#!/bin/bash
set -euo pipefail

# Deploy the Forge container to the OCI ARM64 instance.
# Builds the image locally for linux/arm64, transfers via SCP, and starts the container.
#
# Usage:
#   ./scripts/deploy-forge.sh                        # uses default ../forge relative to script
#   ./scripts/deploy-forge.sh --forge-dir ~/forge    # explicit Forge project path
#
# Prerequisites:
#   - Podman installed locally (for cross-platform build)
#   - SSH host 'oci-agent' configured in ~/.ssh/config
#   - /mnt/workspace/forge/ directory created on instance (see scripts/setup-forge-dirs.sh)
#   - /mnt/workspace/forge/.env populated with secrets (see config/forge.env.example)
#
# FORGE_URL uses http://localhost:3100 because Forge is a localhost-only service
# on the same OCI instance — no external access via Cloudflare tunnel.

CONTAINER_NAME="forge"
IMAGE_TAG="forge:latest"
PLATFORM="linux/arm64"
SSH_HOST="oci-agent"
REMOTE_TAR_PATH="/home/opc/forge-arm64.tar"
FORGE_DIR=""

# --- Parse arguments ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --forge-dir)
            FORGE_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--forge-dir <path>]"
            exit 1
            ;;
    esac
done

# Default to ../forge relative to this script's location
if [ -z "$FORGE_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FORGE_DIR="$(cd "$SCRIPT_DIR/../../forge" && pwd)"
fi

if [ ! -f "$FORGE_DIR/Containerfile" ]; then
    echo "ERROR: Containerfile not found at $FORGE_DIR/Containerfile"
    echo "Specify the Forge project root with --forge-dir"
    exit 1
fi

echo "=== Forge Deployment ==="
echo "Forge project: $FORGE_DIR"
echo ""

# --- Build image ---

echo "=== Building container image (${PLATFORM}) ==="

if ! podman build --platform "$PLATFORM" -t "$IMAGE_TAG" "$FORGE_DIR"; then
    echo ""
    echo "ERROR: Container image build failed."
    exit 1
fi

echo "Build complete: $IMAGE_TAG"
echo ""

# --- Export and transfer ---

echo "=== Exporting image and transferring to ${SSH_HOST} ==="

LOCAL_TAR="$(mktemp -t forge-arm64-XXXXXX.tar)"
trap 'rm -f "$LOCAL_TAR"' EXIT

podman save "$IMAGE_TAG" -o "$LOCAL_TAR"

if ! scp "$LOCAL_TAR" "${SSH_HOST}:${REMOTE_TAR_PATH}"; then
    echo ""
    echo "ERROR: SCP transfer failed."
    exit 1
fi

echo "Image transferred to ${SSH_HOST}:${REMOTE_TAR_PATH}"
echo ""

# --- Load image on instance ---

echo "=== Loading image on instance ==="

ssh "$SSH_HOST" "podman load < ${REMOTE_TAR_PATH} && rm -f ${REMOTE_TAR_PATH}"

echo "Image loaded into Podman on instance."
echo ""

# --- Pre-flight check: .env exists ---

echo "=== Pre-flight checks ==="

if ! ssh "$SSH_HOST" "test -f /mnt/workspace/forge/.env"; then
    echo "ERROR: /mnt/workspace/forge/.env not found."
    echo "Copy config/forge.env.example to /mnt/workspace/forge/.env and fill in the values."
    exit 1
fi

echo "Pre-flight checks passed."
echo ""

# --- Stop and remove existing container ---

echo "=== Stopping existing container ==="

if ssh "$SSH_HOST" "podman ps -a --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
    echo "Stopping existing container '${CONTAINER_NAME}'..."
    ssh "$SSH_HOST" "podman stop ${CONTAINER_NAME} 2>/dev/null || true"
    echo "Removing existing container '${CONTAINER_NAME}'..."
    ssh "$SSH_HOST" "podman rm ${CONTAINER_NAME} 2>/dev/null || true"
else
    echo "No existing container to remove."
fi

echo ""

# --- Start container ---

echo "=== Starting container ==="

ssh "$SSH_HOST" "podman run -d \
    --name ${CONTAINER_NAME} \
    --userns=keep-id \
    --restart unless-stopped \
    --env-file /mnt/workspace/forge/.env \
    -p 127.0.0.1:3100:3100 \
    -v /mnt/workspace/forge/data:/data/forge:Z \
    -v /mnt/workspace/forge/workspaces:/workspaces:Z \
    ${IMAGE_TAG}"

echo "Container '${CONTAINER_NAME}' started."
echo ""

# --- Verify container is running ---

echo "=== Verifying container (waiting 5s) ==="

sleep 5

if ssh "$SSH_HOST" "podman ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'"; then
    echo "Container '${CONTAINER_NAME}' is running."
    ssh "$SSH_HOST" "podman ps --filter name=${CONTAINER_NAME} --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
else
    echo ""
    echo "ERROR: Container '${CONTAINER_NAME}' is not running after 5 seconds."
    echo "Check logs: ssh ${SSH_HOST} 'podman logs ${CONTAINER_NAME}'"
    exit 1
fi

echo ""

# --- Health check ---

echo "=== Health check ==="

HEALTH_RESULT=$(ssh "$SSH_HOST" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3100/health 2>/dev/null" || true)

if [ "$HEALTH_RESULT" = "200" ]; then
    echo "Health check passed: GET /health returned HTTP 200"
else
    echo "WARNING: Health check returned HTTP ${HEALTH_RESULT:-timeout/error} (container may need more startup time)"
fi

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Next steps:"
echo "  - Check health: ssh ${SSH_HOST} 'curl -s http://localhost:3100/health'"
echo "  - View logs:    ssh ${SSH_HOST} 'podman logs -f ${CONTAINER_NAME}'"
