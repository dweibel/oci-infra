---
type: Reference
id: OCI-INFRA-INDEX
title: Oracle Cloud Infrastructure Knowledge Index
---

# Oracle Cloud Infrastructure Knowledge Base

This is the project knowledge base for Oracle Cloud Infrastructure Infrastructure-as-Code management.

## Structure

- **objectives/**: Infrastructure objectives and key results
- **requirements/**: Infrastructure requirements and specifications
- **changes/**: Infrastructure change documentation and wrappers
- **architecture/**: Infrastructure architecture components and interfaces
- **decisions/**: Infrastructure architecture decision records
- **testing/**: Infrastructure test procedures and evidence
- **operations/**: Infrastructure runbooks and incident lessons
- **risks/**: Infrastructure risk assessments
- **references/**: External references and documentation

## Project Overview

This repository manages Oracle Cloud Infrastructure (OCI) resources using Infrastructure as Code (IaC) principles with a focus on ARM64 architecture and cost optimization.

## Key Infrastructure Components

1. **Modular Terraform Infrastructure**: Reusable components for compute, networking, logging, and monitoring
2. **ARM64 Architecture Enforcement**: VM.Standard.A1.Flex shape for OCI Always Free tier
3. **Automated Deployment**: Robust error handling and retry logic across availability domains
4. **Persistent Storage**: Block volumes that survive instance terminations
5. **Centralized Logging & Monitoring**: OCI unified agent and configurable alarms
6. **Secure Secret Management**: .env-based configuration with verification tooling
7. **Wiki.js Deployment**: Complete deployment with PostgreSQL and MCP server