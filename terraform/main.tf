# =============================================================================
# Security
# =============================================================================

module "security" {
  source = "./modules/security"

  compartment_id = var.compartment_id
  tenancy_id     = var.tenancy_id != "" ? var.tenancy_id : var.compartment_id
  region         = var.region
}

# =============================================================================
# Networking
# =============================================================================

locals {
  private_subnet_cidr = "10.0.1.0/24"
}

module "networking" {
  source = "./modules/networking"

  compartment_id     = var.compartment_id
  vcn_name           = "The Crinkle Domain"
  vcn_cidr_blocks    = ["10.0.0.0/16"]
  public_subnet_cidr = "10.0.0.0/24"

  # Private subnet egresses via OpenClaw now (see oci_core_route_table.private).
  # Transit-traffic allow lives on OpenClaw's NSG, not the whole subnet, so no extra SL here.
  public_subnet_additional_security_list_ids = []
}

# NAT instance decommissioned 2026-05-30: OpenClaw (public subnet, ~4 Gbps IGW egress)
# now serves as the private subnet's NAT router via skip_source_dest_check + nftables
# masquerade. The private subnet + route table + Bastion are retained for a future DB tier.

# =============================================================================
# Private Subnet (IPv4 egress via OpenClaw-as-NAT; empty, reserved for future DB tier)
# =============================================================================

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = module.networking.vcn_id
  display_name   = "Private Route Table"

  # IPv4 egress routes through OpenClaw (skip_source_dest_check + nftables masquerade),
  # which replaced the dedicated NAT micro instance on 2026-05-30.
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = data.oci_core_private_ips.openclaw.private_ips[0].id
  }

  # OCI services (yum repos, Object Storage, etc.) go direct via the service gateway
  route_rules {
    destination       = module.networking.all_services_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = module.networking.service_gateway_id
  }

  # Native IPv6 egress straight to the internet gateway — no NAT needed for IPv6 (GUAs
  # are globally routable). A future DB tier gets v6 internet without touching OpenClaw.
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = module.networking.internet_gateway_id
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_id
  vcn_id         = module.networking.vcn_id
  display_name   = "Private Subnet Security List"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  # IPv6 egress
  egress_security_rules {
    destination      = "::/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol    = "1"
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 3
      code = -1
    }
  }

  ingress_security_rules {
    protocol    = "1"
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 8
      code = -1
    }
  }

  # IPv6 SSH from VCN
  ingress_security_rules {
    protocol    = "6"
    source      = module.networking.vcn_ipv6cidr_blocks[0]
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMPv6 from VCN (destination unreachable)
  ingress_security_rules {
    protocol    = "58"
    source      = module.networking.vcn_ipv6cidr_blocks[0]
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 1
      code = -1
    }
  }

  # ICMPv6 packet too big
  ingress_security_rules {
    protocol    = "58"
    source      = "::/0"
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 2
      code = 0
    }
  }
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_id
  vcn_id                     = module.networking.vcn_id
  display_name               = "Private"
  cidr_block                 = local.private_subnet_cidr
  ipv6cidr_block             = cidrsubnet(module.networking.vcn_ipv6cidr_blocks[0], 8, 1)
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
}

# =============================================================================
# OpenClaw NSG - per-VNIC ingress control on the shared public subnet
# =============================================================================
# OpenClaw moves onto the public subnet for direct IGW egress (no NAT bottleneck).
# The subnet's default security list already blocks all internet ingress except
# ICMP PMTUD (SSH is VCN-only). This NSG adds the one inbound rule Tailscale wants
# for its fast DIRECT path; without it Tailscale still works but via DERP relay.
resource "oci_core_network_security_group" "openclaw" {
  compartment_id = var.compartment_id
  vcn_id         = module.networking.vcn_id
  display_name   = "OpenClaw NSG"
}

# Tailscale WireGuard (UDP 41641). Open from anywhere is safe: only cryptographically
# authenticated tailnet peers can do anything with it. This is the only inbound port.
resource "oci_core_network_security_group_security_rule" "openclaw_tailscale" {
  network_security_group_id = oci_core_network_security_group.openclaw.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

# Transit traffic from the private subnet: OpenClaw is the NAT router for 10.0.1.0/24,
# so it must accept forwarded traffic from there (replaces the old NAT instance's
# security list). Source is VCN-internal only — the public internet cannot use this.
resource "oci_core_network_security_group_security_rule" "openclaw_private_transit" {
  network_security_group_id = oci_core_network_security_group.openclaw.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.private_subnet_cidr
  source_type               = "CIDR_BLOCK"
}

# =============================================================================
# Compute Instance
# =============================================================================

resource "oci_core_instance" "openclaw" {
  compartment_id      = var.compartment_id
  availability_domain = "mBSv:US-SANJOSE-1-AD-1"
  display_name        = "OpenClaw"
  shape               = "VM.Standard.A1.Flex"

  # Preserve boot volume on termination. The IGW migration changes subnet_id
  # (ForceNew → recreate); without this, terminate would delete the boot volume
  # and the recreate-from-OCID would fail with data loss. Commit BEFORE cutover.
  preserve_boot_volume = true

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  source_details {
    source_type             = var.openclaw_boot_volume_id != null ? "bootVolume" : "image"
    source_id               = var.openclaw_boot_volume_id != null ? var.openclaw_boot_volume_id : "ocid1.image.oc1..aaaaaaaauc7uim6b3utoeimtl3l7q27qbb4tmmh5f2rfblv6vowhxfjyiusa"
    boot_volume_size_in_gbs = var.openclaw_boot_volume_id != null ? null : 50
  }

  create_vnic_details {
    subnet_id              = module.networking.public_subnet_id
    assign_public_ip       = true # ephemeral; egress-only. Ingress sealed by subnet SL + NSG + firewalld.
    assign_ipv6ip          = true # native dual-stack via IGW (replaces NAT64/DNS64/Jool)
    nsg_ids                = [oci_core_network_security_group.openclaw.id]
    skip_source_dest_check = true # act as NAT/router for the private subnet (replaces micro NAT instance)
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

# OpenClaw's primary private IP OCID — used as the private subnet's NAT next-hop
# (oci_core_route_table.private routes 0.0.0.0/0 here).
data "oci_core_vnic_attachments" "openclaw" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.openclaw.id
}

data "oci_core_private_ips" "openclaw" {
  vnic_id = data.oci_core_vnic_attachments.openclaw.vnic_attachments[0].vnic_id
}

# =============================================================================
# Bastion
# =============================================================================

resource "oci_bastion_bastion" "main" {
  compartment_id               = var.compartment_id
  bastion_type                 = "STANDARD"
  target_subnet_id             = oci_core_subnet.private.id
  name                         = "Bastion202602041330"
  client_cidr_block_allow_list = ["0.0.0.0/0"]
}
