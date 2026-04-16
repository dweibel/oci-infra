#!/bin/bash
set -e

CONTAINER_NAME="keep-alive"
SCRIPT_PATH="/keep-alive.sh"

# The corrected keep-alive loop script
# Uses awk int() to truncate decimal CPU values for integer comparison
KEEP_ALIVE_SCRIPT='#!/bin/sh
while true; do
    CPU_USAGE=$(top -bn1 | grep "CPU:" | awk "{print int(\$2)}")
    if [ -z "$CPU_USAGE" ]; then CPU_USAGE=0; fi
    if [ "$CPU_USAGE" -lt 15 ]; then
        echo "CPU usage ${CPU_USAGE}% - running stress-ng"
        stress-ng --cpu 1 --timeout 118s --cpu-load 80
    else
        echo "CPU usage ${CPU_USAGE}% - skipping stress-ng"
    fi
    curl -s https://www.oracle.com > /dev/null
    sleep 2
done'

echo "Checking if container '${CONTAINER_NAME}' is running..."
if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container '${CONTAINER_NAME}' is not running."
    echo "Use a full rebuild if the container doesn't exist yet."
    exit 1
fi

echo "Copying patched keep-alive script into container..."
echo "$KEEP_ALIVE_SCRIPT" | podman exec -i "$CONTAINER_NAME" sh -c "cat > ${SCRIPT_PATH} && chmod +x ${SCRIPT_PATH}"

echo "Killing existing keep-alive loop process inside container..."
# Kill the shell loop (PID 1's child processes: stress-ng, curl, sleep)
podman exec "$CONTAINER_NAME" sh -c 'kill $(pgrep -f stress-ng) 2>/dev/null; kill $(pgrep -f "curl.*oracle") 2>/dev/null; kill $(pgrep -f "sleep 2") 2>/dev/null' || true

echo "Restarting keep-alive script inside container..."
podman exec -d "$CONTAINER_NAME" sh -c "${SCRIPT_PATH}"

echo "Patched and restarted keep-alive process successfully (container preserved)."
podman exec "$CONTAINER_NAME" ps aux
