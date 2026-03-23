# OCI Monitoring Module Variables

variable "compartment_id" {
  description = "OCID of the compartment where resources will be created"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "agent-coder"
}

variable "instance_id" {
  description = "OCID of the compute instance to monitor"
  type        = string
}

variable "alert_email" {
  description = "Email address for alert notifications"
  type        = string
}

variable "tags" {
  description = "Freeform tags to apply to resources"
  type        = map(string)
  default     = {}
}
