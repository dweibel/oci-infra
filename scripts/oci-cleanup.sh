#!/bin/bash
# OCI Infrastructure Cleanup Script
# Destroys all OCI resources across all 3 availability domains
# Handles the unified agent config → log dependency ordering that causes 409 conflicts

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
LOG_FILE="${SCRIPT_DIR}/oci-cleanup.log"

# OCI Configuration
COMPARTMENT_ID="ocid1.compartment.oc1..aaaaaaaauehbyd5gast7s6w65igxfjmhw5uyuwpkiox73yhzulcbh7roz3xa"

ADS=(
    "fBMf:US-ASHBURN-AD-1"
    "fBMf:US-ASHBURN-AD-2"
    "fBMf:US-ASHBURN-AD-3"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] $@" | tee -a "${LOG_FILE}"
}

cleanup_stale_lock() {
    log "INFO" "Checking for stale terraform locks..."
    local plan_output
    plan_output=$(terraform plan -no-color 2>&1 || true)

    if echo "${plan_output}" | grep -q "Error acquiring the state lock"; then
        local lock_id
        lock_id=$(echo "${plan_output}" | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1)
        if [[ -n "${lock_id}" ]]; then
            log "WARN" "${YELLOW}Found stale lock: ${lock_id}, removing...${NC}"
            terraform force-unlock -force "${lock_id}" 2>&1 | tee -a "${LOG_FILE}"
        fi
    fi
}

# Destroy the unified agent config first to avoid 409 on log deletion
destroy_agent_config() {
    log "INFO" "${BLUE}Phase 1: Destroying unified agent configuration...${NC}"

    local uma_in_state
    uma_in_state=$(terraform state list 2>/dev/null | grep "unified_agent_configuration" || true)

    if [[ -z "${uma_in_state}" ]]; then
        log "INFO" "No unified agent configuration in state, skipping."
        return 0
    fi

    if terraform destroy -auto-approve \
        -target=module.logging.oci_logging_unified_agent_configuration.main \
        >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Unified agent configuration destroyed.${NC}"
    else
        log "WARN" "${YELLOW}Failed to destroy agent config via terraform, trying OCI CLI...${NC}"
        destroy_agent_config_via_cli
    fi
}

destroy_agent_config_via_cli() {
    local configs
    configs=$(oci logging agent-configuration list \
        --compartment-id "${COMPARTMENT_ID}" \
        --all \
        --query 'data[?"lifecycle-state"!=`DELETED`].id' \
        --raw-output 2>/dev/null || echo "[]")

    if [[ "${configs}" == "[]" ]] || [[ -z "${configs}" ]]; then
        log "INFO" "No agent configurations found via CLI."
        return 0
    fi

    echo "${configs}" | jq -r '.[]' | while read -r config_id; do
        log "INFO" "Deleting agent config: ${config_id}"
        oci logging agent-configuration delete \
            --unified-agent-configuration-id "${config_id}" \
            --force \
            --wait-for-state SUCCEEDED 2>&1 | tee -a "${LOG_FILE}" || true
    done
}

# Destroy logging resources (logs, log groups, dynamic groups, policies)
destroy_logging() {
    log "INFO" "${BLUE}Phase 2: Destroying logging resources...${NC}"

    local logging_resources
    logging_resources=$(terraform state list 2>/dev/null | grep "module.logging" || true)

    if [[ -z "${logging_resources}" ]]; then
        log "INFO" "No logging resources in state, skipping."
        return 0
    fi

    if terraform destroy -auto-approve \
        -target=module.logging \
        >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Logging resources destroyed.${NC}"
    else
        log "WARN" "${YELLOW}Terraform destroy of logging failed, trying individual resources...${NC}"
        for resource in \
            "module.logging.oci_identity_policy.logging" \
            "module.logging.oci_logging_log.app" \
            "module.logging.oci_logging_log_group.main" \
            "module.logging.oci_identity_dynamic_group.instance"; do

            if terraform state list 2>/dev/null | grep -q "${resource}"; then
                log "INFO" "Destroying ${resource}..."
                terraform destroy -auto-approve -target="${resource}" >> "${LOG_FILE}" 2>&1 || \
                    log "WARN" "${YELLOW}Failed to destroy ${resource}, will clean up via CLI${NC}"
            fi
        done
    fi
}

# Destroy compute resources (volume attachment, volume, instance)
destroy_compute() {
    log "INFO" "${BLUE}Phase 3: Destroying compute resources...${NC}"

    local compute_resources
    compute_resources=$(terraform state list 2>/dev/null | grep "module.compute" || true)

    if [[ -z "${compute_resources}" ]]; then
        log "INFO" "No compute resources in state, skipping."
        return 0
    fi

    if terraform destroy -auto-approve \
        -target=module.compute \
        >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Compute resources destroyed.${NC}"
    else
        log "WARN" "${YELLOW}Terraform destroy of compute failed, trying individual resources...${NC}"
        for resource in \
            "module.compute.oci_core_volume_attachment.workspace" \
            "module.compute.oci_core_volume.workspace" \
            "module.compute.oci_core_instance.main"; do

            if terraform state list 2>/dev/null | grep -q "${resource}"; then
                log "INFO" "Destroying ${resource}..."
                terraform destroy -auto-approve -target="${resource}" >> "${LOG_FILE}" 2>&1 || \
                    log "WARN" "${YELLOW}Failed to destroy ${resource}${NC}"
            fi
        done
    fi
}

# Destroy monitoring resources
destroy_monitoring() {
    log "INFO" "${BLUE}Phase 4: Destroying monitoring resources...${NC}"

    local monitoring_resources
    monitoring_resources=$(terraform state list 2>/dev/null | grep "module.monitoring" || true)

    if [[ -z "${monitoring_resources}" ]]; then
        log "INFO" "No monitoring resources in state, skipping."
        return 0
    fi

    if terraform destroy -auto-approve \
        -target=module.monitoring \
        >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Monitoring resources destroyed.${NC}"
    else
        log "WARN" "${YELLOW}Terraform destroy of monitoring module failed${NC}"
    fi
}

# Destroy network resources
destroy_network() {
    log "INFO" "${BLUE}Phase 5: Destroying network resources...${NC}"

    local network_resources
    network_resources=$(terraform state list 2>/dev/null | grep "module.network" || true)

    if [[ -z "${network_resources}" ]]; then
        log "INFO" "No network resources in state, skipping."
        return 0
    fi

    if terraform destroy -auto-approve \
        -target=module.network \
        >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Network resources destroyed.${NC}"
    else
        log "WARN" "${YELLOW}Terraform destroy of network module failed${NC}"
    fi
}