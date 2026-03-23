#!/bin/bash
# OCI Always Free Instance Creation Retry Script (v2 - OCI CLI based)
#
# Uses OCI CLI directly instead of terraform for much faster retry cycles.
# Tries all 3 ADs in rapid succession, then sleeps before the next round.
# Once the instance is running, updates terraform.tfvars and imports into state.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
STATE_FILE="${SCRIPT_DIR}/.oci-retry-state"
LOG_FILE="${SCRIPT_DIR}/oci-retry.log"

# OCI Configuration
COMPARTMENT_ID="ocid1.compartment.oc1..aaaaaaaauehbyd5gast7s6w65igxfjmhw5uyuwpkiox73yhzulcbh7roz3xa"
DISPLAY_NAME="agent-coder-dev-vm"
SHAPE="VM.Standard.A1.Flex"
OCPUS=4
MEMORY_GB=24
BOOT_VOLUME_SIZE_GB=150
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7i///uMbqYyZth4kXSnX0vnJ9LE0LALwLJA2PwOla8 dirk@Dirk-Laptop"

# Workspace volume
WORKSPACE_VOLUME_SIZE_GB=50
WORKSPACE_VOLUME_NAME="agent-coder-dev-workspace-volume"

# Retry timing
SLEEP_BETWEEN_ROUNDS=20  # seconds between full AD rotation rounds

# Availability domains (us-ashburn-1)
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

# Get the latest Oracle Linux ARM64 image
get_image_id() {
    oci compute image list \
        --compartment-id "${COMPARTMENT_ID}" \
        --operating-system "Oracle Linux" \
        --operating-system-version "8" \
        --shape "${SHAPE}" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[0].id' \
        --raw-output 2>/dev/null
}

# Get subnet ID
get_subnet_id() {
    oci network subnet list \
        --compartment-id "${COMPARTMENT_ID}" \
        --query 'data[?"display-name" | contains(@, `agent-coder`)]."id" | [0]' \
        --raw-output 2>/dev/null || echo ""
}

# Ensure network infrastructure exists (create via terraform if missing)
ensure_network() {
    local subnet_id
    subnet_id=$(get_subnet_id)

    if [[ -n "${subnet_id}" ]] && [[ "${subnet_id}" != "null" ]] && [[ "${subnet_id}" != "None" ]]; then
        echo "${subnet_id}"
        return 0
    fi

    log "INFO" "${BLUE}Network not found, creating via terraform...${NC}"
    cd "${TERRAFORM_DIR}"

    if [[ ! -d ".terraform" ]]; then
        log "INFO" "Initializing terraform..."
        terraform init >> "${LOG_FILE}" 2>&1
    fi

    if terraform apply -auto-approve -target=module.network >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Network created.${NC}"
    else
        log "ERROR" "${RED}Failed to create network. Check ${LOG_FILE}${NC}"
        return 1
    fi

    # Re-fetch subnet ID
    subnet_id=$(get_subnet_id)
    if [[ -z "${subnet_id}" ]] || [[ "${subnet_id}" == "null" ]] || [[ "${subnet_id}" == "None" ]]; then
        log "ERROR" "${RED}Subnet still not found after terraform apply${NC}"
        return 1
    fi

    echo "${subnet_id}"
}

# Check if a running instance already exists
find_existing_instance() {
    oci compute instance list \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${DISPLAY_NAME}" \
        --lifecycle-state RUNNING \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo ""
}

# Check for any non-terminated instance (PROVISIONING, STARTING, etc.)
find_pending_instance() {
    oci compute instance list \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${DISPLAY_NAME}" \
        --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].{id:id,state:"lifecycle-state"}' \
        2>/dev/null || echo ""
}

