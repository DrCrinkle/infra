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

module "networking" {
  source = "./modules/networking"

  compartment_id     = var.compartment_id
  vcn_name           = "The Crinkle Domain"
  vcn_cidr_blocks    = ["10.0.0.0/16"]
  public_subnet_cidr = "10.0.0.0/24"
}

# =============================================================================
# Compute Instance
# =============================================================================

resource "oci_core_instance" "openclaw" {
  compartment_id      = var.compartment_id
  availability_domain = "mBSv:US-SANJOSE-1-AD-1"
  display_name        = "OpenClaw"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  source_details {
    source_type             = "image"
    source_id               = "ocid1.image.oc1..aaaaaaaauc7uim6b3utoeimtl3l7q27qbb4tmmh5f2rfblv6vowhxfjyiusa"
    boot_volume_size_in_gbs = 50
    # kms_key_id = module.security.kms_key_id  # Enable for new instances
  }

  create_vnic_details {
    subnet_id        = module.networking.public_subnet_id
    assign_public_ip = false
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
  target_subnet_id             = module.networking.public_subnet_id
  name                         = "Bastion202602041330"
  client_cidr_block_allow_list = ["0.0.0.0/0"]
}
