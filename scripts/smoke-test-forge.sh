#!/bin/bash
set -euo pipefail

# Smoke test for the Forge task execution API.
# Submits a minimal task, polls for completion, and verifies end-to-end functionality.
#
# Usage:
#   ./scripts/smoke-test-forge.sh                          # run on instance
#   ssh oci-agent 'bash -s' < scripts/smoke-test-forge.sh  # run remotely
#
# Prerequisites:
#   - Forge container running (see scripts/deploy-forge.sh)
#   - /mnt/workspace/forge/.env contains FORGE_API_KEY
#   - curl and jq installed

BASE_URL="http://localhost:3100"
ENV_FILE="/mnt/workspace/forge/.env"
POLL_INTERVAL=2
TIMEOUT=60

echo "=== Forge Smoke Test ==="
echo "Target: $BASE_URL"
echo ""

# ─── Read API key from .env ────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found"
    echo "Run setup-forge-dirs.sh and populate the .env file first."
    exit 1
fi

API_KEY=$(grep -E '^FORGE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2-)

if [ -z "${API_KEY:-}" ]; then
    echo "ERROR: FORGE_API_KEY not found or empty in $ENV_FILE"
    exit 1
fi

echo "API key loaded from $ENV_FILE"

# ─── Submit task ───────────────────────────────────────────────────────────────

echo -n "Submitting task... "

RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 \
    -X POST "$BASE_URL/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d '{
        "description": "echo hello world",
        "context": "Smoke test task — execute a simple echo command.",
        "toolConstraints": ["bash"],
        "contextBoundaries": []
    }' 2>/dev/null) || true

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# Forge returns 201 for accepted tasks
if [ "$HTTP_CODE" != "201" ]; then
    echo "FAILED"
    echo "ERROR: Task submission returned HTTP $HTTP_CODE (expected 201)"
    echo "Response body: $BODY"
    exit 1
fi

TASK_ID=$(echo "$BODY" | jq -r '.taskId // empty')

if [ -z "$TASK_ID" ]; then
    echo "FAILED"
    echo "ERROR: No taskId in response body"
    echo "Response body: $BODY"
    exit 1
fi

echo "OK (task $TASK_ID)"

# ─── Poll for terminal state ──────────────────────────────────────────────────

echo -n "Polling status"

START_TIME=$(date +%s)

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo ""
        echo "ERROR: Task $TASK_ID did not reach terminal state within ${TIMEOUT}s"
        echo "Last status: ${STATUS:-unknown}"
        exit 1
    fi

    STATUS_RESPONSE=$(curl -s --max-time 5 \
        -H "Authorization: Bearer $API_KEY" \
        "$BASE_URL/tasks/$TASK_ID/status" 2>/dev/null) || true

    STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status // empty')

    case "$STATUS" in
        completed)
            echo ""
            echo "SUCCESS: Task $TASK_ID completed"
            exit 0
            ;;
        failed)
            echo ""
            ERROR_MSG=$(echo "$STATUS_RESPONSE" | jq -r '.error.message // "unknown error"')
            ERROR_CAT=$(echo "$STATUS_RESPONSE" | jq -r '.error.category // "unknown"')
            echo "FAILED: Task $TASK_ID failed"
            echo "  Category: $ERROR_CAT"
            echo "  Reason:   $ERROR_MSG"
            exit 1
            ;;
        accepted|running)
            echo -n "."
            sleep "$POLL_INTERVAL"
            ;;
        *)
            echo ""
            echo "ERROR: Unexpected status '$STATUS' for task $TASK_ID"
            echo "Response: $STATUS_RESPONSE"
            exit 1
            ;;
    esac
done
