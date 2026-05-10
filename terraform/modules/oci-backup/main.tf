# OCI Backup Module
# Creates Object Storage bucket and IAM policy for instance-based backups

resource "oci_objectstorage_bucket" "backup" {
  compartment_id = var.compartment_id
  namespace      = var.object_storage_namespace
  name           = "${var.name_prefix}-backups"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"

  freeform_tags = var.tags

  # Auto-delete old backups via lifecycle rule
  # OCI free tier: 10 GB Standard + 10 GB Archive
}

resource "oci_objectstorage_object_lifecycle_policy" "backup_retention" {
  namespace = var.object_storage_namespace
  bucket    = oci_objectstorage_bucket.backup.name

  rules {
    name      = "expire-old-backups"
    action    = "DELETE"
    is_enabled = true
    time_amount = var.retention_days
    time_unit   = "DAYS"

    target = "objects"

    object_name_filter {
      inclusion_prefixes = ["wikijs/"]
    }
  }
}

# IAM policy allowing the instance dynamic group to write to the bucket
resource "oci_identity_policy" "backup" {
  compartment_id = var.compartment_id
  name           = "${var.name_prefix}-backup-policy"
  description    = "Policy allowing ${var.name_prefix} instance to manage backup bucket"

  statements = [
    "Allow dynamic-group ${var.dynamic_group_name} to manage objects in compartment id ${var.compartment_id} where target.bucket.name = '${oci_objectstorage_bucket.backup.name}'",
    "Allow dynamic-group ${var.dynamic_group_name} to read buckets in compartment id ${var.compartment_id} where target.bucket.name = '${oci_objectstorage_bucket.backup.name}'",
  ]
}
