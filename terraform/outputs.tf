# =============================================================================
# Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# NAT Instance
# -----------------------------------------------------------------------------

output "nat_instance_public_ip" {
  description = "Public IP of NAT instance (use as jump host)"
  value       = module.nat_instance.public_ip
}

output "nat_instance_private_ip" {
  description = "Private IP of NAT instance"
  value       = module.nat_instance.private_ip
}

output "nat_instance_ocid" {
  description = "OCID of NAT instance (for Bastion sessions and VNIC verification)"
  value       = module.nat_instance.instance_id
}

output "nat_instance_ipv6_address" {
  description = "IPv6 address of NAT instance (NAT64 gateway)"
  value       = module.nat_instance.ipv6_address
}

output "nat_instance_security_list_id" {
  description = "OCID of NAT instance security list"
  value       = module.nat_instance.security_list_id
}

# -----------------------------------------------------------------------------
# OpenClaw Instance
# -----------------------------------------------------------------------------

output "openclaw_private_ip" {
  description = "Private IP of openclaw instance"
  value       = oci_core_instance.openclaw.private_ip
}

output "openclaw_ocid" {
  description = "OCID of openclaw instance (for Bastion sessions)"
  value       = oci_core_instance.openclaw.id
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

output "vcn_id" {
  description = "OCID of the VCN"
  value       = module.networking.vcn_id
}

output "public_subnet_id" {
  description = "OCID of the public subnet (NAT instance)"
  value       = module.networking.public_subnet_id
}

output "private_subnet_id" {
  description = "OCID of the private subnet (openclaw)"
  value       = oci_core_subnet.private.id
}

output "private_route_table_id" {
  description = "OCID of the private subnet route table"
  value       = oci_core_route_table.private.id
}

# -----------------------------------------------------------------------------
# Bastion
# -----------------------------------------------------------------------------

output "bastion_ocid" {
  description = "OCID of the Bastion service"
  value       = oci_bastion_bastion.main.id
}

# -----------------------------------------------------------------------------
# SSH Commands (for convenience)
# -----------------------------------------------------------------------------

output "ssh_via_nat_jump" {
  description = "SSH command to reach openclaw via NAT jump host"
  value       = "ssh -J opc@${module.nat_instance.public_ip} opc@${oci_core_instance.openclaw.private_ip}"
}
