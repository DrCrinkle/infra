# =============================================================================
# IAM Policies - Required for Cloud Guard
# =============================================================================

resource "oci_identity_policy" "cloud_guard" {
  compartment_id = var.tenancy_id
  name           = "cloud-guard-access"
  description    = "Allow Cloud Guard to monitor tenancy"

  statements = [
    "Allow service cloudguard to read all-resources in tenancy",
    "Allow service cloudguard to use network-security-groups in tenancy"
  ]
}

# =============================================================================
# Cloud Guard - Threat Detection & Compliance
# =============================================================================

resource "oci_cloud_guard_cloud_guard_configuration" "main" {
  compartment_id   = var.tenancy_id
  reporting_region = var.region
  status           = "ENABLED"

  depends_on = [oci_identity_policy.cloud_guard]
}

resource "oci_cloud_guard_target" "compartment" {
  compartment_id       = var.compartment_id
  display_name         = "infra-target"
  target_resource_id   = var.compartment_id
  target_resource_type = "COMPARTMENT"

  depends_on = [oci_cloud_guard_cloud_guard_configuration.main]
}

# =============================================================================
# Vulnerability Scanning
# =============================================================================

resource "oci_vulnerability_scanning_host_scan_recipe" "main" {
  compartment_id = var.compartment_id
  display_name   = "weekly-scan"

  port_settings {
    scan_level = "STANDARD"
  }

  schedule {
    type        = "WEEKLY"
    day_of_week = "SUNDAY"
  }

  agent_settings {
    scan_level = "STANDARD"
    agent_configuration {
      vendor = "OCI"
    }
  }
}

resource "oci_vulnerability_scanning_host_scan_target" "main" {
  compartment_id        = var.compartment_id
  host_scan_recipe_id   = oci_vulnerability_scanning_host_scan_recipe.main.id
  target_compartment_id = var.compartment_id
  display_name          = "infra-instances"
}

# =============================================================================
# Audit Log Retention - 90 days
# =============================================================================

resource "oci_logging_log_group" "audit" {
  compartment_id = var.compartment_id
  display_name   = "audit-logs"
}
