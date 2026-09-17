# OKF Implementation Change Schema

Schema for linking OKF concepts to OpenSpec implementation changes (`IMPL-CHG-*`).

## Purpose

This schema defines how OKF wraps OpenSpec implementation changes, including:
- Production behavior delta specification
- Verification change dependency
- Test Contract binding
- Implementation task definition

## Schema Definition

```yaml
# implementation-change.yaml
type: OpenSpec Change
role: implementation
id: IMPL-CHG-{identifier}
title: {Descriptive title}
resource: openspec/changes/implement-{identifier}/
dependencies:
  - okf://{bundle-id}/{verification-change-id}?revision={revision}&contract={digest}
status: draft|ready|implementation|archived
```

## Relationships

- One Implementation Change wraps one native OpenSpec implementation change
- Must have exactly one dependency on a frozen Verification Change
- Inherits Test Contract from its verification dependency
- Implementation agents receive this change with read-only test access