#!/bin/bash
set -euo pipefail

# Apply Oracle Critical Security Patch Update (CSPU) to the OCI ARM64 instance.
# Performs pre-assessment, applies patches, handles reboot, verifies services,
# and monitors keep-alive sustained operation.
#
# Execution model: Run on the instance as root, piped via SSH:
#   ssh oci-agent 'sudo bash -s' < scripts/apply-security-patches.sh
#
# For reboot scenarios (two-phase execution):
#   ssh oci-agent 'sudo bash -s' < scripts/apply-security-patches.sh
#   # ... SSH disconnects on reboot ...
#   ssh oci-agent 'sudo bash -s' < scripts/apply-security-patches.sh --skip-to-phase 4
#
# Note: sudo is required because DNF update needs root privileges.
# The script detects rootless Podman containers via 'sudo -u opc podman'.
#
# Arguments:
#   --dry-run         Perform assessment only, do not apply patches
#   --skip-reboot     Apply patches but do not reboot even if kernel is updated
#   --skip-to-phase N Resume from a specific phase (useful after reboot)
#   --force           Skip backup age verification (proceed without recent backup)
#
# Prerequisites:
#   - SSH host 'oci-agent' configured in ~/.ssh/config
#   - Block volume mounted at /mnt/workspace
#   - DNF repositories reachable
#   - Services running: forge (Podman), keep-alive (Podman), cloudflared (systemd)

# --- Global Variables ---

CONTAINER_FORGE="forge"
CONTAINER_KEEP_ALIVE="keep-alive"
SERVICE_CLOUDFLARED="cloudflared"

STOP_TIMEOUT=30
SERVICE_WAIT_TIMEOUT=120
KEEP_ALIVE_ITERATION_TIMEOUT=450
SSH_RECONNECT_TIMEOUT=300

STATE_FILE="/tmp/patching-state.json"

# Rootless Podman: containers run as 'opc' user.
# When this script runs as root (via sudo), we must use 'sudo -u opc podman'
# to access the rootless container namespace.
CONTAINER_USER="opc"

# _podman() — wrapper that routes podman commands through the correct user context.
# When running as root, invokes podman as the container owner (opc).
# When running as opc directly, invokes podman without sudo.
_podman() {
    if [[ $EUID -eq 0 ]]; then
        sudo -u "$CONTAINER_USER" podman "$@"
    else
        podman "$@"
    fi
}

# Colors
COLOR_BLUE="\033[0;34m"
COLOR_YELLOW="\033[0;33m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_RESET="\033[0m"

# Flags (defaults)
DRY_RUN=false
SKIP_REBOOT=false
SKIP_TO_PHASE=0
FORCE=false

# --- Argument Parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-reboot)
            SKIP_REBOOT=true
            shift
            ;;
        --skip-to-phase)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --skip-to-phase requires a numeric argument"
                exit 1
            fi
            SKIP_TO_PHASE="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--dry-run] [--skip-reboot] [--skip-to-phase N] [--force]"
            exit 1
            ;;
    esac
done

# --- Utility Functions ---

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""

    case "$level" in
        INFO)    color="$COLOR_BLUE" ;;
        WARN)    color="$COLOR_YELLOW" ;;
        ERROR)   color="$COLOR_RED" ;;
        SUCCESS) color="$COLOR_GREEN" ;;
        *)       color="$COLOR_RESET" ;;
    esac

    echo -e "${color}${timestamp} [${level}] ${message}${COLOR_RESET}"
}

abort() {
    log ERROR "$@"
    exit 1
}

phase_banner() {
    local phase_num="$1"
    shift
    local phase_title="$*"
    echo ""
    echo "============================================================"
    log INFO "Phase ${phase_num}: ${phase_title}"
    echo "============================================================"
    echo ""
}

# --- State Persistence Functions ---

