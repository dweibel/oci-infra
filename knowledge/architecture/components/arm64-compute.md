---
type: Architecture Component
id: OCI-ARM64-COMPUTE
title: ARM64 Compute Infrastructure
status: implemented
---

# ARM64 Compute Infrastructure

## Overview

ARM64-based compute infrastructure using OCI's VM.Standard.A1.Flex shape to leverage the Always Free tier while providing reliable compute resources for development and agentic systems.

## Architecture

### Compute Shape
- **Shape**: VM.Standard.A1.Flex
- **OCPUs**: 4 (Always Free maximum)
- **Memory**: 24 GB (Always Free maximum)
- **Architecture**: ARM64

### Instance Configuration
- **Boot Volume**: 100 GB
- **Image**: Oracle Linux 8 ARM64
- **Networking**: Public subnet with security lists
- **Storage**: Persistent block volumes for workspace data

### Key Features
1. **Cost Optimization**: Leverages OCI Always Free tier
2. **Resilience**: Automated retry across availability domains
3. **Persistence**: Workspace data survives instance terminations
4. **Automation**: Terraform-managed provisioning

## Implementation

- **Terraform Module**: `terraform/modules/oci-compute/`
- **Retry Logic**: `scripts/oci-instance-retry.sh`
- **Configuration**: Enforced through Terraform validation rules

## Constraints

- **Availability Domain Restrictions**: ARM64 capacity may be limited in some domains
- **Performance Characteristics**: ARM64 architecture requires compatible software
- **Regional Availability**: Some regions may have limited ARM64 availability

## Dependencies

- **Network Infrastructure**: Requires VCN and subnet configuration
- **Security Lists**: Appropriate ingress/egress rules
- **Block Volumes**: Persistent storage for workspace data

## Verification

Component tests verify:
1. Instance provisioning succeeds
2. ARM64 architecture is enforced
3. Persistent storage attaches correctly
4. Automated retry logic functions

## Status

**Implemented and Operational** - This component is actively used for development infrastructure.