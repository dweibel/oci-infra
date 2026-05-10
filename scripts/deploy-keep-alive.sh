#!/bin/bash
set -e

# Deploy/patch the keep-alive container.
#
# The container uses tini as PID 1, so the keep-alive script runs as a
# normal child process. To patch: copy the new script in and restart the
# container. No wrapper hacks needed.
#
# Usage:
#   ./scripts/deploy-keep-alive.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/deploy-keep-alive.sh  # run remotely

CONTAINER_NAME="keep-alive"
SCRIPT_PATH="/keep-alive.sh"

KEEP_ALIVE_SCRIPT='#!/bin/sh
while true; do
    CPU_USAGE=$(top -bn1 | grep "CPU:" | awk "{print int(\$2)}")
    if [ -z "$CPU_USAGE" ]; then CPU_USAGE=0; fi
    if [ "$CPU_USAGE" -lt 15 ]; then
        echo "CPU usage ${CPU_USAGE}% - running stress-ng"
        stress-ng --cpu 2 --timeout 118s --cpu-load 50
    else
        echo "CPU usage ${CPU_USAGE}% - skipping stress-ng"
    fi
    curl -s https://www.oracle.com > /dev/null
    sleep 2
done'

# Check container exists
if ! podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container '${CONTAINER_NAME}' does not exist."
    echo "Build and run it first:"
    echo "  podman build --platform linux/arm64 -t keep-alive -f Dockerfile.keep-alive ."
    echo "  podman run -d --name keep-alive --restart unless-stopped keep-alive"
    exit 1
fi

# Copy patched script into container
echo "Copying keep-alive script into container..."
echo "$KEEP_ALIVE_SCRIPT" | podman exec -i "$CONTAINER_NAME" sh -c "cat > ${SCRIPT_PATH} && chmod +x ${SCRIPT_PATH}"

# Restart container — tini (PID 1) exits cleanly, podman restarts it with
# the updated script via --restart unless-stopped
echo "Restarting container..."
podman restart "$CONTAINER_NAME"

sleep 3

echo ""
echo "=== Container process list ==="
podman exec "$CONTAINER_NAME" ps aux
echo ""

if podman exec "$CONTAINER_NAME" pgrep -f "keep-alive.sh" > /dev/null 2>&1; then
    echo "SUCCESS: keep-alive script is running."
else
    echo "WARNING: keep-alive script does not appear to be running."
    echo "Check logs: podman logs ${CONTAINER_NAME}"
    exit 1
fi
