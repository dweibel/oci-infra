# OCI Logging Module
# Creates log group, custom log, dynamic group, and IAM policy

resource "oci_logging_log_group" "main" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-log-group"
  description    = "Log group for ${var.name_prefix} application logs"
  freeform_tags  = var.tags
}

resource "oci_logging_log" "app" {
  display_name = "${var.name_prefix}-app"
  log_group_id = oci_logging_log_group.main.id
  log_type     = "CUSTOM"

  configuration {
    source {
      category    = "custom"
      resource    = var.instance_id
      service     = "compute"
      source_type = "OCISERVICE"
    }

    compartment_id = var.compartment_id
  }

  is_enabled         = true
  retention_duration = var.log_retention_days
  freeform_tags      = var.tags

  # OCI provider marks configuration block as ForceNew even when values haven't
  # changed. Ignore it to prevent unnecessary destroy/recreate cycles that fail
  # due to the unified agent config holding a reference to this log.
  lifecycle {
    ignore_changes = [configuration]
  }
}

resource "oci_identity_dynamic_group" "instance" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-instance-dg"
  description    = "Dynamic group for ${var.name_prefix} instance"
  matching_rule  = "instance.id = '${var.instance_id}'"
}

resource "oci_identity_policy" "logging" {
  compartment_id = var.compartment_id
  name           = "${var.name_prefix}-logging-policy"
  description    = "Policy allowing ${var.name_prefix} instance to write logs"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.instance.name} to use log-content in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.instance.name} to manage logging-family in compartment id ${var.compartment_id}",
  ]
}

# Unified Monitoring Agent configuration
resource "oci_logging_unified_agent_configuration" "main" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-uma-config"
  description    = "Unified Monitoring Agent configuration for ${var.name_prefix}"
  is_enabled     = true

  service_configuration {
    configuration_type = "LOGGING"

    destination {
      log_object_id = oci_logging_log.app.id
    }

    sources {
      source_type = "LOG_TAIL"
      name        = "agent-coder-journald"
      parser {
        parser_type = "JSON"
        time_format = "%Y-%m-%dT%H:%M:%S.%LZ"
        time_type   = "STRING"
      }
      paths = ["/var/log/journal"]
    }
  }

  group_association {
    group_list = [oci_identity_dynamic_group.instance.id]
  }

  freeform_tags = var.tags
}
