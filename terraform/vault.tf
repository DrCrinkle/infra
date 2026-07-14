# =============================================================================
# OCI Vault — OpenClaw secrets (exec SecretRef backend)
# =============================================================================
# Backs OpenClaw's formerly-plaintext secrets via a runtime exec resolver on the
# box (/home/opc/.local/bin/oci-vault-resolver) that reads secret bundles using
# instance-principal auth. This file provisions ONLY the vault, key, dynamic
# group, and policy. The secret *values* are created out-of-band from the
# instance (via instance principal) so live credentials never land in TF state.
#
# Cost note: vault_type DEFAULT is the shared virtual vault (no hourly charge,
# unlike VIRTUAL_PRIVATE). protection_mode SOFTWARE key versions are free (HSM
# key versions are billed). Expected bill impact ~$0 on this PAYG account —
# verify after apply per the repo's standing "verify the bill" practice.

resource "oci_kms_vault" "openclaw_secrets" {
  compartment_id = var.compartment_id
  display_name   = "openclaw-secrets"
  vault_type     = "DEFAULT"
}

resource "oci_kms_key" "openclaw_secrets" {
  compartment_id      = var.compartment_id
  display_name        = "openclaw-secrets-key"
  management_endpoint = oci_kms_vault.openclaw_secrets.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32 # 256-bit
  }
}

# Dynamic group matches the live OpenClaw instance by OCID. Dynamic groups and
# their policies must live in the tenancy (root) compartment; compartment_id
# here is the tenancy root OCID, matching the existing nat_standby pattern.
resource "oci_identity_dynamic_group" "openclaw_secrets" {
  compartment_id = var.compartment_id
  name           = "openclaw-secrets-dg"
  description    = "OpenClaw instance principal — access to its own Vault secrets"
  matching_rule  = "instance.id = '${oci_core_instance.openclaw.id}'"
}

# Least-privilege runtime: the on-box exec resolver only READS secret bundles
# (GetSecretBundle) via instance principal. The 7 secrets were created once,
# during migration (2026-07-14), under a temporary "manage secret-family" grant
# that has since been narrowed to this single read statement. To create/rotate
# secrets from the box again, temporarily restore:
#   "Allow dynamic-group openclaw-secrets-dg to manage secret-family in compartment id ${var.compartment_id}"
#   "Allow dynamic-group openclaw-secrets-dg to use keys in compartment id ${var.compartment_id}"
resource "oci_identity_policy" "openclaw_secrets" {
  compartment_id = var.compartment_id
  name           = "openclaw-secrets-policy"
  description    = "Allow OpenClaw instance principal to read its Vault secret bundles (runtime resolver)."
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.openclaw_secrets.name} to read secret-bundles in compartment id ${var.compartment_id}",
  ]
}
