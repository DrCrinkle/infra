# =============================================================================
# Free-tier E2.1.Micro fleet: sentinel (watchdog) + edge-lab (public sandbox)
# =============================================================================
# Two Always-Free x86_64 AMD micros (1 OCPU / 1 GB each). Both sit on the
# EXISTING public subnet with an egress-only ephemeral public IP (same sealed
# pattern as OpenClaw: subnet security list blocks all internet inbound; a
# per-VNIC NSG opens only Tailscale UDP 41641, which is crypto-authenticated).
#
# - sentinel : external monitor. Needs INDEPENDENT egress so it can still send
#              alerts when OpenClaw (the thing it watches / the private-subnet
#              NAT router) is down -> its own public IP, not OpenClaw's NAT.
# - edge-lab : public demo sandbox. Public exposure (80/443) is DEFERRED; it
#              starts Tailscale-only until a real demo + domain exists.
#
# Billing: 2x E2.1.Micro is within the Always Free 2-instance limit (verified
# live: limit 2, used 0). Image is FREE. Boot 50 GB x2 keeps total block usage
# at ~150/200 GB. Ephemeral public IPv4 has run at $0 on OpenClaw for months.
# =============================================================================

variable "tailscale_authkey" {
  description = "Single-use EPHEMERAL Tailscale auth key, baked into first-boot cloud-init and consumed on enrollment. Pass via TF_VAR_tailscale_authkey; never commit."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  # AlmaLinux OS 10 (x86_64) marketplace/community image. Resolved live:
  #   listing   ocid1.appcataloglisting.oc1..aaaaaaaaomk2k66osjl3ug7mppezgmzgyc75m23slfanq6bc6nxtcpfz7hhq
  #   version   10.2.20260526.0  (AlmaLinux-10-OCI-10.2-20260526.0.x86_64)  pricing FREE
  #   us-sanjose-1 supported, image AVAILABLE in-tenancy.
  alma_x86_listing_id = "ocid1.appcataloglisting.oc1..aaaaaaaaomk2k66osjl3ug7mppezgmzgyc75m23slfanq6bc6nxtcpfz7hhq"
  alma_x86_version    = "10.2.20260526.0"

  micro_ad = "mBSv:US-SANJOSE-1-AD-1"
}

# --- Marketplace agreement + subscription (FREE image; one-time, auditable) ---
# The agreement is a *resource* (creating it retrieves+accepts the terms and
# exposes signature/links as computed attributes), not a data source.
resource "oci_core_app_catalog_listing_resource_version_agreement" "alma_x86" {
  listing_id               = local.alma_x86_listing_id
  listing_resource_version = local.alma_x86_version
}

resource "oci_core_app_catalog_subscription" "alma_x86" {
  compartment_id           = var.compartment_id
  listing_id               = local.alma_x86_listing_id
  listing_resource_version = oci_core_app_catalog_listing_resource_version_agreement.alma_x86.listing_resource_version
  oracle_terms_of_use_link = oci_core_app_catalog_listing_resource_version_agreement.alma_x86.oracle_terms_of_use_link
  eula_link                = oci_core_app_catalog_listing_resource_version_agreement.alma_x86.eula_link
  signature                = oci_core_app_catalog_listing_resource_version_agreement.alma_x86.signature
  time_retrieved           = oci_core_app_catalog_listing_resource_version_agreement.alma_x86.time_retrieved

  timeouts {
    create = "10m"
  }
}

# The concrete image OCID behind the subscribed listing version.
data "oci_core_app_catalog_listing_resource_version" "alma_x86" {
  listing_id       = local.alma_x86_listing_id
  resource_version = local.alma_x86_version
}

# =============================================================================
# Per-instance NSGs — only inbound path from the internet is Tailscale UDP.
# =============================================================================
resource "oci_core_network_security_group" "sentinel" {
  compartment_id = var.compartment_id
  vcn_id         = module.networking.vcn_id
  display_name   = "sentinel NSG"
}

resource "oci_core_network_security_group" "edge_lab" {
  compartment_id = var.compartment_id
  vcn_id         = module.networking.vcn_id
  display_name   = "edge-lab NSG"
}

# Tailscale WireGuard (UDP 41641) — safe from anywhere; only authenticated
# tailnet peers can use it. Same rationale as OpenClaw's rule.
resource "oci_core_network_security_group_security_rule" "sentinel_tailscale" {
  network_security_group_id = oci_core_network_security_group.sentinel.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

resource "oci_core_network_security_group_security_rule" "edge_lab_tailscale" {
  network_security_group_id = oci_core_network_security_group.edge_lab.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

# NOTE: edge-lab public 80/443 is intentionally NOT opened yet. When a real
# demo + domain exists, add INGRESS TCP 80/443 rules to edge_lab NSG here.

# =============================================================================
# Instances (E2.1.Micro is a FIXED shape: no shape_config block)
# =============================================================================
resource "oci_core_instance" "sentinel" {
  compartment_id       = var.compartment_id
  availability_domain  = local.micro_ad
  display_name         = "sentinel"
  shape                = "VM.Standard.E2.1.Micro"
  preserve_boot_volume = true

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_app_catalog_listing_resource_version.alma_x86.listing_resource_id
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = module.networking.public_subnet_id
    assign_public_ip = true # egress-only; ingress sealed by subnet SL + NSG + firewalld
    nsg_ids          = [oci_core_network_security_group.sentinel.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/micro-base.yaml.tftpl", {
      tailscale_authkey = var.tailscale_authkey
      hostname          = "sentinel"
    }))
  }

  # Ephemeral auth key is consumed on first boot; ignore later metadata/image
  # drift so a routine apply never tries to replace a working box.
  lifecycle {
    ignore_changes = [metadata, source_details]
  }

  depends_on = [oci_core_app_catalog_subscription.alma_x86]
}

resource "oci_core_instance" "edge_lab" {
  compartment_id       = var.compartment_id
  availability_domain  = local.micro_ad
  display_name         = "edge-lab"
  shape                = "VM.Standard.E2.1.Micro"
  preserve_boot_volume = true

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_app_catalog_listing_resource_version.alma_x86.listing_resource_id
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = module.networking.public_subnet_id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.edge_lab.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/micro-base.yaml.tftpl", {
      tailscale_authkey = var.tailscale_authkey
      hostname          = "edge-lab"
    }))
  }

  # Oracle Cloud Agent trial box (plugin set in main.tf). sentinel stays
  # agent-free until edge-lab shows the agent fits in 1 GB of RAM.
  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    dynamic "plugins_config" {
      for_each = local.oca_plugins
      content {
        name          = plugins_config.key
        desired_state = plugins_config.value
      }
    }
  }

  lifecycle {
    ignore_changes = [metadata, source_details]
  }

  depends_on = [oci_core_app_catalog_subscription.alma_x86]
}

# =============================================================================
# Outputs
# =============================================================================
output "sentinel_public_ip" {
  value = oci_core_instance.sentinel.public_ip
}
output "sentinel_private_ip" {
  value = oci_core_instance.sentinel.private_ip
}
output "edge_lab_public_ip" {
  value = oci_core_instance.edge_lab.public_ip
}
output "edge_lab_private_ip" {
  value = oci_core_instance.edge_lab.private_ip
}
