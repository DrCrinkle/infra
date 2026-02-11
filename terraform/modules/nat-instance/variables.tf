variable "compartment_id" {
  description = "OCI Compartment OCID"
  type        = string
}

variable "availability_domain" {
  description = "Availability domain for the NAT instance"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet OCID where NAT instance will be placed"
  type        = string
}

variable "vcn_id" {
  description = "VCN OCID for security list"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR block of private subnet(s) that will use this NAT"
  type        = string
  default     = "10.0.1.0/24"
}

variable "display_name" {
  description = "Display name for the NAT instance"
  type        = string
  default     = "fck-nat"
}

variable "image_id" {
  description = "OCID of the image to use (Oracle Linux x86)"
  type        = string
}

variable "enable_ha" {
  description = "Enable HA mode with active/passive failover (uses 2 instances)"
  type        = bool
  default     = false
}

variable "route_table_id" {
  description = "Route table OCID to update on failover (required if enable_ha = true)"
  type        = string
  default     = null
}

variable "private_subnet_ipv6_cidr" {
  description = "IPv6 CIDR of the private subnet (for NAT64 traffic)"
  type        = string
  default     = null
}
