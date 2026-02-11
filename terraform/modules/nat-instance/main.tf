# =============================================================================
# NAT Instance (fck-nat style for OCI free tier)
# =============================================================================
# Uses VM.Standard.E2.1.Micro (1 OCPU, 1GB RAM) - Always Free eligible
# Configures IP forwarding and nftables masquerade via cloud-init
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

    # Enable IPv6 forwarding
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/98-nat.conf
    sysctl -w net.ipv6.conf.all.forwarding=1

    # Disable reverse path filtering
    for i in /proc/sys/net/ipv4/conf/*/rp_filter; do
      echo 0 > "$i"
    done
    echo "net.ipv4.conf.all.rp_filter = 0" >> /etc/sysctl.d/98-nat.conf
    echo "net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.d/98-nat.conf

    # Conntrack tuning for VM.Standard.E2.1.Micro (prevents exhaustion under load)
    {
      echo "net.netfilter.nf_conntrack_max = 131072"
      echo "net.netfilter.nf_conntrack_tcp_timeout_established = 600"
      echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
      echo "net.netfilter.nf_conntrack_udp_timeout = 30"
      echo "net.netfilter.nf_conntrack_udp_timeout_stream = 120"
    } >> /etc/sysctl.d/98-nat.conf

    # Queueing and buffer tuning for improved throughput/latency under burst
    {
      echo "net.core.default_qdisc = fq_codel"
      echo "net.core.netdev_max_backlog = 8192"
      echo "net.core.rmem_max = 16777216"
      echo "net.core.wmem_max = 16777216"
      echo "net.ipv4.tcp_rmem = 4096 87380 16777216"
      echo "net.ipv4.tcp_wmem = 4096 65536 16777216"
    } >> /etc/sysctl.d/98-nat.conf
    
    # Load conntrack module and apply settings
    modprobe nf_conntrack 2>/dev/null || true
    sysctl -p /etc/sysctl.d/98-nat.conf 2>/dev/null || true

    # Adapt conntrack table size to available RAM (bounded for E2.1.Micro class hosts)
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    CONNTRACK_MAX=$((MEM_KB / 8))
    if [ "$CONNTRACK_MAX" -lt 32768 ]; then
      CONNTRACK_MAX=32768
    fi
    if [ "$CONNTRACK_MAX" -gt 262144 ]; then
      CONNTRACK_MAX=262144
    fi
    CONNTRACK_HASHSIZE=$((CONNTRACK_MAX / 4))
    sysctl -w net.netfilter.nf_conntrack_max="$CONNTRACK_MAX" 2>/dev/null || true
    echo "net.netfilter.nf_conntrack_max = $CONNTRACK_MAX" >> /etc/sysctl.d/98-nat.conf
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
      echo "$CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize || true
    fi
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

    # Update kernel so kernel-devel in repos matches (base image may lag behind)
    echo "=== Updating kernel ===" | tee -a /var/log/nat-setup.log
    dnf update -y kernel 2>&1 | tail -5 | tee -a /var/log/nat-setup.log

    # Install nftables if not present
    if ! command -v nft &> /dev/null; then
      echo "Installing nftables..." | tee -a /var/log/nat-setup.log
      dnf install -y nftables 2>/dev/null || yum install -y nftables 2>/dev/null || true
    fi

    # Install ethtool for NIC feature verification/tuning
    if ! command -v ethtool &> /dev/null; then
      dnf install -y ethtool 2>/dev/null || yum install -y ethtool 2>/dev/null || true
    fi

    # Configure NAT masquerade
    if command -v nft &> /dev/null; then
      echo "Using nftables for NAT" | tee -a /var/log/nat-setup.log
      mkdir -p /etc/nftables

      # Load flowtable modules when available
      modprobe nf_flow_table 2>/dev/null || true
      modprobe nf_flow_table_ipv4 2>/dev/null || true

      cat > /etc/nftables/nat.nft << NFTEOF
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${var.private_subnet_cidr} oifname "$DEFAULT_IF" masquerade
    }
}

table inet filter {
    flowtable f {
        hook ingress priority 0;
        devices = { $${DEFAULT_IF} };
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        ip protocol { tcp, udp } flow add @f
        ip saddr ${var.private_subnet_cidr} oifname "$DEFAULT_IF" tcp flags syn tcp option maxseg size set rt mtu
    }
}
NFTEOF

      touch /etc/sysconfig/nftables.conf
      grep -qF 'include "/etc/nftables/nat.nft"' /etc/sysconfig/nftables.conf || echo 'include "/etc/nftables/nat.nft"' >> /etc/sysconfig/nftables.conf
      systemctl enable --now nftables

      if command -v ethtool &> /dev/null; then
        ethtool -K "$DEFAULT_IF" gro on gso on tso on rx on tx on 2>/dev/null || true
        ethtool -k "$DEFAULT_IF" | grep -E 'generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|rx-checksumming|tx-checksumming' | tee -a /var/log/nat-setup.log || true
      fi

      echo "nftables NAT configured" | tee -a /var/log/nat-setup.log
      nft list ruleset | tee -a /var/log/nat-setup.log
    elif command -v iptables &> /dev/null; then
      echo "Using iptables fallback for NAT" | tee -a /var/log/nat-setup.log
      iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -s ${var.private_subnet_cidr} -j MASQUERADE
      iptables -t mangle -A FORWARD -o "$DEFAULT_IF" -p tcp --tcp-flags SYN,RST SYN -s ${var.private_subnet_cidr} -j TCPMSS --clamp-mss-to-pmtu

      if command -v iptables-save &> /dev/null; then
        mkdir -p /etc/sysconfig
        iptables-save > /etc/sysconfig/iptables
      fi

      if systemctl list-unit-files | grep -q iptables; then
        systemctl enable --now iptables
      fi

      if command -v ethtool &> /dev/null; then
        ethtool -K "$DEFAULT_IF" gro on gso on tso on rx on tx on 2>/dev/null || true
      fi

      iptables -t nat -L POSTROUTING -n | tee -a /var/log/nat-setup.log
    else
      echo "ERROR: Neither nftables nor iptables available" | tee -a /var/log/nat-setup.log
      exit 1
    fi

    # =================================================================
    # Jool NAT64 (DKMS)
    # =================================================================
    echo "=== Installing Jool NAT64 ===" | tee -a /var/log/nat-setup.log

    # Install DKMS and build dependencies
    dnf install -y epel-release 2>/dev/null || true
    dnf install -y dkms gcc make kernel-devel libnl3-devel

    # Determine newest installed kernel (may differ from running kernel after dnf update)
    NEW_KERNEL=$(rpm -q --last kernel | head -1 | sed 's/kernel-//;s/ .*//')
    echo "Running kernel: $(uname -r), target kernel: $NEW_KERNEL" | tee -a /var/log/nat-setup.log

    # Download and install Jool 4.1.14
    JOOL_VERSION="4.1.14"
    cd /usr/src
    curl -fsSL "https://github.com/NICMx/Jool/releases/download/v$${JOOL_VERSION}/jool-$${JOOL_VERSION}.tar.gz" | tar xz
    dkms install "jool-$${JOOL_VERSION}/" -k "$NEW_KERNEL"

    # Build and install userspace tools
    cd "/usr/src/jool-$${JOOL_VERSION}/"
    dnf install -y autoconf automake libtool pkg-config iptables-devel 2>/dev/null || true
    autoreconf -i 2>/dev/null || true
    ./configure
    make -j$(nproc)
    make install
    ldconfig

    # Persist module loading (Jool loads after reboot into new kernel)
    echo "jool" > /etc/modules-load.d/jool.conf

    # Persist Jool config across reboots
    mkdir -p /etc/jool
    cat > /etc/jool/nat64.conf << 'JOOLEOF'
{
    "instance": "nat64",
    "framework": "netfilter",
    "global": {
        "pool6": "64:ff9b::/96"
    }
}
JOOLEOF

    # Create systemd unit to restore Jool config on boot
    cat > /etc/systemd/system/jool-nat64.service << 'SVCEOF'
