variable "compartment_id" {
  description = "OCI Compartment OCID (using tenancy root)"
  type        = string
}

variable "tenancy_id" {
  description = "OCI Tenancy OCID (for Cloud Guard, defaults to compartment_id)"
  type        = string
  default     = ""
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "us-sanjose-1"
}

variable "oci_namespace" {
  description = "OCI Object Storage namespace (for Terraform state backend)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

variable "nat_instance_image_id" {
  description = "x86 image OCID for NAT instance. Must support dnf, firewalld, iptables. Verify: oci compute image get --image-id <ocid>"
  type        = string
}
