# OCI Network Module Variables

variable "compartment_id" {
  description = "OCID of the compartment where resources will be created"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "agent-coder"
}

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

variable "http_port" {
  description = "HTTP port for the application"
  type        = number
  default     = 8080
}

variable "extra_ports" {
  description = "Additional TCP ports to open from allowed_http_cidrs source IP"
  type        = list(number)
  default     = []
}
