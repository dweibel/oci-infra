# OCI Compute Module Outputs

output "instance_id" {
  description = "OCID of the compute instance"
  value       = oci_core_instance.main.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = oci_core_instance.main.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = oci_core_instance.main.private_ip
}

output "workspace_volume_id" {
  description = "OCID of the workspace volume"
  value       = oci_core_volume.workspace.id
}

output "workspace_volume_attachment_id" {
  description = "OCID of the workspace volume attachment"
  value       = oci_core_volume_attachment.workspace.id
}
