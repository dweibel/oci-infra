# OCI Monitoring Module Outputs

output "critical_topic_id" {
  description = "OCID of the critical notifications topic"
  value       = oci_ons_notification_topic.critical.id
}

output "warnings_topic_id" {
  description = "OCID of the warnings notifications topic"
  value       = oci_ons_notification_topic.warnings.id
}

output "info_topic_id" {
  description = "OCID of the info notifications topic"
  value       = oci_ons_notification_topic.info.id
}

output "cpu_high_alarm_id" {
  description = "OCID of the CPU high alarm"
  value       = oci_monitoring_alarm.cpu_high.id
}

output "memory_high_alarm_id" {
  description = "OCID of the memory high alarm"
  value       = oci_monitoring_alarm.memory_high.id
}

output "cpu_idle_alarm_id" {
  description = "OCID of the CPU idle risk alarm"
  value       = oci_monitoring_alarm.cpu_idle.id
}

output "instance_down_alarm_id" {
  description = "OCID of the instance down alarm"
  value       = oci_monitoring_alarm.instance_down.id
}
