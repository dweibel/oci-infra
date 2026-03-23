# OCI Root Module
# Main configuration for agent-coder OCI deployment

terraform {
  required_version = ">= 1.6.0"
  
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

locals {
  common_tags = {
    Project     = "agent-coder"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Network Module
module "network" {
  source = "./modules/oci-network"

  compartment_id     = var.compartment_id
  name_prefix        = "${var.name_prefix}-${var.environment}"
  vcn_cidr           = var.vcn_cidr
  subnet_cidr        = var.subnet_cidr
  allowed_ssh_cidrs  = var.allowed_ssh_cidrs
  allowed_http_cidrs = var.allowed_http_cidrs
  http_port          = var.app_port
  extra_ports        = var.extra_ports
}

# Compute Module
module "compute" {
  source = "./modules/oci-compute"

  compartment_id           = var.compartment_id
  name_prefix              = "${var.name_prefix}-${var.environment}"
  subnet_id                = module.network.subnet_id
  availability_domain      = var.availability_domain
  instance_shape           = var.instance_shape
  instance_ocpus           = var.instance_ocpus
  instance_memory_gb       = var.instance_memory_gb
  ssh_public_key           = var.ssh_public_key
  boot_volume_size_gb      = var.boot_volume_size_gb
  workspace_volume_size_gb = var.workspace_volume_size_gb
  workspace_mount_path     = var.workspace_mount_path
  aws_region               = var.aws_region
  ecr_registry             = var.ecr_registry
  s3_bucket                = var.s3_bucket
  bedrock_model_id         = var.bedrock_model_id
  log_format               = var.log_format
  app_port                 = var.app_port
  max_iterations           = var.max_iterations
  iteration_timeout        = var.iteration_timeout
  tags                     = local.common_tags
}

# Logging Module
module "logging" {
  source = "./modules/oci-logging"

  compartment_id       = var.compartment_id
  tenancy_ocid         = var.tenancy_ocid
  name_prefix          = "${var.name_prefix}-${var.environment}"
  instance_id          = module.compute.instance_id
  log_retention_days   = var.log_retention_days
  tags                 = local.common_tags
}

# Monitoring Module
module "monitoring" {
  source = "./modules/oci-monitoring"

  compartment_id = var.compartment_id
  name_prefix    = "${var.name_prefix}-${var.environment}"
  instance_id    = module.compute.instance_id
  alert_email    = var.alert_email
  tags           = local.common_tags
}