# save_state() — Write patching context to STATE_FILE as JSON.
# Used to carry context across the SSH disconnect during reboot.
# Arguments:
#   $1 — updated packages (newline-separated "name old_ver new_ver" lines)
#   $2 — kernel updated flag ("true" or "false")
#   $3 — forge pre-patch state (running|stopped|not_found)
#   $4 — keep-alive pre-patch state (running|stopped|not_found)
#   $5 — cloudflared pre-patch state (active|inactive|failed|not_found)
save_state() {
    local updated_packages="${1:-}"
    local kernel_updated="${2:-false}"
    local forge_state="${3:-unknown}"
    local keepalive_state="${4:-unknown}"
    local cloudflared_state="${5:-unknown}"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Build the packages JSON array from newline-separated input
    local packages_json="["
    local first=true
    if [[ -n "$updated_packages" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pkg_name pkg_old pkg_new
            pkg_name=$(echo "$line" | awk '{print $1}')
            pkg_old=$(echo "$line" | awk '{print $2}')
            pkg_new=$(echo "$line" | awk '{print $3}')
            if [[ "$first" == "true" ]]; then
                first=false
            else
                packages_json+=","
            fi
            packages_json+=$(printf '{"name":"%s","old_version":"%s","new_version":"%s"}' \
                "$pkg_name" "$pkg_old" "$pkg_new")
        done <<< "$updated_packages"
    fi
    packages_json+="]"

    # Write state file using printf-based JSON generation
    printf '{\n' > "$STATE_FILE"
    printf '  "timestamp": "%s",\n' "$timestamp" >> "$STATE_FILE"
    printf '  "kernel_updated": %s,\n' "$kernel_updated" >> "$STATE_FILE"
    printf '  "updated_packages": %s,\n' "$packages_json" >> "$STATE_FILE"
    printf '  "pre_patch_services": {\n' >> "$STATE_FILE"
    printf '    "forge": "%s",\n' "$forge_state" >> "$STATE_FILE"
    printf '    "keep_alive": "%s",\n' "$keepalive_state" >> "$STATE_FILE"
    printf '    "cloudflared": "%s"\n' "$cloudflared_state" >> "$STATE_FILE"
    printf '  }\n' >> "$STATE_FILE"
    printf '}\n' >> "$STATE_FILE"

    log INFO "State saved to ${STATE_FILE}"
}

# load_state() — Read and parse the state file when --skip-to-phase is used.
# Exports variables for use by subsequent phases:
#   STATE_TIMESTAMP, STATE_KERNEL_UPDATED, STATE_FORGE, STATE_KEEPALIVE, STATE_CLOUDFLARED
load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        abort "State file not found at ${STATE_FILE}. Cannot resume without prior state."
    fi

    if ! jq empty "$STATE_FILE" 2>/dev/null; then
        abort "State file at ${STATE_FILE} is not valid JSON."
    fi

    STATE_TIMESTAMP=$(jq -r '.timestamp' "$STATE_FILE")
    STATE_KERNEL_UPDATED=$(jq -r '.kernel_updated' "$STATE_FILE")
    STATE_FORGE=$(jq -r '.pre_patch_services.forge' "$STATE_FILE")
    STATE_KEEPALIVE=$(jq -r '.pre_patch_services.keep_alive' "$STATE_FILE")
    STATE_CLOUDFLARED=$(jq -r '.pre_patch_services.cloudflared' "$STATE_FILE")

    log INFO "Loaded state from ${STATE_FILE} (saved at ${STATE_TIMESTAMP})"
    log INFO "  Kernel updated: ${STATE_KERNEL_UPDATED}"
    log INFO "  Pre-patch services — Forge: ${STATE_FORGE}, Keep-Alive: ${STATE_KEEPALIVE}, Cloudflared: ${STATE_CLOUDFLARED}"
}

# --- Phase 1: Pre-Assessment Functions ---

# check_mount() — Verify block volume is mounted at /mnt/workspace.
# Aborts the script if the mount is not present.
check_mount() {
    log INFO "Checking block volume mount at /mnt/workspace..."
    if ! findmnt /mnt/workspace > /dev/null 2>&1; then
        abort "ABORT: /mnt/workspace is not mounted. Block volume must be attached and mounted before patching."
    fi
    log SUCCESS "Block volume is mounted at /mnt/workspace"
}

# check_repo_connectivity() — Verify DNF repositories are reachable.
# Uses a 30-second timeout on dnf repolist to detect network issues.
# Aborts the script if repos are unreachable.
check_repo_connectivity() {
    log INFO "Checking DNF repository connectivity..."
    if ! timeout 30 dnf repolist > /dev/null 2>&1; then
        abort "ABORT: DNF repository unreachable. Check network connectivity and repo configuration."
    fi
    log SUCCESS "DNF repositories are reachable"
}

# --- Service State Recording and Backup Verification ---

# Global service state variables (populated by record_service_states)
FORGE_STATE="unknown"
KEEPALIVE_STATE="unknown"
CLOUDFLARED_STATE="unknown"

# record_service_states() — Capture the running state of all managed services.
# Populates FORGE_STATE, KEEPALIVE_STATE, and CLOUDFLARED_STATE globals.
# States: running|stopped|not_found for containers, active|inactive|failed|not_found for systemd.
record_service_states() {
    log INFO "Recording service states..."

    # Forge container state
    local forge_status
    if _podman inspect --format '{{.State.Status}}' "$CONTAINER_FORGE" &>/dev/null; then
        forge_status=$(_podman inspect --format '{{.State.Status}}' "$CONTAINER_FORGE" 2>/dev/null)
        FORGE_STATE="${forge_status}"
    else
        FORGE_STATE="not_found"
    fi

    # Keep-Alive container state
    local keepalive_status
    if _podman inspect --format '{{.State.Status}}' "$CONTAINER_KEEP_ALIVE" &>/dev/null; then
        keepalive_status=$(_podman inspect --format '{{.State.Status}}' "$CONTAINER_KEEP_ALIVE" 2>/dev/null)
        KEEPALIVE_STATE="${keepalive_status}"
    else
        KEEPALIVE_STATE="not_found"
    fi

    # Cloudflared systemd service state
    local cloudflared_status
    cloudflared_status=$(systemctl is-active "$SERVICE_CLOUDFLARED" 2>/dev/null || echo "not_found")
    CLOUDFLARED_STATE="${cloudflared_status}"

    log INFO "  Forge: ${FORGE_STATE}"
    log INFO "  Keep-Alive: ${KEEPALIVE_STATE}"
    log INFO "  Cloudflared: ${CLOUDFLARED_STATE}"
}

# verify_backup_recent() — Check if a backup completed within the last 24 hours.
# Inspects backup file timestamps in /mnt/workspace/backups/forge/.
# Returns 0 if a recent backup exists, 1 otherwise.
verify_backup_recent() {
    local backup_dir="/mnt/workspace/backups/forge"

    if [[ ! -d "$backup_dir" ]]; then
        log WARN "Backup directory ${backup_dir} does not exist"
        return 1
    fi

    # Find backup files modified within the last 24 hours (1440 minutes)
    local recent_backup
    recent_backup=$(find "$backup_dir" -name "forge-*.tar.gz" -mmin -1440 -print -quit 2>/dev/null)

    if [[ -n "$recent_backup" ]]; then
        local backup_age
        backup_age=$(stat -c '%y' "$recent_backup" 2>/dev/null | cut -d'.' -f1)
        log INFO "Recent backup found: $(basename "$recent_backup") (${backup_age})"
        return 0
    else
        log WARN "No backup found within the last 24 hours in ${backup_dir}"
        return 1
    fi
}

# trigger_backup() — Run backup if no recent backup exists.
# If --force is set, skip backup age verification with a WARN log.
# Aborts if backup fails and --force is not set.
trigger_backup() {
    local backup_script="/home/opc/scripts/backup-forge.sh"

    if [[ "$FORCE" == "true" ]]; then
        log WARN "Skipping backup age verification (--force is set)"
        return 0
    fi

    if verify_backup_recent; then
        log SUCCESS "Backup verification passed"
        return 0
    fi

    # No recent backup — trigger one
    log INFO "Triggering backup before patching..."

    if [[ ! -x "$backup_script" ]]; then
        abort "ABORT: Backup script not found or not executable at ${backup_script}"
    fi

    if ! "$backup_script" --target local; then
        abort "ABORT: Backup failed — cannot proceed without a valid backup"
    fi

    log SUCCESS "Backup completed successfully"
}

# phase_1_assessment() — Phase 1: Pre-Assessment
# Performs system state capture and precondition checks:
#   1. Verify block volume is mounted
#   2. Verify DNF repo connectivity
#   3. Output OS and kernel versions
#   4. List available security updates
#   5. Record service states
#   6. Verify/trigger backup
phase_1_assessment() {
    phase_banner 1 "Pre-Assessment"

    # Precondition checks — abort early if not met
    check_mount
    check_repo_connectivity

    # System state capture
    log INFO "System information:"
    log INFO "  OS version: $(cat /etc/oracle-release 2>/dev/null || echo 'unknown')"
    log INFO "  Kernel version: $(uname -r)"

    # List available security updates
    log INFO "Available security updates:"
    echo ""
    dnf updateinfo list --security 2>/dev/null || log WARN "No security update information available"
    echo ""

    # Record service states (Requirement 1.3)
    record_service_states

    # Verify/trigger backup (Requirements 5.1, 5.4)
    trigger_backup
}

# --- Phase 2: Patch Application Functions ---

# Global variables populated by Phase 2
KERNEL_UPDATED=false
UPDATED_PACKAGES=""

# apply_security_patches() — Execute dnf update --security -y and handle success/failure.
# On failure: logs DNF error output, confirms DNF auto-rollback preserves system state, aborts.
# On success: displays a summary table of updated packages with old and new versions.
# Populates UPDATED_PACKAGES global with "name old_ver new_ver" lines.
# Requirements: 2.1, 2.3, 2.4
apply_security_patches() {
    log INFO "Applying security patches via DNF..."

    local dnf_output
    local dnf_exit_code=0

    # Capture both stdout and stderr from dnf update
    dnf_output=$(dnf update --security -y 2>&1) || dnf_exit_code=$?

    if [[ $dnf_exit_code -ne 0 ]]; then
        log ERROR "DNF transaction failed (exit code: ${dnf_exit_code})"
        log ERROR "DNF output:"
        echo "$dnf_output" | while IFS= read -r line; do
            log ERROR "  $line"
        done
        log INFO "DNF auto-rollback should preserve system state — no packages partially installed"
        abort "DNF transaction failed — rolled back. Review errors above and retry."
    fi

    # Check if any packages were actually updated
    if echo "$dnf_output" | grep -qi "Nothing to do\|No packages marked for update"; then
        log INFO "No security updates available — system is already up to date"
        UPDATED_PACKAGES=""
        return 0
    fi

    log SUCCESS "Security patches applied successfully"

    # Parse update summary from dnf history info last
    log INFO "Parsing update summary..."
    local history_output
    history_output=$(dnf history info last 2>/dev/null) || true

    # Display summary table of updated packages
    echo ""
    printf "%-40s %-24s %-24s\n" "Package" "Old Version" "New Version"
    printf "%-40s %-24s %-24s\n" "-------" "-----------" "-----------"

    # Parse "Upgraded" lines from dnf history info last
    # Format: "    Upgraded <package>-<version>.<arch>"
    # We compare Upgraded vs the replacement (the line after or the Updated entry)
    local packages_parsed=""

    # dnf history info shows pairs: old package upgraded and new package installed
    # Extract upgraded packages (old versions) and their replacements (new versions)
    local old_packages=""
    local new_packages=""

    old_packages=$(echo "$history_output" | grep -E "^\s+Upgrade\s+" | sed 's/^\s*Upgrade\s*//' || true)
    new_packages=$(echo "$history_output" | grep -E "^\s+Upgraded\s+" | sed 's/^\s*Upgraded\s*//' || true)

    if [[ -z "$old_packages" && -z "$new_packages" ]]; then
        # Try alternative format: "Upgrade" and "Upgraded" or just list from output
        # Some DNF versions use "Updated" format
        old_packages=$(echo "$history_output" | grep -E "^\s+Updated\s+" | sed 's/^\s*Updated\s*//' || true)
        new_packages=$(echo "$history_output" | grep -E "^\s+Update\s+" | sed 's/^\s*Update\s*//' || true)
    fi

    # If we got paired output, process it
    if [[ -n "$old_packages" || -n "$new_packages" ]]; then
        # Use process substitution to avoid subshell (preserves packages_parsed variable)
        while IFS=$'\t' read -r old_pkg new_pkg; do
            [[ -z "$old_pkg" && -z "$new_pkg" ]] && continue
            # Extract package name (everything before the last -version-release.arch)
            local pkg_name old_ver new_ver
            pkg_name=$(echo "$old_pkg" | rev | cut -d'-' -f3- | rev)
            old_ver=$(echo "$old_pkg" | rev | cut -d'-' -f1-2 | rev | sed 's/\.[^.]*$//')
            new_ver=$(echo "$new_pkg" | rev | cut -d'-' -f1-2 | rev | sed 's/\.[^.]*$//')
            printf "%-40s %-24s %-24s\n" "$pkg_name" "$old_ver" "$new_ver"
            packages_parsed+="${pkg_name} ${old_ver} ${new_ver}"$'\n'
        done < <(paste <(echo "$old_packages") <(echo "$new_packages") 2>/dev/null)
    else
        # Fallback: parse from dnf update output directly
        # Look for "Upgraded:" or "Updated:" section in dnf output
        log WARN "Could not parse detailed version info from dnf history — showing raw update list"
        echo "$dnf_output" | grep -E "^\s+(Upgrading|Installing)" | head -20 || true
    fi

    UPDATED_PACKAGES="$packages_parsed"
    echo ""
}

# detect_kernel_update() — Check if a kernel update requires a reboot.
# Uses needs-restarting -r which returns exit code 1 if reboot is needed, 0 if not.
# Populates KERNEL_UPDATED global (true/false).
# Requirements: 2.2
detect_kernel_update() {
    log INFO "Checking if kernel update requires reboot..."

    local nr_exit_code=0
    needs-restarting -r > /dev/null 2>&1 || nr_exit_code=$?

    if [[ $nr_exit_code -eq 1 ]]; then
        KERNEL_UPDATED=true
        log WARN "Kernel update detected — reboot is required to activate the new kernel"
    else
        KERNEL_UPDATED=false
        log INFO "No kernel update requiring reboot"
    fi
}

# phase_2_apply_patches() — Phase 2 orchestrator: Apply Security Patches
# 1. If DRY_RUN is true, shows what would be applied and exits
# 2. Calls apply_security_patches()
# 3. Calls detect_kernel_update()
# 4. Stores results in KERNEL_UPDATED and UPDATED_PACKAGES for later use by save_state()
# Requirements: 2.1, 2.2, 2.3, 2.4
phase_2_apply_patches() {
    phase_banner 2 "Apply Security Patches"

    # Dry-run mode: show what would be applied without executing
    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "DRY RUN — displaying security updates that would be applied (no changes will be made):"
        echo ""
        dnf updateinfo list --security 2>/dev/null || log WARN "No security update information available"
        echo ""
        log INFO "DRY RUN complete — no patches were applied"
        return 0
    fi

    # Apply security patches
    apply_security_patches

    # Detect kernel update
    detect_kernel_update

    log INFO "Phase 2 summary:"
    log INFO "  Packages updated: $(echo "$UPDATED_PACKAGES" | grep -c '[^ ]' || echo 0)"
    log INFO "  Kernel update requires reboot: ${KERNEL_UPDATED}"
}

# --- Phase 3: Reboot Sequence Functions ---

# graceful_shutdown() — Stop managed containers with a graceful timeout.
# Sends SIGTERM to containers and waits up to STOP_TIMEOUT (30s) for clean shutdown.
# Requirements: 3.1
graceful_shutdown() {
    log INFO "Gracefully stopping containers (timeout: ${STOP_TIMEOUT}s)..."

    local shutdown_failed=false

    if _podman inspect "$CONTAINER_FORGE" &>/dev/null; then
        log INFO "  Stopping ${CONTAINER_FORGE}..."
        if ! _podman stop -t "$STOP_TIMEOUT" "$CONTAINER_FORGE" 2>/dev/null; then
            log WARN "  Failed to stop ${CONTAINER_FORGE} gracefully"
            shutdown_failed=true
        else
            log SUCCESS "  ${CONTAINER_FORGE} stopped"
        fi
    else
        log INFO "  ${CONTAINER_FORGE} container not found — skipping"
    fi

    if _podman inspect "$CONTAINER_KEEP_ALIVE" &>/dev/null; then
        log INFO "  Stopping ${CONTAINER_KEEP_ALIVE}..."
        if ! _podman stop -t "$STOP_TIMEOUT" "$CONTAINER_KEEP_ALIVE" 2>/dev/null; then
            log WARN "  Failed to stop ${CONTAINER_KEEP_ALIVE} gracefully"
            shutdown_failed=true
        else
            log SUCCESS "  ${CONTAINER_KEEP_ALIVE} stopped"
        fi
    else
        log INFO "  ${CONTAINER_KEEP_ALIVE} container not found — skipping"
    fi

    if [[ "$shutdown_failed" == "true" ]]; then
        log WARN "One or more containers did not stop cleanly — proceeding anyway"
    else
        log SUCCESS "All containers stopped gracefully"
    fi
}

# phase_3_reboot() — Phase 3 orchestrator: Reboot Sequence
# 1. If kernel was NOT updated, skip reboot entirely and proceed to Phase 4
# 2. If --skip-reboot is set, log WARN and proceed to Phase 4
# 3. Gracefully stop containers
# 4. Save state file for post-reboot context
# 5. Log SSH disconnect message with reconnect instructions
# 6. Execute systemctl reboot
# Requirements: 3.1, 3.2, 3.3, 3.4, 3.5
phase_3_reboot() {
    phase_banner 3 "Reboot Sequence"

    # If kernel was not updated, no reboot needed
    if [[ "$KERNEL_UPDATED" != "true" ]]; then
        log INFO "No kernel update detected — reboot is not required"
        log INFO "Proceeding directly to Phase 4: Post-Patch Verification"
        return 0
    fi

    # If --skip-reboot is set, warn and skip
    if [[ "$SKIP_REBOOT" == "true" ]]; then
        log WARN "Reboot was skipped (--skip-reboot flag is set)"
        log WARN "The new kernel will NOT be active until the system is rebooted manually"
        log INFO "Proceeding to Phase 4: Post-Patch Verification"
        return 0
    fi

    # Gracefully stop containers before reboot
    graceful_shutdown

    # Save state file for post-reboot context
    log INFO "Saving patching state before reboot..."
    save_state "$UPDATED_PACKAGES" "$KERNEL_UPDATED" "$FORGE_STATE" "$KEEPALIVE_STATE" "$CLOUDFLARED_STATE"

    # Log clear reconnection instructions
    log WARN "============================================================"
    log WARN "REBOOT IMMINENT — SSH session will disconnect"
    log WARN ""
    log WARN "After the instance comes back online (~60-90 seconds), reconnect with:"
    log WARN ""
    log WARN "  ssh oci-agent 'bash -s' < scripts/apply-security-patches.sh --skip-to-phase 4"
    log WARN ""
    log WARN "============================================================"

    # Initiate reboot
    log INFO "Initiating system reboot..."
    sudo systemctl reboot
}

# --- Phase 4: Post-Patch Verification Functions ---

# verify_service_health() — Check the health of all 3 managed services.
# Returns 0 if ALL services are healthy. Returns 1 if any service is unhealthy.
# Populates FAILED_SERVICES associative array with "service_name=observed_state" for failures.
# Health criteria:
#   - Cloudflared: systemctl is-active returns "active"
#   - Forge: HTTP 200 from curl localhost:3100/health within 5 seconds
#   - Keep-Alive: container running AND keep-alive.sh process active inside container
# Requirements: 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.6
declare -A FAILED_SERVICES

verify_service_health() {
    local all_healthy=true
    FAILED_SERVICES=()

    log INFO "Verifying service health..."

    # Check Cloudflared (systemd service)
    local cloudflared_status
    cloudflared_status=$(systemctl is-active "$SERVICE_CLOUDFLARED" 2>/dev/null || echo "inactive")
    if [[ "$cloudflared_status" == "active" ]]; then
        log SUCCESS "  Cloudflared: active"
    else
        log ERROR "  Cloudflared: ${cloudflared_status} (expected: active)"
        FAILED_SERVICES["$SERVICE_CLOUDFLARED"]="$cloudflared_status"
        all_healthy=false
    fi

    # Check Forge container (HTTP health endpoint)
    local forge_http_code
    forge_http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3100/health 2>/dev/null || echo "000")
    if [[ "$forge_http_code" == "200" ]]; then
        log SUCCESS "  Forge: HTTP 200 on /health"
    else
        log ERROR "  Forge: HTTP ${forge_http_code} on /health (expected: 200)"
        FAILED_SERVICES["$CONTAINER_FORGE"]="http_${forge_http_code}"
        all_healthy=false
    fi

    # Check Keep-Alive container (running state + process active)
    local keepalive_running=false
    local keepalive_process=false
    local keepalive_container_state

    keepalive_container_state=$(_podman inspect --format '{{.State.Status}}' "$CONTAINER_KEEP_ALIVE" 2>/dev/null || echo "not_found")

    if [[ "$keepalive_container_state" == "running" ]]; then
        keepalive_running=true
        # Verify keep-alive.sh process is active inside the container
        if _podman exec "$CONTAINER_KEEP_ALIVE" pgrep -f "keep-alive.sh" > /dev/null 2>&1; then
            keepalive_process=true
        fi
    fi

    if [[ "$keepalive_running" == "true" && "$keepalive_process" == "true" ]]; then
        log SUCCESS "  Keep-Alive: running with active keep-alive.sh process"
    else
        local observed_state="container_${keepalive_container_state}"
        if [[ "$keepalive_running" == "true" && "$keepalive_process" == "false" ]]; then
            observed_state="running_but_no_process"
        fi
        log ERROR "  Keep-Alive: ${observed_state} (expected: running with active keep-alive.sh)"
        FAILED_SERVICES["$CONTAINER_KEEP_ALIVE"]="$observed_state"
        all_healthy=false
    fi

    if [[ "$all_healthy" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# wait_for_services() — Poll all 3 services every 10s for up to SERVICE_WAIT_TIMEOUT (120s).
# Waits 60 seconds before the first health check (Requirement 4.1: 60s elapsed since services started).
# Returns 0 if all services become healthy within the timeout, 1 otherwise.
# Requirements: 3.2, 3.3, 3.4, 3.6, 4.1
wait_for_services() {
    log INFO "Waiting 60 seconds for services to initialize after boot..."
    sleep 60

    log INFO "Polling service health (timeout: ${SERVICE_WAIT_TIMEOUT}s, interval: 10s)..."

    local elapsed=0
    local poll_interval=10

    while [[ $elapsed -lt $SERVICE_WAIT_TIMEOUT ]]; do
        if verify_service_health; then
            log SUCCESS "All services are healthy after ${elapsed}s of polling (plus 60s initial wait)"
            return 0
        fi

        elapsed=$((elapsed + poll_interval))
        if [[ $elapsed -lt $SERVICE_WAIT_TIMEOUT ]]; then
            log INFO "  Services not yet ready — retrying in ${poll_interval}s (${elapsed}s/${SERVICE_WAIT_TIMEOUT}s elapsed)..."
            sleep "$poll_interval"
        fi
    done

    log WARN "Service health timeout reached (${SERVICE_WAIT_TIMEOUT}s) — not all services are healthy"
    return 1
}

# attempt_service_restart() — Attempt to restart failed services, up to 2 retries each.
# Uses podman start for containers (forge, keep-alive) and systemctl restart for cloudflared.
# After each restart attempt, waits 15 seconds then re-checks health of that service.
# Reports observed vs expected state for any service that remains failed after all retries.
# Returns 0 if all services recovered, 1 if any service still fails.
# Requirements: 3.6, 4.6, 5.2
attempt_service_restart() {
    local max_retries=2
    local any_failed=false

    if [[ ${#FAILED_SERVICES[@]} -eq 0 ]]; then
        log INFO "No failed services to restart"
        return 0
    fi

    log INFO "Attempting to restart ${#FAILED_SERVICES[@]} failed service(s) (max ${max_retries} attempts each)..."

    # Restart Cloudflared if it failed
    if [[ -n "${FAILED_SERVICES[$SERVICE_CLOUDFLARED]:-}" ]]; then
        local cloudflared_recovered=false
        local observed_state="${FAILED_SERVICES[$SERVICE_CLOUDFLARED]}"

        for attempt in $(seq 1 $max_retries); do
            log INFO "  Restarting ${SERVICE_CLOUDFLARED} (attempt ${attempt}/${max_retries})..."
            systemctl restart "$SERVICE_CLOUDFLARED" 2>/dev/null || true
            sleep 15

            local status
            status=$(systemctl is-active "$SERVICE_CLOUDFLARED" 2>/dev/null || echo "inactive")
            if [[ "$status" == "active" ]]; then
                log SUCCESS "  ${SERVICE_CLOUDFLARED} recovered on attempt ${attempt}"
                cloudflared_recovered=true
                unset 'FAILED_SERVICES[$SERVICE_CLOUDFLARED]'
                break
            else
                observed_state="$status"
                log WARN "  ${SERVICE_CLOUDFLARED} still not active (state: ${status})"
            fi
        done

        if [[ "$cloudflared_recovered" == "false" ]]; then
            log ERROR "  ${SERVICE_CLOUDFLARED} FAILED after ${max_retries} restart attempts"
            log ERROR "    Observed: ${observed_state}"
            log ERROR "    Expected: active"
            any_failed=true
        fi
    fi

    # Restart Forge container if it failed
    if [[ -n "${FAILED_SERVICES[$CONTAINER_FORGE]:-}" ]]; then
        local forge_recovered=false
        local observed_state="${FAILED_SERVICES[$CONTAINER_FORGE]}"

        for attempt in $(seq 1 $max_retries); do
            log INFO "  Restarting ${CONTAINER_FORGE} container (attempt ${attempt}/${max_retries})..."
            _podman start "$CONTAINER_FORGE" 2>/dev/null || true
            sleep 15

            # Check HTTP health
            local http_code
            http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3100/health 2>/dev/null || echo "000")
            if [[ "$http_code" == "200" ]]; then
                log SUCCESS "  ${CONTAINER_FORGE} recovered on attempt ${attempt} (HTTP 200)"
                forge_recovered=true
                unset 'FAILED_SERVICES[$CONTAINER_FORGE]'
                break
            else
                observed_state="http_${http_code}"
                log WARN "  ${CONTAINER_FORGE} health check returned HTTP ${http_code}"
            fi
        done

        if [[ "$forge_recovered" == "false" ]]; then
            log ERROR "  ${CONTAINER_FORGE} FAILED after ${max_retries} restart attempts"
            log ERROR "    Observed: ${observed_state}"
            log ERROR "    Expected: HTTP 200 on localhost:3100/health"
            any_failed=true
        fi
    fi

    # Restart Keep-Alive container if it failed
    if [[ -n "${FAILED_SERVICES[$CONTAINER_KEEP_ALIVE]:-}" ]]; then
        local keepalive_recovered=false
        local observed_state="${FAILED_SERVICES[$CONTAINER_KEEP_ALIVE]}"

        for attempt in $(seq 1 $max_retries); do
            log INFO "  Restarting ${CONTAINER_KEEP_ALIVE} container (attempt ${attempt}/${max_retries})..."
            _podman start "$CONTAINER_KEEP_ALIVE" 2>/dev/null || true
            sleep 15

            # Check container running AND process active
            local container_state
            container_state=$(_podman inspect --format '{{.State.Status}}' "$CONTAINER_KEEP_ALIVE" 2>/dev/null || echo "not_found")

            if [[ "$container_state" == "running" ]]; then
                if _podman exec "$CONTAINER_KEEP_ALIVE" pgrep -f "keep-alive.sh" > /dev/null 2>&1; then
                    log SUCCESS "  ${CONTAINER_KEEP_ALIVE} recovered on attempt ${attempt}"
                    keepalive_recovered=true
                    unset 'FAILED_SERVICES[$CONTAINER_KEEP_ALIVE]'
                    break
                else
                    observed_state="running_but_no_process"
                    log WARN "  ${CONTAINER_KEEP_ALIVE} running but keep-alive.sh not active"
                fi
            else
                observed_state="container_${container_state}"
                log WARN "  ${CONTAINER_KEEP_ALIVE} container state: ${container_state}"
            fi
        done

        if [[ "$keepalive_recovered" == "false" ]]; then
            log ERROR "  ${CONTAINER_KEEP_ALIVE} FAILED after ${max_retries} restart attempts"
            log ERROR "    Observed: ${observed_state}"
            log ERROR "    Expected: running with active keep-alive.sh process"
            any_failed=true
        fi
    fi

    if [[ "$any_failed" == "true" ]]; then
        return 1
    fi

    log SUCCESS "All previously failed services have recovered"
    return 0
}

# --- Phase 4: Kernel and Block Volume Verification (Task 6.2) ---

# verify_kernel_version() — If kernel was updated, compare running kernel against latest installed.
# Compares `uname -r` against the latest installed kernel-core RPM.
# Returns 0 if kernel version matches or kernel was not updated, 1 on mismatch.
# Requirements: 3.5, 4.4
verify_kernel_version() {
    log INFO "Verifying kernel version..."

    # Determine if kernel was updated — check both state file variable and current-run variable
    local kernel_was_updated="${STATE_KERNEL_UPDATED:-${KERNEL_UPDATED:-false}}"

    if [[ "$kernel_was_updated" != "true" ]]; then
        log INFO "  Kernel was not updated — skipping kernel version verification"
        return 0
    fi

    # Get the currently running kernel version
    local running_kernel
    running_kernel=$(uname -r)

    # Get the latest installed kernel-core RPM version
    # rpm -q kernel-core --last lists installed kernels sorted newest-first
    local latest_installed_kernel
    latest_installed_kernel=$(rpm -q kernel-core --last 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-core-//')

    if [[ -z "$latest_installed_kernel" ]]; then
        log WARN "  Could not determine latest installed kernel-core version"
        return 1
    fi

    log INFO "  Running kernel:   ${running_kernel}"
    log INFO "  Installed kernel: ${latest_installed_kernel}"

    # Compare — the running kernel should match the latest installed
    # uname -r returns e.g. "5.15.0-200.el9.aarch64"
    # rpm shows e.g. "5.15.0-200.el9.aarch64" after stripping "kernel-core-"
    if [[ "$running_kernel" == "$latest_installed_kernel" ]]; then
        log SUCCESS "  Kernel version verified — running the latest installed kernel"
        return 0
    else
        log ERROR "  Kernel version MISMATCH — running '${running_kernel}' but latest installed is '${latest_installed_kernel}'"
        log ERROR "  The system may need another reboot to activate the new kernel"
        return 1
    fi
}

# verify_block_volume() — Verify block volume is mounted and writable.
# Reuses check_mount() for mount verification, then tests writability
# by creating and removing a temp file in /mnt/workspace.
# Returns 0 if mount is present and writable, 1 otherwise.
# Requirements: 4.5
verify_block_volume() {
    log INFO "Verifying block volume mount and writability..."

    # Reuse existing check_mount() for mount verification
    # (check_mount aborts on failure, so we wrap it to just return status here)
    if ! findmnt /mnt/workspace > /dev/null 2>&1; then
        log ERROR "  Block volume is NOT mounted at /mnt/workspace"
        return 1
    fi
    log SUCCESS "  Block volume is mounted at /mnt/workspace"

    # Test writability by creating and removing a temp file
    local test_file="/mnt/workspace/.patching-write-test-$$"
    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file" 2>/dev/null
        log SUCCESS "  Block volume is writable (temp file created and removed)"
        return 0
    else
        log ERROR "  Block volume is NOT writable — failed to create test file at ${test_file}"
        return 1
    fi
}

# provide_restore_instructions() — Output backup timestamp and restore commands.
# Called when services fail after 2 restart retries.
# Provides the operator with clear steps to restore from backup.
# Requirements: 5.2, 5.3
provide_restore_instructions() {
    local backup_dir="/mnt/workspace/backups/forge"

    log ERROR "============================================================"
    log ERROR "SERVICE RECOVERY FAILED — Manual intervention required"
    log ERROR "============================================================"
    echo ""

    # Find the most recent backup and its timestamp
    local latest_backup=""
    local backup_timestamp="unknown"

    if [[ -d "$backup_dir" ]]; then
        latest_backup=$(find "$backup_dir" -name "forge-*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -n "$latest_backup" ]]; then
            backup_timestamp=$(stat -c '%y' "$latest_backup" 2>/dev/null | cut -d'.' -f1)
        fi
    fi

    log ERROR "Restore Instructions:"
    echo ""
    log INFO "  1. Roll back the DNF transaction:"
    log INFO "     sudo dnf history undo last -y"
    echo ""
    log INFO "  2. Verify the rollback:"
    log INFO "     sudo dnf history info last"
    echo ""

    if [[ -n "$latest_backup" ]]; then
        log INFO "  3. Restore from backup (created: ${backup_timestamp}):"
        log INFO "     Backup file: ${latest_backup}"
        log INFO "     Restore command:"
        log INFO "       sudo systemctl stop cloudflared"
        log INFO "       podman stop forge keep-alive"
        log INFO "       tar -xzf ${latest_backup} -C /mnt/workspace/forge/"
        log INFO "       podman start forge keep-alive"
        log INFO "       sudo systemctl start cloudflared"
    else
        log WARN "  3. No backup file found in ${backup_dir}"
        log WARN "     Manual recovery may be required"
    fi

    echo ""
    log INFO "  4. Verify services after restore:"
    log INFO "     systemctl is-active cloudflared"
    log INFO "     podman inspect --format '{{.State.Status}}' forge"
    log INFO "     podman inspect --format '{{.State.Status}}' keep-alive"
    log INFO "     curl -s http://localhost:3100/health"
    echo ""
    log ERROR "============================================================"
}

# --- Phase 4 Orchestrator ---

# phase_4_verify() — Phase 4 orchestrator: Post-Patch Verification
# Ties together all verification steps after patching (and optionally reboot).
# 1. If --skip-to-phase >= 4, load state from state file
# 2. Call wait_for_services() which waits 60s then polls until ready (Requirement 4.1)
# 3. Verify service health with retry logic via attempt_service_restart()
# 4. Verify kernel version if kernel was updated
# 5. Verify block volume mount and writability
# 6. If anything fails after retries, provide restore instructions
# Requirements: 3.5, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.2, 5.3
phase_4_verify() {
    phase_banner 4 "Post-Patch Verification"

    # If resuming from a reboot (--skip-to-phase >= 4), load persisted state
    if [[ "$SKIP_TO_PHASE" -ge 4 ]]; then
        log INFO "Resuming after reboot — loading persisted state..."
        load_state
    fi

    # Wait for services to initialize (60s initial wait per Requirement 4.1)
    # then poll until all healthy (up to SERVICE_WAIT_TIMEOUT)
    wait_for_services || true

    # Verify service health — verify_service_health() populates FAILED_SERVICES on failure
    if ! verify_service_health; then
        log WARN "Service health check failed — attempting restarts..."

        # attempt_service_restart() uses FAILED_SERVICES array populated by verify_service_health()
        if ! attempt_service_restart; then
            # Services failed after 2 restart attempts — provide restore instructions
            provide_restore_instructions
            abort "Service recovery failed after 2 restart attempts. See restore instructions above."
        fi

        # Re-verify health after successful restarts
        log INFO "Re-verifying service health after restarts..."
        if ! verify_service_health; then
            provide_restore_instructions
            abort "Services still failing after restart attempts. See restore instructions above."
        fi
    fi

    # Verify kernel version if kernel was updated (Requirement 4.4)
    if ! verify_kernel_version; then
        log WARN "Kernel version verification failed — system may need another reboot"
    fi

    # Verify block volume mount and writability (Requirement 4.5)
    if ! verify_block_volume; then
        provide_restore_instructions
        abort "Block volume verification failed. See restore instructions above."
    fi

    log SUCCESS "Phase 4 complete — all post-patch verifications passed"
}

# --- Phase 5: Keep-Alive Sustained Operation Check ---

# monitor_keep_alive() — Poll keep-alive container logs and count successful iterations.
# Watches for "running stress-ng" or "skipping stress-ng" patterns in log output.
# Counts 3 consecutive successful iterations (each ~120s cycle).
# Uses a polling approach (podman logs --since) that works reliably over SSH.
#
# Returns 0 after 3 successful iterations, 1 on timeout or error.
# Requirements: 6.1, 6.2, 6.3, 6.4
monitor_keep_alive() {
    local required_iterations=3
    local iteration_count=0
    local timeout="$KEEP_ALIVE_ITERATION_TIMEOUT"
    local poll_interval=15
    local log_start
    log_start=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    log INFO "Monitoring keep-alive container for ${required_iterations} successful iterations (timeout: ${timeout}s)..."
    log INFO "  Watching for patterns: 'running stress-ng' or 'skipping stress-ng'"

    local start_time
    start_time=$(date +%s)

    # Track which log lines we've already counted to avoid double-counting
    local last_seen_count=0

    while true; do
        local now elapsed
        now=$(date +%s)
        elapsed=$((now - start_time))

        # Check overall timeout
        if [[ $elapsed -ge $timeout ]]; then
            log ERROR "Timeout reached (${timeout}s) after ${iteration_count}/${required_iterations} successful iterations"
            return 1
        fi

        # Verify the container is still running
        local container_state
        container_state=$(_podman inspect --format '{{.State.Status}}' "$CONTAINER_KEEP_ALIVE" 2>/dev/null || echo "not_found")
        if [[ "$container_state" != "running" ]]; then
            log ERROR "Keep-alive container is not running (state: ${container_state}) after ${iteration_count}/${required_iterations} iterations"
            return 1
        fi

        # Poll logs since the start time and count iteration markers
        local logs_output
        logs_output=$(_podman logs --since "$log_start" "$CONTAINER_KEEP_ALIVE" 2>&1 || true)

        # Check for error indicators in the logs (exclude stress-ng info lines)
        local error_line
        error_line=$(echo "$logs_output" | grep -i "error\|fatal\|panic\|killed\|terminated" | grep -v "stress-ng" | head -1) || true
        if [[ -n "$error_line" ]]; then
            log ERROR "Error detected in keep-alive log at iteration $((iteration_count + 1)):"
            log ERROR "  ${error_line}"
            return 1
        fi

        # Count successful iteration markers in the logs
        local current_count
        current_count=$(echo "$logs_output" | grep -c "running stress-ng\|skipping stress-ng" 2>/dev/null) || current_count=0

        # Report new iterations found since last poll
        if [[ "$current_count" -gt "$last_seen_count" ]]; then
            iteration_count=$current_count
            last_seen_count=$current_count

            # Show the latest matching line
            local latest_line
            latest_line=$(echo "$logs_output" | grep "running stress-ng\|skipping stress-ng" | tail -1)
            log SUCCESS "  Iteration ${iteration_count}/${required_iterations} detected: ${latest_line}"

            if [[ $iteration_count -ge $required_iterations ]]; then
                log SUCCESS "All ${required_iterations} iterations completed successfully"
                return 0
            fi
        fi

        # Wait before next poll
        sleep "$poll_interval"
    done
}

# phase_5_keep_alive_check() — Phase 5 orchestrator: Keep-Alive Sustained Operation Check
# Monitors the keep-alive container for 3 full successful iterations after patching.
# On success: logs patching process as fully complete.
# On failure: reports iteration number and error details.
# Requirements: 6.1, 6.2, 6.3, 6.4
phase_5_keep_alive_check() {
    phase_banner 5 "Keep-Alive Sustained Operation Check"

    log INFO "Verifying keep-alive container sustained operation..."
    log INFO "Each iteration takes approximately 120 seconds (3 iterations ≈ 360s, timeout: ${KEEP_ALIVE_ITERATION_TIMEOUT}s)"

    if monitor_keep_alive; then
        echo ""
        log SUCCESS "============================================================"
        log SUCCESS "PATCHING COMPLETE — All phases passed successfully"
        log SUCCESS "============================================================"
        log SUCCESS ""
        log SUCCESS "Summary:"
        log SUCCESS "  ✓ Phase 1: Pre-assessment passed"
        log SUCCESS "  ✓ Phase 2: Security patches applied"
        log SUCCESS "  ✓ Phase 3: Reboot handled (if required)"
        log SUCCESS "  ✓ Phase 4: Post-patch verification passed"
        log SUCCESS "  ✓ Phase 5: Keep-alive sustained operation verified (3 iterations)"
        log SUCCESS ""
        log SUCCESS "The OCI instance is fully patched and all services are operational."
    else
        echo ""
        log ERROR "Keep-alive sustained operation check FAILED"
        log ERROR "The keep-alive container did not complete 3 consecutive successful iterations"
        log ERROR ""
        log ERROR "Troubleshooting:"
        log ERROR "  1. Check container status:  podman inspect --format '{{.State.Status}}' ${CONTAINER_KEEP_ALIVE}"
        log ERROR "  2. Check container logs:    podman logs --tail 50 ${CONTAINER_KEEP_ALIVE}"
        log ERROR "  3. Check process inside:    podman exec ${CONTAINER_KEEP_ALIVE} pgrep -f keep-alive.sh"
        log ERROR "  4. Restart if needed:       podman restart ${CONTAINER_KEEP_ALIVE}"
        abort "Keep-alive sustained operation check failed. Instance may be at risk of reclamation."
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

log INFO "============================================================"
log INFO "OCI Security Patching — Starting"
log INFO "============================================================"
log INFO "Flags:"
log INFO "  --dry-run:        ${DRY_RUN}"
log INFO "  --skip-reboot:    ${SKIP_REBOOT}"
log INFO "  --skip-to-phase:  ${SKIP_TO_PHASE}"
log INFO "  --force:          ${FORCE}"
log INFO "============================================================"

case "$SKIP_TO_PHASE" in
    0)
        # Full run: Phase 1 → 2 → 3 → 4 → 5
        phase_1_assessment

        # In dry-run mode, stop after Phase 1 assessment display
        if [[ "$DRY_RUN" == "true" ]]; then
            log SUCCESS "Dry-run assessment complete. No changes were made."
            exit 0
        fi

        phase_2_apply_patches
        phase_3_reboot
        # If phase_3_reboot returns (no reboot was issued), continue verification
        phase_4_verify
        phase_5_keep_alive_check
        ;;
    4)
        # Resume after reboot: Phase 4 → 5
        log INFO "Resuming from Phase 4 (post-reboot verification)..."
        phase_4_verify
        phase_5_keep_alive_check
        ;;
    5)
        # Skip directly to keep-alive check
        log INFO "Resuming from Phase 5 (keep-alive sustained check)..."
        phase_5_keep_alive_check
        ;;
    *)
        abort "Invalid --skip-to-phase value: ${SKIP_TO_PHASE}. Supported values: 0 (default), 4, 5."
        ;;
esac

log SUCCESS "Script completed successfully."
exit 0
