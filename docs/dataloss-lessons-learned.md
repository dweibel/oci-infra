# Data Loss Incident — April 17, 2026

## What Happened

A targeted `terraform apply -target=module.backup` was run to create a new OCI Object Storage bucket. Terraform resolved the dependency chain through `module.logging` → `module.compute`, which pulled the compute instance into the apply scope. The compute module's `source_details.source_id` referenced a data source that always resolves to the latest Oracle Linux ARM64 image. Because `source_details` was not in the instance's `lifecycle.ignore_changes` list, Terraform applied an in-place update that re-imaged the boot volume.

The instance rebooted with a fresh OS. All data on the boot volume was destroyed.

## What Was Lost

- Wiki.js PostgreSQL database (~67 MB) — all wiki content
- All podman containers and images (wikijs, keep-alive, cloudflared, goose-web, foundry-core)
- All podman volumes (wikijs-pgdata, wikijs-assets, goose-config, workspace)
- Podman secrets (database passwords, API keys)
- User-level systemd units and cron jobs
- AWS CLI credentials configured on the instance

## What Survived

- The 50 GB block volume (`sdb`) — independent of the boot image, data intact
- All Terraform-managed OCI resources (network, monitoring, logging, backup bucket)
- SSH key access (re-injected via instance metadata)
- The git repositories containing all infrastructure code and deployment scripts

## Root Causes

### 1. Missing lifecycle ignore rule on `source_details`

The compute module used a data source to resolve the latest Oracle Linux image:

```hcl
source_id = data.oci_core_images.oracle_linux_arm.images[0].id
```

This value changes every time Oracle publishes a new image. The `lifecycle` block only ignored `metadata` and `defined_tags` — not `source_details`. Any `terraform apply` that included the compute module in its scope would attempt to update the image, re-imaging the boot volume.

### 2. `-target` does not isolate as expected

`terraform apply -target=module.backup` was expected to only create backup resources. However, the backup module depends on `module.logging.dynamic_group_name`, which depends on `module.compute.instance_id`. Terraform refreshed the compute instance state, detected the image drift, and included it in the apply.

The `-target` flag limits what Terraform *plans to create*, but it still refreshes and can modify resources in the dependency chain.

### 3. No backups existed

The backup infrastructure was being created at the moment of the incident. There were no prior backups of the database or container volumes. The 67 MB database had been running for nearly two months without any backup mechanism.

### 4. Stateful data stored on the boot volume

All podman volumes lived under `/home/opc/.local/share/containers/storage/volumes/` on the boot volume. The 50 GB block volume (`sdb`) was attached but not mounted or used for container data. A boot volume re-image destroyed everything.

## Fixes Applied

### Immediate: Add `source_details` to lifecycle ignore

```hcl
lifecycle {
  ignore_changes = [
    metadata,
    source_details,
    defined_tags,
    create_vnic_details[0].defined_tags,
  ]
}
```

This prevents Terraform from ever changing the boot image on an existing instance.

### Planned: Move stateful data off the boot volume

Container volumes (especially `wikijs-pgdata`) should be stored on the persistent block volume (`sdb`), which is independent of the boot image and survives re-provisioning.

### Planned: Backup before any Terraform apply

The backup script (`scripts/backup-wikijs.sh`) and cron job (`scripts/deploy-backup-cron.sh`) should be deployed immediately after instance recovery. Backups should run before any infrastructure changes.

## Rules Going Forward

1. **Never run `terraform apply` without reviewing the full plan.** Even targeted applies can modify resources outside the target scope via dependency chains.

2. **Every `lifecycle` block on a compute instance must ignore `source_details`.** Image data sources that resolve to "latest" will always drift. Changing `source_id` re-images the boot volume.

3. **Stateful data must live on block volumes, not boot volumes.** Boot volumes are ephemeral in practice — they can be re-imaged, and instances on the Always Free tier can be reclaimed.

4. **Backups must exist before the infrastructure that creates them is "done."** If you're building backup infrastructure, manually back up first. A `pg_dump | gzip > local_file` takes seconds.

5. **Use `terraform plan -target=X` and read every line before applying.** The plan for this incident clearly showed `module.compute.oci_core_instance.main will be updated in-place` with a `source_id` change. It was not caught.

6. **Pin the image ID instead of using a data source.** Replace the dynamic image lookup with a fixed OCID in `terraform.tfvars`. Update it deliberately when you want to upgrade the OS.

7. **Bind mount ownership must match the container user.** When using bind mounts with `:Z` (SELinux relabel), the host directory ownership is mapped through podman's user namespace. PostgreSQL runs as uid 999, Wiki.js runs as uid 1000 (`node`). After creating bind mount directories, set ownership with `podman unshare chown -R <uid>:<gid> <path>` for each container's expected user. Without this, containers get `EACCES: permission denied` when writing to the mount. The `setup-block-volume.sh` script and `deploy-wikijs.sh` must account for this.
