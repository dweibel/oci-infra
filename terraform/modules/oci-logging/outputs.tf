# OCI Logging Module Outputs

output "log_group_id" {
  description = "OCID of the log group"
  value       = oci_logging_log_group.main.id
}

output "app_log_id" {
  description = "OCID of the application log"
  value       = oci_logging_log.app.id
}

output "dynamic_group_id" {
  description = "OCID of the dynamic group"
  value       = oci_identity_dynamic_group.instance.id
}

output "logging_policy_id" {
  description = "OCID of the logging policy"
  value       = oci_identity_policy.logging.id
}

output "uma_config_id" {
  description = "OCID of the Unified Monitoring Agent configuration"
  value       = oci_logging_unified_agent_configuration.main.id
}
