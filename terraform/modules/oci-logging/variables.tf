# OCI Logging Module Variables

variable "compartment_id" {
  description = "OCID of the compartment where resources will be created"
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the tenancy (required for dynamic group creation)"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "agent-coder"
}

variable "instance_id" {
  description = "OCID of the compute instance to associate with logging"
  type        = string
}

variable "log_retention_days" {
  description = "Number of days to retain logs"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Freeform tags to apply to resources"
  type        = map(string)
  default     = {}
}