# Try to launch an instance in a specific AD
try_launch() {
    local ad=$1
    local image_id=$2
    local subnet_id=$3
    local cloud_init_file=$4

    log "INFO" "  Trying ${ad}..."

    # Write SSH key to temp file (OCI CLI needs a real file path)
    local ssh_key_file="${SCRIPT_DIR}/.ssh-key-tmp"
    echo "${SSH_PUBLIC_KEY}" > "${ssh_key_file}"

    # Base64-encode cloud-init for --metadata
    local user_data_b64
    user_data_b64=$(base64 -w 0 "${cloud_init_file}")

    local result
    result=$(oci compute instance launch \
        --compartment-id "${COMPARTMENT_ID}" \
        --availability-domain "${ad}" \
        --display-name "${DISPLAY_NAME}" \
        --shape "${SHAPE}" \
        --shape-config "{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY_GB}}" \
        --image-id "${image_id}" \
        --subnet-id "${subnet_id}" \
        --assign-public-ip true \
        --boot-volume-size-in-gbs "${BOOT_VOLUME_SIZE_GB}" \
        --ssh-authorized-keys-file "${ssh_key_file}" \
        --metadata "{\"user_data\": \"${user_data_b64}\"}" \
        --freeform-tags '{"Project":"agent-coder","Environment":"dev","ManagedBy":"terraform"}' \
        --query 'data.id' \
        --raw-output 2>&1) || true

    rm -f "${ssh_key_file}"

    # Check if it's an OCID (success) or error text
    if [[ "${result}" == ocid1.instance.* ]]; then
        echo "${result}"
        return 0
    fi

    # Check for capacity error (expected, not worth logging as error)
    if echo "${result}" | grep -qi "out of host capacity\|out of capacity\|InternalError\|LimitExceeded"; then
        log "INFO" "  ${YELLOW}No capacity in ${ad}${NC}"
    else
        log "WARN" "  ${YELLOW}Unexpected error in ${ad}: ${result}${NC}"
    fi

    return 1
}

# Wait for instance to reach RUNNING state
wait_for_running() {
    local instance_id=$1
    local max_wait=300  # 5 minutes
    local elapsed=0

    log "INFO" "Waiting for instance to reach RUNNING state..."

    while [[ ${elapsed} -lt ${max_wait} ]]; do
        local state
        state=$(oci compute instance get \
            --instance-id "${instance_id}" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null || echo "UNKNOWN")

        if [[ "${state}" == "RUNNING" ]]; then
            return 0
        elif [[ "${state}" == "TERMINATED" ]] || [[ "${state}" == "TERMINATING" ]]; then
            log "ERROR" "${RED}Instance entered ${state} state${NC}"
            return 1
        fi

        log "INFO" "  State: ${state} (${elapsed}s elapsed)"
        sleep 15
        elapsed=$((elapsed + 15))
    done

    log "WARN" "${YELLOW}Timed out waiting for RUNNING state${NC}"
    return 1
}

