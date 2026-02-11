output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.this.id
}

output "public_subnet_id" {
  description = "OCID of the public subnet"
  value       = oci_core_subnet.public.id
}

output "default_route_table_id" {
  description = "OCID of the default route table"
  value       = oci_core_vcn.this.default_route_table_id
}

output "default_security_list_id" {
  description = "OCID of the default security list"
  value       = oci_core_vcn.this.default_security_list_id
}

output "service_gateway_id" {
  description = "OCID of the service gateway"
  value       = oci_core_service_gateway.this.id
}

output "all_services_cidr" {
  description = "CIDR block for OCI Object Storage services"
  value       = data.oci_core_services.object_storage.services[0].cidr_block
}

output "vcn_ipv6cidr_blocks" {
  description = "Oracle-allocated IPv6 /56 prefixes for the VCN"
  value       = oci_core_vcn.this.ipv6cidr_blocks
}

output "internet_gateway_id" {
  description = "OCID of the internet gateway"
  value       = oci_core_internet_gateway.this.id
}


