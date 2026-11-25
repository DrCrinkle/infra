resource "oci_core_volume" "claude_mem_pilot" {
  availability_domain = oci_core_instance.openclaw.availability_domain
  compartment_id      = oci_core_instance.openclaw.compartment_id
  display_name        = "claude-mem-pilot"
  size_in_gbs         = 50
  vpus_per_gb         = 10

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_core_volume_attachment" "claude_mem_pilot" {
  attachment_type                     = "paravirtualized"
  instance_id                         = oci_core_instance.openclaw.id
  volume_id                           = oci_core_volume.claude_mem_pilot.id
  is_pv_encryption_in_transit_enabled = false
}
