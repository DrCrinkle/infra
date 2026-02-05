# =============================================================================
# NAT Instance (fck-nat style for OCI free tier)
# =============================================================================
# Uses VM.Standard.E2.1.Micro (1 OCPU, 1GB RAM) - Always Free eligible
# Configures IP forwarding and iptables masquerade via cloud-init
#
# HA Mode (optional):
# - Deploys a standby instance that monitors the primary
# - On failure, standby updates the route table to point to itself

locals {
  # Base NAT configuration (used by both primary and standby)
  cloud_init_nat = <<-EOF
    echo "=== NAT Instance Setup Starting ===" | tee /var/log/nat-setup.log

    # Enable IP forwarding
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/98-nat.conf
    sysctl -w net.ipv4.ip_forward=1

    # Disable reverse path filtering
    for i in /proc/sys/net/ipv4/conf/*/rp_filter; do
      echo 0 > "$i"
    done
    echo "net.ipv4.conf.all.rp_filter = 0" >> /etc/sysctl.d/98-nat.conf
    echo "net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.d/98-nat.conf

    # Conntrack tuning for VM.Standard.E2.1.Micro (prevents exhaustion under load)
    cat >> /etc/sysctl.d/98-nat.conf << 'SYSCTL'
    net.netfilter.nf_conntrack_max = 131072
    net.netfilter.nf_conntrack_tcp_timeout_established = 600
    net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
    SYSCTL
    
    # Load conntrack module and apply settings
    modprobe nf_conntrack 2>/dev/null || true
    sysctl -p /etc/sysctl.d/98-nat.conf 2>/dev/null || true
    echo "Conntrack tuning applied" | tee -a /var/log/nat-setup.log

    # Detect default outbound interface dynamically
    DEFAULT_IF=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+' | head -1)
    if [ -z "$DEFAULT_IF" ]; then
      DEFAULT_IF=$(ip route show default | grep -oP 'dev \K\S+' | head -1)
    fi
    if [ -z "$DEFAULT_IF" ]; then
      echo "ERROR: Could not detect default interface" | tee /var/log/nat-setup-error.log
      exit 1
    fi
    echo "Detected default interface: $DEFAULT_IF" | tee -a /var/log/nat-setup.log

    # Configure NAT masquerade - use nftables (native to AlmaLinux 10+) or fall back to iptables
    if command -v nft &> /dev/null; then
      echo "Using nftables for NAT" | tee -a /var/log/nat-setup.log
      dnf install -y nftables 2>/dev/null || yum install -y nftables 2>/dev/null || true
      
      mkdir -p /etc/nftables
      cat > /etc/nftables/nat.nft << NFTEOF
    table ip nat {
        chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ip saddr ${var.private_subnet_cidr} oifname "$DEFAULT_IF" masquerade
        }
    }
    NFTEOF
      
      nft -f /etc/nftables/nat.nft
      echo 'include "/etc/nftables/nat.nft"' >> /etc/sysconfig/nftables.conf
      systemctl enable --now nftables
      
      echo "nftables NAT configured" | tee -a /var/log/nat-setup.log
      nft list ruleset | tee -a /var/log/nat-setup.log
    elif command -v iptables &> /dev/null; then
      echo "Using iptables for NAT" | tee -a /var/log/nat-setup.log
      iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -s ${var.private_subnet_cidr} -j MASQUERADE
      
      if command -v iptables-save &> /dev/null; then
        mkdir -p /etc/sysconfig
        iptables-save > /etc/sysconfig/iptables
      fi
      
      if systemctl list-unit-files | grep -q iptables; then
        systemctl enable --now iptables
      fi
      
      iptables -t nat -L POSTROUTING -n | tee -a /var/log/nat-setup.log
    else
      echo "ERROR: Neither nftables nor iptables available" | tee -a /var/log/nat-setup.log
      exit 1
    fi

    # Verify configuration
    echo "=== Verification ===" | tee -a /var/log/nat-setup.log
    echo "ip_forward: $(sysctl -n net.ipv4.ip_forward)" | tee -a /var/log/nat-setup.log
    echo "conntrack_max: $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'N/A')" | tee -a /var/log/nat-setup.log

    echo "=== NAT masquerade configured on $DEFAULT_IF for ${var.private_subnet_cidr} ===" | tee -a /var/log/nat-setup.log
  EOF

  # Primary instance cloud-init
  cloud_init_primary = <<-EOF
    #!/bin/bash
    set -e
    ${local.cloud_init_nat}
    echo "NAT primary configuration complete"
  EOF

}

# Security list for NAT instance - allows forwarded traffic from private subnet
resource "oci_core_security_list" "nat" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.display_name}-security-list"

  # Egress: Allow all outbound (NAT'd traffic)
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  # Ingress: Allow all traffic from private subnet (to be NAT'd)
  ingress_security_rules {
    protocol    = "all"
    source      = var.private_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false
  }

  # Ingress: SSH from private subnet for management
  ingress_security_rules {
    protocol    = "6"
    source      = var.private_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 22
      max = 22
    }
  }
}

# =============================================================================
# Primary NAT Instance
# =============================================================================

resource "oci_core_instance" "nat" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = var.display_name
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type = "image"
    source_id   = var.image_id
  }

  create_vnic_details {
    subnet_id              = var.subnet_id
    assign_public_ip       = true
    skip_source_dest_check = true
    display_name           = "${var.display_name}-vnic"
    nsg_ids                = []
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init_primary)
  }
}

# Get VNIC attachments for the primary NAT instance
data "oci_core_vnic_attachments" "nat" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.nat.id
}

# Get the primary VNIC
data "oci_core_vnic" "nat" {
  vnic_id = data.oci_core_vnic_attachments.nat.vnic_attachments[0].vnic_id
}

# Get the private IP OCID (needed for route table target)
data "oci_core_private_ips" "nat" {
  vnic_id = data.oci_core_vnic.nat.id
}

# =============================================================================
# Standby NAT Instance (HA mode only)
# =============================================================================

resource "oci_core_instance" "nat_standby" {
  count = var.enable_ha ? 1 : 0

  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = "${var.display_name}-standby"
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type = "image"
    source_id   = var.image_id
  }

  create_vnic_details {
    subnet_id              = var.subnet_id
    assign_public_ip       = true
    skip_source_dest_check = true
    display_name           = "${var.display_name}-standby-vnic"
    nsg_ids                = []
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/templates/standby-cloud-init.sh.tftpl", {
      private_subnet_cidr = var.private_subnet_cidr
      primary_private_ip  = oci_core_instance.nat.private_ip
      route_table_id      = var.route_table_id
    }))
  }
}

# Get VNIC attachments for standby
data "oci_core_vnic_attachments" "nat_standby" {
  count = var.enable_ha ? 1 : 0

  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.nat_standby[0].id
}

data "oci_core_vnic" "nat_standby" {
  count = var.enable_ha ? 1 : 0

  vnic_id = data.oci_core_vnic_attachments.nat_standby[0].vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "nat_standby" {
  count = var.enable_ha ? 1 : 0

  vnic_id = data.oci_core_vnic.nat_standby[0].id
}

# =============================================================================
# IAM Policy for Standby Instance Principal (HA mode only)
# =============================================================================
# Allows the standby instance to update route tables on failover

resource "oci_identity_dynamic_group" "nat_standby" {
  count = var.enable_ha ? 1 : 0

  compartment_id = var.compartment_id
  name           = "${var.display_name}-standby-dg"
  description    = "Dynamic group for NAT standby instance failover"
  matching_rule  = "instance.id = '${oci_core_instance.nat_standby[0].id}'"
}

resource "oci_identity_policy" "nat_failover" {
  count = var.enable_ha ? 1 : 0

  compartment_id = var.compartment_id
  name           = "${var.display_name}-failover-policy"
  description    = "Allow NAT standby to update route tables on failover"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.nat_standby[0].name} to manage route-tables in compartment id ${var.compartment_id}"
  ]
}
