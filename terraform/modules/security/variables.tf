variable "compartment_id" {
  description = "OCI Compartment OCID"
  type        = string
}

variable "tenancy_id" {
  description = "OCI Tenancy OCID (for Cloud Guard)"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
}
