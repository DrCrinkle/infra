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

  # Attach NAT security list to public subnet to allow transit traffic from private subnet
  public_subnet_additional_security_list_ids = [module.nat_instance.security_list_id]
}

# =============================================================================
# NAT Instance (fck-nat style on free tier)
# =============================================================================

module "nat_instance" {
  source = "./modules/nat-instance"

  compartment_id           = var.compartment_id
  availability_domain      = "mBSv:US-SANJOSE-1-AD-1"
  subnet_id                = module.networking.public_subnet_id
  vcn_id                   = module.networking.vcn_id
  ssh_public_key           = var.ssh_public_key
  private_subnet_cidr      = local.private_subnet_cidr
  private_subnet_ipv6_cidr = cidrsubnet(module.networking.vcn_ipv6cidr_blocks[0], 8, 1)
  image_id                 = var.nat_instance_image_id

  # HA mode (optional) - uses both free tier x86 instances
  # enable_ha      = true
  # route_table_id = module.networking.private_route_table_id
}

# =============================================================================
# Private Subnet (routes through NAT instance)
# =============================================================================

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = module.networking.vcn_id
  display_name   = "Private Route Table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = module.nat_instance.private_ip_id
  }

  # OCI services (yum repos, Object Storage, etc.) bypass NAT via service gateway
  route_rules {
    destination       = module.networking.all_services_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = module.networking.service_gateway_id
  }

  # Native IPv6 egress via internet gateway (bypasses NAT)
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = module.networking.internet_gateway_id
  }

  # NOTE: NAT64 prefix (64:ff9b::/96) routing is configured at the OS level
  # on private subnet instances, not in OCI route tables. OCI doesn't support
  # IPv6 route rules targeting a VNIC private IP. Configure via:
  #   ip -6 route add 64:ff9b::/96 via <NAT_INSTANCE_IPV6_ADDR>
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
# NAT Cloud-init Wait
# =============================================================================
# NAT instance cloud-init takes 30-60s to configure IP forwarding and iptables.
# Without this wait, openclaw may boot before NAT is ready, breaking outbound.

resource "time_sleep" "wait_for_nat_cloudinit" {
  depends_on      = [module.nat_instance]
  create_duration = "300s"
}

# =============================================================================
# Compute Instance
# =============================================================================

resource "oci_core_instance" "openclaw" {
  compartment_id      = var.compartment_id
  availability_domain = "mBSv:US-SANJOSE-1-AD-1"
  display_name        = "OpenClaw"
  shape               = "VM.Standard.A1.Flex"

  depends_on = [time_sleep.wait_for_nat_cloudinit]

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  source_details {
    source_type = "image"
    # AlmaLinux 10.0 aarch64 (2025.02.03) - us-sanjose-1
    # Verify: oci compute image get --image-id <this-ocid> | jq '.data."display-name"'
    source_id               = "ocid1.image.oc1..aaaaaaaauc7uim6b3utoeimtl3l7q27qbb4tmmh5f2rfblv6vowhxfjyiusa"
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    assign_ipv6ip    = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
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
