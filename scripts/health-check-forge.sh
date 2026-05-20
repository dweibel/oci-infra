#!/bin/bash
set -euo pipefail

# Health check for the Forge container on the OCI instance.
# Verifies the Podman container is running and the HTTP health endpoint responds.
#
# Usage:
#   ./scripts/health-check-forge.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/health-check-forge.sh  # run remotely
#
# Exit codes:
#   0 - Container running and health endpoint returned HTTP 200
#   1 - Container not running, or health endpoint failed
#
# Prerequisites:
#   - Forge container deployed (see scripts/deploy-forge.sh)

CONTAINER_NAME="forge"
HEALTH_URL="http://localhost:3100/health"
TIMEOUT=5

echo "=== Forge Health Check ==="

# --- Step 1: Verify container is running ---

CONTAINER_STATE=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not_found")

if [ "$CONTAINER_STATE" != "running" ]; then
    echo "ERROR: Container '${CONTAINER_NAME}' is not running (state: ${CONTAINER_STATE})"
    echo "Start it with: podman start ${CONTAINER_NAME}"
    echo "Or redeploy:   deploy-forge.sh"
    exit 1
fi

echo "Container '${CONTAINER_NAME}' is running."

# --- Step 2: HTTP health check ---

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$HEALTH_URL" 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ]; then
    echo "Health endpoint returned HTTP 200 — container is healthy."
    exit 0
elif [ "$HTTP_CODE" = "000" ]; then
    echo "ERROR: Connection refused or network error — Forge is not listening on port 3100."
    echo "Check logs: podman logs ${CONTAINER_NAME}"
    exit 1
else
    echo "ERROR: Health endpoint returned HTTP ${HTTP_CODE} (expected 200)."
    echo "Check logs: podman logs ${CONTAINER_NAME}"
    exit 1
fi
