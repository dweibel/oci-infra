# OCI Backup Module Outputs

output "bucket_name" {
  description = "Name of the backup bucket"
  value       = oci_objectstorage_bucket.backup.name
}

output "bucket_namespace" {
  description = "Object Storage namespace"
  value       = var.object_storage_namespace
}

output "s3_endpoint" {
  description = "S3-compatible endpoint for the backup bucket"
  value       = "https://${var.object_storage_namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "backup_policy_id" {
  description = "OCID of the backup IAM policy"
  value       = oci_identity_policy.backup.id
}
