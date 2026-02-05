variable "compartment_id" {
  description = "OCI compartment OCID"
  type        = string
}

variable "vcn_name" {
  description = "Display name for the VCN"
  type        = string
}

variable "vcn_cidr_blocks" {
  description = "CIDR blocks for the VCN"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "public_subnet_additional_security_list_ids" {
  description = "Additional security list OCIDs to attach to the public subnet (e.g., NAT security list for transit traffic)"
  type        = list(string)
  default     = []
}

