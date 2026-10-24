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

# Oracle-managed detector recipes. A target with no recipes attached detects
# nothing (this one sat at 0 recipes / 0 problems until 2026-10-24). Instance
# and container security recipes are left off: they need Oracle Cloud Agent,
# which AlmaLinux images don't run. No responder recipe, so nothing remediates
# automatically; problems are report-only.
locals {
  cloud_guard_detector_recipes = [
    "OCI Configuration Detector Recipe",
    "OCI Activity Detector Recipe",
    "OCI Threat Detector Recipe",
  ]
}

data "oci_cloud_guard_detector_recipes" "oracle" {
  for_each       = toset(local.cloud_guard_detector_recipes)
  compartment_id = var.tenancy_id
  display_name   = each.value
}

resource "oci_cloud_guard_target" "compartment" {
  compartment_id       = var.compartment_id
  display_name         = "infra-target"
  target_resource_id   = var.compartment_id
  target_resource_type = "COMPARTMENT"

  dynamic "target_detector_recipes" {
    for_each = data.oci_cloud_guard_detector_recipes.oracle
    content {
      detector_recipe_id = target_detector_recipes.value.detector_recipe_collection[0].items[0].id
    }
  }

  depends_on = [oci_cloud_guard_cloud_guard_configuration.main]
}

# =============================================================================
# Vulnerability Scanning
# =============================================================================

# Required for agent-based host scans (Oracle docs: "Required IAM Policy for
# Compute Scanning Recipes"). `manage instances` is how the service deploys and
# drives the agent's scanning plugin; the grantee is Oracle's service, not us.
resource "oci_identity_policy" "vulnerability_scanning" {
  compartment_id = var.tenancy_id
  name           = "vulnerability-scanning-access"
  description    = "Allow the Vulnerability Scanning service to scan compute instances"

  statements = [
    "Allow service vulnerability-scanning-service to manage instances in tenancy",
    "Allow service vulnerability-scanning-service to read compartments in tenancy",
    "Allow service vulnerability-scanning-service to read vnics in tenancy",
    "Allow service vulnerability-scanning-service to read vnic-attachments in tenancy",
  ]
}

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