[Unit]
Description=Jool NAT64
After=network.target
Requires=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/jool file handle /etc/jool/nat64.conf
ExecStop=/usr/local/bin/jool instance remove "nat64"

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable jool-nat64.service

    echo "Jool NAT64 configured with prefix 64:ff9b::/96 (active after reboot)" | tee -a /var/log/nat-setup.log

    # =================================================================
    # DNS64 (unbound)
    # =================================================================
    echo "=== Installing unbound for DNS64 ===" | tee -a /var/log/nat-setup.log

    dnf install -y unbound 2>/dev/null || true

    # Get the NAT instance's IPv6 address for listening
    NAT_IPV6=$(ip -6 addr show dev "$DEFAULT_IF" scope global | grep -oP '(?<=inet6 )[\da-f:]+' | head -1)

    cat > /etc/unbound/conf.d/dns64.conf << UNBOUNDEOF
server:
    interface: 127.0.0.1
    interface: ::1
    interface: $(ip -4 addr show dev "$DEFAULT_IF" | grep -oP '(?<=inet )[\d.]+' | head -1)
UNBOUNDEOF

    # Only bind IPv6 if we have a global address
    if [ -n "$NAT_IPV6" ]; then
      echo "    interface: $NAT_IPV6" >> /etc/unbound/conf.d/dns64.conf
    fi

    cat >> /etc/unbound/conf.d/dns64.conf << 'UNBOUNDEOF'
    access-control: 10.0.0.0/8 allow
    access-control: fd00::/8 allow
    access-control: 2000::/3 allow
    access-control: ::1/128 allow

    module-config: "dns64 validator iterator"

    dns64-prefix: 64:ff9b::/96

