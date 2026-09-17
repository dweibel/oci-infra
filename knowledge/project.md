---
type: Software Project
id: OCI-INFRA-PROJECT
title: Oracle Cloud Infrastructure Infrastructure
status: operational
---

# Oracle Cloud Infrastructure Infrastructure Project

## Overview

A dedicated Infrastructure-as-Code repository for managing Oracle Cloud Infrastructure (OCI) resources with a focus on ARM64 architecture, cost optimization, and persistent infrastructure that survives instance terminations.

## Purpose

Provides reliable, automated infrastructure management for development and agentic systems with:
- Cost optimization through OCI Always Free tier (ARM64)
- Infrastructure persistence through block volumes
- Automated recovery and retry mechanisms
- Centralized logging and monitoring
- Secure secret management
- Backup and restore capabilities

## Key Infrastructure Features

1. **ARM64 Architecture Enforcement**: Exclusive use of VM.Standard.A1.Flex shape for cost optimization
2. **Automated Retry Logic**: Instance provisioning automatically retries across availability domains
3. **Persistent Storage**: Workspace volumes survive instance terminations
4. **Comprehensive Logging**: Centralized log collection with OCI unified agent
5. **Monitoring & Alerts**: Configurable alarms for CPU, memory, and disk usage
6. **Secret Management**: .env-based configuration with verification to prevent credential leakage
7. **Wiki.js Deployment**: Complete deployment with PostgreSQL database and MCP server

## Architecture Principles

1. **Cost Optimization**: Leverage OCI Always Free tier where possible
2. **Resilience**: Infrastructure survives instance terminations
3. **Automation**: Minimal manual intervention required
4. **Security**: Least-privilege access and secret protection
5. **Observability**: Comprehensive logging and monitoring

## Repository Structure

- `terraform/`: Modular Terraform infrastructure
- `scripts/`: Deployment and management automation
- `docs/`: Architecture and operational documentation
- `container/`: Container-related configurations
- `tests/`: Infrastructure testing
- `knowledge/`: OKF knowledge base

## Status

This is an **operational infrastructure project** with active deployments and maintenance procedures in place.