# Create workspace block volume in the same AD as the instance
create_workspace_volume() {
    local ad=$1

    # Check if volume already exists
    local existing
    existing=$(oci bv volume list \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${WORKSPACE_VOLUME_NAME}" \
        --query 'data[?"lifecycle-state"==`AVAILABLE`].id | [0]' \
        --raw-output 2>/dev/null || echo "")

    if [[ -n "${existing}" ]] && [[ "${existing}" != "null" ]]; then
        # Check if it's in the right AD
        local vol_ad
        vol_ad=$(oci bv volume get \
            --volume-id "${existing}" \
            --query 'data."availability-domain"' \
            --raw-output 2>/dev/null || echo "")

        if [[ "${vol_ad}" == "${ad}" ]]; then
            log "INFO" "Workspace volume already exists in ${ad}: ${existing}"
            echo "${existing}"
            return 0
        else
            log "INFO" "Existing volume in wrong AD (${vol_ad}), creating new one in ${ad}..."
        fi
    fi

    log "INFO" "Creating workspace volume in ${ad}..."
    local volume_id
    volume_id=$(oci bv volume create \
        --compartment-id "${COMPARTMENT_ID}" \
        --availability-domain "${ad}" \
        --display-name "${WORKSPACE_VOLUME_NAME}" \
        --size-in-gbs "${WORKSPACE_VOLUME_SIZE_GB}" \
        --freeform-tags '{"Project":"agent-coder","Environment":"dev","ManagedBy":"terraform"}' \
        --wait-for-state AVAILABLE \
        --query 'data.id' \
        --raw-output 2>/dev/null) || {
        log "ERROR" "${RED}Failed to create workspace volume${NC}"
        return 1
    }

    log "INFO" "${GREEN}Workspace volume created: ${volume_id}${NC}"
    echo "${volume_id}"
}

# Attach workspace volume to instance
attach_workspace_volume() {
    local instance_id=$1
    local volume_id=$2

    log "INFO" "Attaching workspace volume..."
    oci compute volume-attachment attach-paravirtualized-volume \
        --instance-id "${instance_id}" \
        --volume-id "${volume_id}" \
        --display-name "agent-coder-dev-workspace-attachment" \
        --wait-for-state ATTACHED \
        >> "${LOG_FILE}" 2>&1 || {
        log "WARN" "${YELLOW}Volume attachment failed (may already be attached)${NC}"
    }
}

# Update terraform.tfvars and import resources into state
sync_to_terraform() {
    local instance_id=$1
    local ad=$2
    local volume_id=$3

    log "INFO" "${BLUE}Syncing to terraform state...${NC}"

    cd "${TERRAFORM_DIR}"

    # Update terraform.tfvars with the successful AD
    sed -i.bak "s|^availability_domain[[:space:]]*=.*|availability_domain = \"${ad}\"|" terraform.tfvars
    log "INFO" "Updated terraform.tfvars with AD: ${ad}"

    # Initialize terraform if needed
    if [[ ! -d ".terraform" ]]; then
        terraform init >> "${LOG_FILE}" 2>&1
    fi

    # Import instance into state (ignore errors if already in state)
    log "INFO" "Importing instance into terraform state..."
    terraform import module.compute.oci_core_instance.main "${instance_id}" >> "${LOG_FILE}" 2>&1 || \
        log "INFO" "Instance may already be in state (ok)"

    # Import volume if we have one
    if [[ -n "${volume_id}" ]]; then
        log "INFO" "Importing workspace volume into terraform state..."
        terraform import module.compute.oci_core_volume.workspace "${volume_id}" >> "${LOG_FILE}" 2>&1 || \
            log "INFO" "Volume may already be in state (ok)"
    fi

    # Run a full apply to create/sync remaining resources (logging, monitoring, network)
    log "INFO" "Running terraform apply to sync remaining infrastructure..."
    if terraform apply -auto-approve >> "${LOG_FILE}" 2>&1; then
        log "INFO" "${GREEN}Terraform sync complete.${NC}"
    else
        log "WARN" "${YELLOW}Terraform apply had issues. Review log and run manually if needed.${NC}"
    fi
}

# Generate cloud-init from the terraform template
generate_cloud_init() {
    local cloud_init_file="${SCRIPT_DIR}/.cloud-init-generated.yaml"

    # Read the template and substitute variables
    sed \
        -e 's/${aws_region}/us-east-1/g' \
        -e 's/${ecr_registry}/830364544979.dkr.ecr.us-east-1.amazonaws.com/g' \
        -e 's/${s3_bucket}/agent-coder-workspace-830364544979/g' \
        -e 's/${bedrock_model_id}/anthropic.claude-3-5-sonnet-20241022-v2:0/g' \
        -e 's/${log_format}/json/g' \
        -e 's/${app_port}/8080/g' \
        -e 's/${max_iterations}/10/g' \
        -e 's/${iteration_timeout}/300/g' \
        -e 's|${workspace_mount_path}|/mnt/workspace|g' \
        "${TERRAFORM_DIR}/modules/oci-compute/cloud-init.yaml" > "${cloud_init_file}"

    echo "${cloud_init_file}"
}

main() {
    rm -f "${LOG_FILE}"

    log "INFO" "=== OCI Instance Retry Script (v2 - OCI CLI) ==="
    log "INFO" "Shape: ${SHAPE} (ARM64), OCPUs: ${OCPUS}, Memory: ${MEMORY_GB}GB"
    log "INFO" "Strategy: try all 3 ADs per round, sleep ${SLEEP_BETWEEN_ROUNDS}s between rounds"

    # Prerequisites
    if ! command -v oci &> /dev/null; then
        log "ERROR" "${RED}OCI CLI not installed${NC}"
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        log "ERROR" "${RED}jq not installed${NC}"
        exit 1
    fi

    # Check for existing running instance
    local existing_id
    existing_id=$(find_existing_instance)
    if [[ -n "${existing_id}" ]] && [[ "${existing_id}" != "null" ]]; then
        local ip
        ip=$(oci compute instance list-vnics \
            --instance-id "${existing_id}" \
            --query 'data[0]."public-ip"' \
            --raw-output 2>/dev/null || echo "N/A")
        log "INFO" "${GREEN}Instance already running: ${existing_id}${NC}"
        log "INFO" "${GREEN}Public IP: ${ip}${NC}"
        log "INFO" "${GREEN}SSH: ssh -i ~/.ssh/oci_agent_coder opc@${ip}${NC}"
        exit 0
    fi

    # Check for pending instance (provisioning, starting, etc.)
    local pending
    pending=$(find_pending_instance)
    if [[ -n "${pending}" ]] && [[ "${pending}" != "null" ]] && [[ "${pending}" != "" ]]; then
        local pending_id pending_state
        pending_id=$(echo "${pending}" | jq -r '.id')
        pending_state=$(echo "${pending}" | jq -r '.state')
        log "INFO" "Found instance in ${pending_state} state: ${pending_id}"
        log "INFO" "Waiting for it to finish..."
        if wait_for_running "${pending_id}"; then
            log "INFO" "${GREEN}Instance is now running.${NC}"
            exit 0
        fi
        log "WARN" "${YELLOW}Pending instance didn't reach RUNNING, continuing with retry...${NC}"
    fi

    # Resolve image and subnet once (these don't change between attempts)
    log "INFO" "Resolving image ID..."
    local image_id
    image_id=$(get_image_id)
    if [[ -z "${image_id}" ]] || [[ "${image_id}" == "null" ]]; then
        log "ERROR" "${RED}Could not find Oracle Linux ARM64 image${NC}"
        exit 1
    fi
    log "INFO" "Image: ${image_id}"

    log "INFO" "Resolving subnet ID..."
    local subnet_id
    subnet_id=$(ensure_network)
    if [[ -z "${subnet_id}" ]] || [[ "${subnet_id}" == "null" ]]; then
        log "ERROR" "${RED}Could not resolve subnet${NC}"
        exit 1
    fi
    log "INFO" "Subnet: ${subnet_id}"

    # Generate cloud-init
    log "INFO" "Generating cloud-init..."
    local cloud_init_file
    cloud_init_file=$(generate_cloud_init)

    local round=0

    while true; do
        round=$((round + 1))
        log "INFO" "${BLUE}=== Round #${round} ===${NC}"

        # Try all 3 ADs in quick succession
        for ad in "${ADS[@]}"; do
            # Re-check before each attempt to avoid duplicates
            existing_id=$(find_existing_instance)
            if [[ -n "${existing_id}" ]] && [[ "${existing_id}" != "null" ]]; then
                log "INFO" "${GREEN}Instance now running (possibly from earlier attempt): ${existing_id}${NC}"
                local ip
                ip=$(oci compute instance list-vnics \
                    --instance-id "${existing_id}" \
                    --query 'data[0]."public-ip"' \
                    --raw-output 2>/dev/null || echo "N/A")
                log "INFO" "${GREEN}Public IP: ${ip}${NC}"
                rm -f "${STATE_FILE}" "${cloud_init_file}"
                exit 0
            fi

            local instance_id
            instance_id=$(try_launch "${ad}" "${image_id}" "${subnet_id}" "${cloud_init_file}" || true)

            if [[ -n "${instance_id}" ]] && [[ "${instance_id}" == ocid1.instance.* ]]; then
                log "INFO" "${GREEN}Instance launched in ${ad}: ${instance_id}${NC}"

                if wait_for_running "${instance_id}"; then
                    local ip
                    ip=$(oci compute instance list-vnics \
                        --instance-id "${instance_id}" \
                        --query 'data[0]."public-ip"' \
                        --raw-output 2>/dev/null || echo "N/A")

                    log "INFO" "${GREEN}=== SUCCESS ===${NC}"
                    log "INFO" "${GREEN}Instance ID: ${instance_id}${NC}"
                    log "INFO" "${GREEN}Public IP:   ${ip}${NC}"
                    log "INFO" "${GREEN}AD:          ${ad}${NC}"
                    log "INFO" "${GREEN}SSH:         ssh -i ~/.ssh/oci_agent_coder opc@${ip}${NC}"

                    # Create and attach workspace volume
                    local volume_id
                    volume_id=$(create_workspace_volume "${ad}" || echo "")

                    if [[ -n "${volume_id}" ]] && [[ "${volume_id}" != "null" ]]; then
                        attach_workspace_volume "${instance_id}" "${volume_id}"
                    fi

                    # Sync everything to terraform
                    sync_to_terraform "${instance_id}" "${ad}" "${volume_id}"

                    # Cleanup
                    rm -f "${STATE_FILE}" "${cloud_init_file}"

                    exit 0
                else
                    log "WARN" "${YELLOW}Instance launched but didn't reach RUNNING${NC}"
                fi
            fi
        done

        log "INFO" "No capacity in any AD. Sleeping ${SLEEP_BETWEEN_ROUNDS}s... (Ctrl+C to stop)"
        sleep "${SLEEP_BETWEEN_ROUNDS}"
    done
}

trap 'log "INFO" "${YELLOW}Script interrupted${NC}"; rm -f "${SCRIPT_DIR}/.cloud-init-generated.yaml" "${SCRIPT_DIR}/.ssh-key-tmp"; exit 130' INT TERM

main "$@"
