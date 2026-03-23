# OCI Compute Module
# Creates VM instance, block volume, and volume attachment

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

data "oci_core_images" "oracle_linux_arm" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "main" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain != "" ? var.availability_domain : data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${var.name_prefix}-vm"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.oracle_linux_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
    display_name     = "${var.name_prefix}-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      aws_region           = var.aws_region
      ecr_registry         = var.ecr_registry
      s3_bucket            = var.s3_bucket
      bedrock_model_id     = var.bedrock_model_id
      log_format           = var.log_format
      app_port             = var.app_port
      max_iterations       = var.max_iterations
      iteration_timeout    = var.iteration_timeout
      workspace_mount_path = var.workspace_mount_path
    }))
  }

  freeform_tags = var.tags

  # Ignore metadata changes to prevent instance replacement when
  # the instance was created via OCI CLI (retry script) and imported.
  # user_data and ssh_authorized_keys formatting can differ slightly.
  lifecycle {
    ignore_changes = [metadata, defined_tags, create_vnic_details[0].defined_tags]
  }
}

resource "oci_core_volume" "workspace" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain != "" ? var.availability_domain : data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${var.name_prefix}-workspace-volume"
  size_in_gbs         = var.workspace_volume_size_gb
  freeform_tags       = var.tags
}

resource "oci_core_volume_attachment" "workspace" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.main.id
  volume_id       = oci_core_volume.workspace.id
  display_name    = "${var.name_prefix}-workspace-attachment"
}
