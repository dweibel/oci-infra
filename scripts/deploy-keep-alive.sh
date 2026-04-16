#!/bin/bash
set -e

CONTAINER_NAME="keep-alive"
SCRIPT_PATH="/keep-alive.sh"

# The corrected keep-alive loop script
# Uses awk int() to truncate decimal CPU values for integer comparison
# Sets KEEP_ALIVE_PATCHED=1 so the stress-ng wrapper knows to run the real binary
KEEP_ALIVE_SCRIPT='#!/bin/sh
export KEEP_ALIVE_PATCHED=1
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

# --- Container state handling ---

CONTAINER_EXISTS=$(podman ps -a --format '{{.Names}}' | grep -c "^${CONTAINER_NAME}$" || true)
CONTAINER_RUNNING=$(podman ps --format '{{.Names}}' | grep -c "^${CONTAINER_NAME}$" || true)

if [ "$CONTAINER_EXISTS" -eq 0 ]; then
    echo "ERROR: Container '${CONTAINER_NAME}' does not exist."
    echo "Build it first with: podman build --platform linux/arm64 -t keep-alive -f Dockerfile.keep-alive ."
    echo "Then create it with: podman run -d --name keep-alive --restart unless-stopped keep-alive"
    exit 1
fi

if [ "$CONTAINER_RUNNING" -eq 0 ]; then
    echo "Container '${CONTAINER_NAME}' exists but is not running. Starting it..."
    podman start "$CONTAINER_NAME"
    echo "Waiting for container to initialize..."
    sleep 3
fi

echo "Container '${CONTAINER_NAME}' is running."

# --- Patch the script into the container ---

echo "Copying patched keep-alive script into container..."
echo "$KEEP_ALIVE_SCRIPT" | podman exec -i "$CONTAINER_NAME" sh -c "cat > ${SCRIPT_PATH} && chmod +x ${SCRIPT_PATH}"

# --- Kill existing processes first ---
# Must happen before installing the wrapper, since stress-ng can't be
# overwritten while it's running ("Text file busy" error).

echo "Stopping existing keep-alive processes inside container..."
# Kill any previously patched script instances (not PID 1)
podman exec "$CONTAINER_NAME" sh -c '
    for pid in $(pgrep -f "keep-alive.sh" | grep -v "^1$"); do
        kill "$pid" 2>/dev/null
    done
' || true

# Kill child processes of the original CMD loop
podman exec "$CONTAINER_NAME" sh -c '
    kill $(pgrep -f "stress-ng" | grep -v "^1$") 2>/dev/null
    kill $(pgrep -f "curl.*oracle") 2>/dev/null
    kill $(pgrep -f "sleep 2") 2>/dev/null
' || true

echo "Waiting for processes to exit..."
sleep 3

# --- Neutralize PID 1's CMD loop ---
# PID 1 can't be killed without stopping the container. Instead, we replace
# stress-ng with a wrapper that only runs the real binary when called from
# our patched script (identified by KEEP_ALIVE_PATCHED=1 env var).
# PID 1's loop will call the wrapper, get a no-op, and harmlessly idle.

echo "Installing stress-ng wrapper to neutralize PID 1 loop..."
podman exec "$CONTAINER_NAME" sh -c '
    REAL_PATH=$(which stress-ng)
    # Only rename if not already wrapped
    if [ ! -f "${REAL_PATH}.real" ]; then
        cp "$REAL_PATH" "${REAL_PATH}.real"
    fi
    cat > "$REAL_PATH" <<WRAPPER
#!/bin/sh
if [ "\$KEEP_ALIVE_PATCHED" = "1" ]; then
    exec $(which stress-ng).real "\$@"
else
    # Called from PID 1 original CMD — do nothing
    exit 0
fi
WRAPPER
    chmod +x "$REAL_PATH"
'

# --- Start the patched script ---

echo "Starting patched keep-alive script inside container..."
podman exec -d "$CONTAINER_NAME" sh -c "${SCRIPT_PATH}"

# --- Verify ---

sleep 2
echo ""
echo "=== Container process list ==="
podman exec "$CONTAINER_NAME" ps aux
echo ""

# Check that our patched script is actually running
if podman exec "$CONTAINER_NAME" pgrep -f "keep-alive.sh" > /dev/null 2>&1; then
    echo "SUCCESS: Patched keep-alive script is running."
else
    echo "WARNING: Patched keep-alive script does not appear to be running."
    echo "Check container logs: podman logs ${CONTAINER_NAME}"
    exit 1
fi
