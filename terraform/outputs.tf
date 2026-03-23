# OCI Root Module Outputs

# Network Outputs
output "vcn_id" {
  description = "OCID of the VCN"
  value       = module.network.vcn_id
}

output "subnet_id" {
  description = "OCID of the public subnet"
  value       = module.network.subnet_id
}

# Compute Outputs
output "instance_id" {
  description = "OCID of the compute instance"
  value       = module.compute.instance_id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = module.compute.instance_public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = module.compute.instance_private_ip
}

output "workspace_volume_id" {
  description = "OCID of the workspace volume"
  value       = module.compute.workspace_volume_id
}

# Logging Outputs
output "log_group_id" {
  description = "OCID of the log group"
  value       = module.logging.log_group_id
}

output "app_log_id" {
  description = "OCID of the application log"
  value       = module.logging.app_log_id
}

# Monitoring Outputs
output "critical_topic_id" {
  description = "OCID of the critical notifications topic"
  value       = module.monitoring.critical_topic_id
}

output "warnings_topic_id" {
  description = "OCID of the warnings notifications topic"
  value       = module.monitoring.warnings_topic_id
}

output "info_topic_id" {
  description = "OCID of the info notifications topic"
  value       = module.monitoring.info_topic_id
}

# Connection Information
output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/oci_agent_coder opc@${module.compute.instance_public_ip}"
}

output "health_check_url" {
  description = "URL for health check endpoint"
  value       = "http://${module.compute.instance_public_ip}:${var.app_port}/ping"
}

output "invocation_url" {
  description = "URL for invocation endpoint"
  value       = "http://${module.compute.instance_public_ip}:${var.app_port}/invocations"
}
