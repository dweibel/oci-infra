# OKF Verification Change Schema

Schema for linking OKF concepts to OpenSpec verification changes (`TEST-CHG-*`).

## Purpose

This schema defines how OKF wraps OpenSpec verification changes, including:
- Gherkin feature ownership
- Test Contract creation
- Readiness evidence collection
- Implementation dependency binding

## Schema Definition

```yaml
# verification-change.yaml
type: OpenSpec Change
role: verification
id: TEST-CHG-{identifier}
title: {Descriptive title}
resource: openspec/changes/verify-{identifier}/
dependencies: []
evidence:
  readiness: {digest}
  contract: {digest}
status: draft|ready|frozen|archived
```

## Relationships

- One Verification Change wraps one native OpenSpec verification change
- May have zero or more dependencies on other OKF concepts (requirements, etc.)
- Produces a Test Contract digest when frozen
- Required for any Implementation Change dependency