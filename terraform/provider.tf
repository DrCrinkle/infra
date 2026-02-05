terraform {
  required_version = ">= 1.0.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }

  # terraform init -backend-config="namespace=$TF_VAR_oci_namespace"
  backend "oci" {
    bucket = "terraform-state"
    key    = "infra/terraform.tfstate"
    region = "us-sanjose-1"
  }
}

provider "oci" {
  config_file_profile = "DEFAULT"
}
