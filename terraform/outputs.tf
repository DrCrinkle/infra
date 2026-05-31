# =============================================================================
# Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# OpenClaw Instance (public subnet; direct IGW egress + NAT router for private subnet)
# -----------------------------------------------------------------------------

output "openclaw_private_ip" {
  description = "Private IP of openclaw instance (also the private subnet's NAT next-hop)"
  value       = oci_core_instance.openclaw.private_ip
}

output "openclaw_public_ip" {
  description = "Ephemeral public IP (egress only; inbound is sealed — access via Tailscale/Bastion)"
  value       = oci_core_instance.openclaw.public_ip
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
  description = "OCID of the public subnet (OpenClaw)"
  value       = module.networking.public_subnet_id
}

output "private_subnet_id" {
  description = "OCID of the private subnet (reserved for future DB tier; egresses via OpenClaw)"
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
# Access
# -----------------------------------------------------------------------------
# OpenClaw has no public ingress. Reach it via Tailscale (primary) or Bastion (break-glass):
#   tailscale:  ssh opc@openclaw          (or opc@100.104.160.85)
#   bastion:    oci bastion session create-port-forwarding --target-private-ip <openclaw_private_ip>
# Outputs intentionally omit a direct-SSH string since no internet-facing SSH exists.