forward-zone:
    name: "."
    forward-addr: 1.1.1.1
UNBOUNDEOF

    systemctl enable --now unbound
    echo "unbound DNS64 configured with prefix 64:ff9b::/96" | tee -a /var/log/nat-setup.log

    # Verify configuration
    echo "=== Verification ===" | tee -a /var/log/nat-setup.log
    echo "ip_forward: $(sysctl -n net.ipv4.ip_forward)" | tee -a /var/log/nat-setup.log
    echo "ipv6_forward: $(sysctl -n net.ipv6.conf.all.forwarding)" | tee -a /var/log/nat-setup.log
    echo "conntrack_max: $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'N/A')" | tee -a /var/log/nat-setup.log
    echo "unbound: $(systemctl is-active unbound 2>/dev/null || echo 'N/A')" | tee -a /var/log/nat-setup.log
    echo "jool: will activate after reboot into kernel $NEW_KERNEL" | tee -a /var/log/nat-setup.log

    echo "=== NAT masquerade configured on $DEFAULT_IF for ${var.private_subnet_cidr} ===" | tee -a /var/log/nat-setup.log

    # Reboot into updated kernel so Jool module loads
    echo "=== Rebooting into new kernel ===" | tee -a /var/log/nat-setup.log
    reboot
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

  # Egress: Allow all IPv6 outbound
  egress_security_rules {
    destination      = "::/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }

  # Ingress: Allow all IPv6 from private subnet (NAT64 traffic)
  dynamic "ingress_security_rules" {
    for_each = var.private_subnet_ipv6_cidr != null ? [1] : []
    content {
      protocol    = "all"
      source      = var.private_subnet_ipv6_cidr
      source_type = "CIDR_BLOCK"
      stateless   = false
    }
  }

  # Ingress: DNS64 (UDP 53) from private subnet IPv6
  dynamic "ingress_security_rules" {
    for_each = var.private_subnet_ipv6_cidr != null ? [1] : []
    content {
      protocol    = "17"
      source      = var.private_subnet_ipv6_cidr
      source_type = "CIDR_BLOCK"
      stateless   = false

      udp_options {
        min = 53
        max = 53
      }
    }
  }

  # Ingress: DNS64 (TCP 53) from private subnet IPv6
  dynamic "ingress_security_rules" {
    for_each = var.private_subnet_ipv6_cidr != null ? [1] : []
    content {
      protocol    = "6"
      source      = var.private_subnet_ipv6_cidr
      source_type = "CIDR_BLOCK"
      stateless   = false

      tcp_options {
        min = 53
        max = 53
      }
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
    assign_ipv6ip          = true
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
