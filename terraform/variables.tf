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

variable "openclaw_boot_volume_id" {
  description = "Boot volume OCID to restore OpenClaw from. If set, instance boots from this volume instead of the base image."
  type        = string
  default     = null
}
