# Primary instance outputs
output "instance_id" {
  description = "OCID of the primary NAT instance"
  value       = oci_core_instance.nat.id
}

output "private_ip" {
  description = "Private IP address of the primary NAT instance"
  value       = oci_core_instance.nat.private_ip
}

output "private_ip_id" {
  description = "OCID of the primary NAT instance's private IP (use as route table target)"
  value       = data.oci_core_private_ips.nat.private_ips[0].id
}

output "public_ip" {
  description = "Public IP of the primary NAT instance"
  value       = oci_core_instance.nat.public_ip
}

output "ipv6_address" {
  description = "IPv6 address of the primary NAT instance"
  value       = try(data.oci_core_vnic.nat.ipv6addresses[0], null)
}

output "security_list_id" {
  description = "OCID of the NAT security list"
  value       = oci_core_security_list.nat.id
}

# Standby instance outputs (HA mode only)
output "standby_instance_id" {
  description = "OCID of the standby NAT instance (null if HA disabled)"
  value       = try(oci_core_instance.nat_standby[0].id, null)
}

output "standby_private_ip" {
  description = "Private IP address of the standby NAT instance (null if HA disabled)"
  value       = try(oci_core_instance.nat_standby[0].private_ip, null)
}

output "standby_private_ip_id" {
  description = "OCID of the standby NAT instance's private IP (null if HA disabled)"
  value       = try(data.oci_core_private_ips.nat_standby[0].private_ips[0].id, null)
}
