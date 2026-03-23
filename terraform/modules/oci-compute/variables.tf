# OCI Compute Module Variables

variable "compartment_id" {
  description = "OCID of the compartment where resources will be created"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "agent-coder"
}

variable "subnet_id" {
  description = "OCID of the subnet where the instance will be created"
  type        = string
}

variable "availability_domain" {
  description = "Availability domain for the instance (leave empty to use first available)"
  type        = string
  default     = ""
}

variable "instance_shape" {
  description = "Shape of the instance"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs for the instance"
  type        = number
  default     = 2
}

variable "instance_memory_gb" {
  description = "Memory in GB for the instance"
  type        = number
  default     = 12
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

variable "boot_volume_size_gb" {
  description = "Size of the boot volume in GB"
  type        = number
  default     = 200
}

variable "workspace_volume_size_gb" {
  description = "Size of the workspace volume in GB"
  type        = number
  default     = 40
}

variable "workspace_mount_path" {
  description = "Mount path for the workspace volume"
  type        = string
  default     = "/mnt/workspace"
}

variable "aws_region" {
  description = "AWS region for ECR and Bedrock access"
  type        = string
  default     = "us-east-1"
}

variable "ecr_registry" {
  description = "ECR registry URL"
  type        = string
}

variable "s3_bucket" {
  description = "S3 bucket for workspace storage"
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model ID"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "log_format" {
  description = "Log format (json or text)"
  type        = string
  default     = "json"
}

variable "app_port" {
  description = "Application port"
  type        = number
  default     = 8080
}

variable "max_iterations" {
  description = "Maximum iterations for agent"
  type        = number
  default     = 10
}

variable "iteration_timeout" {
  description = "Iteration timeout in seconds"
  type        = number
  default     = 300
}

variable "tags" {
  description = "Freeform tags to apply to resources"
  type        = map(string)
  default     = {}
}
