# OCI Root Module Variables

# OCI Provider Configuration
variable "tenancy_ocid" {
  description = "OCID of the tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the user"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the private key file"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "us-ashburn-1"
}

variable "compartment_id" {
  description = "OCID of the compartment where resources will be created"
  type        = string
}

# General Configuration
variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "agent-coder"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

# Network Configuration
variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to instances"
  type        = list(string)
}

variable "allowed_http_cidrs" {
  description = "List of CIDR blocks allowed to access HTTP port"
  type        = list(string)
}

variable "extra_ports" {
  description = "Additional TCP ports to open from the allowed source IP"
  type        = list(number)
  default     = []
}

# Compute Configuration
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
  default     = 4
}

variable "instance_memory_gb" {
  description = "Memory in GB for the instance"
  type        = number
  default     = 24
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

# Application Configuration
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

# Logging Configuration
variable "log_retention_days" {
  description = "Number of days to retain logs"
  type        = number
  default     = 30
}

# Monitoring Configuration
variable "alert_email" {
  description = "Email address for alert notifications"
  type        = string
}
