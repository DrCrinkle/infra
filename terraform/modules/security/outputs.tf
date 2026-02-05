output "kms_key_id" {
  description = "KMS key ID for boot volume encryption"
  value       = oci_kms_key.main.id

  depends_on = [oci_identity_policy.block_storage_kms]
}

output "vault_id" {
  description = "OCI Vault ID"
  value       = oci_kms_vault.main.id
}
