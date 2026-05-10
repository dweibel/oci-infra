# OCI Backup Module Variables

variable "compartment_id" {
  description = "OCID of the compartment where resources will be created"
  type        = string
}

variable "object_storage_namespace" {
  description = "OCI Object Storage namespace (tenancy-level)"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "agent-coder"
}

variable "dynamic_group_name" {
  description = "Name of the dynamic group that includes the compute instance"
  type        = string
}

variable "retention_days" {
  description = "Number of days to retain backups before auto-deletion"
  type        = number
  default     = 30
}

variable "region" {
  description = "OCI region (e.g. us-ashburn-1)"
  type        = string
}

variable "tags" {
  description = "Freeform tags to apply to resources"
  type        = map(string)
  default     = {}
}
