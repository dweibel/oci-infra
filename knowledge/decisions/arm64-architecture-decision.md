---
type: Architecture Decision
id: ADR-001-ARM64
title: Use ARM64 Architecture for Cost Optimization
status: accepted
context: Infrastructure cost optimization for development systems
---

# ADR-001: Use ARM64 Architecture for Cost Optimization

## Status

**Accepted** - April 2026

## Context

Development and agentic systems require reliable compute infrastructure with predictable costs. Oracle Cloud Infrastructure offers an Always Free tier with ARM64 instances providing substantial resources (4 OCPUs, 24GB RAM) at no cost.

## Decision

Use ARM64 architecture (VM.Standard.A1.Flex shape) exclusively for all development infrastructure to leverage OCI's Always Free tier while maintaining sufficient compute resources for development workflows.

## Consequences

### Positive
- **Zero Compute Costs**: Leverages OCI Always Free tier
- **Substantial Resources**: 4 OCPUs and 24GB RAM available
- **Reliable Performance**: ARM64 provides consistent performance for development workloads
- **Cost Predictability**: No unexpected compute charges

### Negative
- **Availability Constraints**: ARM64 capacity may be limited in some availability domains
- **Architecture Compatibility**: Requires ARM64-compatible software and containers
- **Regional Limitations**: Some regions may have limited ARM64 availability
- **Retry Logic Required**: Automated retry across availability domains needed

## Implementation

1. **Terraform Enforcement**: Shape validation in Terraform modules
2. **Retry Logic**: `scripts/oci-instance-retry.sh` for automated availability domain failover
3. **Image Compatibility**: ARM64-compatible Oracle Linux 8 images
4. **Container Images**: ARM64-compatible container images for all services

## Verification

- **Terraform Validation**: Rejects non-ARM64 shape configurations
- **Provisioning Tests**: Verify instance creation with ARM64 shape
- **Performance Monitoring**: Monitor ARM64 instance performance characteristics

## Related Decisions

- ADR-002: Use Persistent Block Volumes for Workspace Data
- ADR-003: Implement Automated Retry Logic for Capacity Issues

## References

- [OCI Always Free Tier Documentation](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [VM.Standard.A1.Flex Shape Documentation](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm#a1-flex)