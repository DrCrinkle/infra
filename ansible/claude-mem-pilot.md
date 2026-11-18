# Synthetic claude-mem pilot

The dedicated playbook stages the worker. The pilot volume keeps OCI encryption at rest. Its paravirtualized attachment has in-transit encryption off because OpenClaw was launched without the in-transit launch option, and changing that would modify the instance. Run it after approval and after Terraform has attached the pilot volume. The regular OpenClaw playbook does not include this role.

1. Match the newly attached block device to the OCI pilot volume using the attachment and guest device identities. Initialize that verified empty device with ext4 and record the filesystem UUID. The playbook mounts by UUID and adds `nofail` to fstab. It does not format disks.
2. In the encrypted Ansible Vault, set separate `vault_claude_mem_pilot_ingest_token` and `vault_claude_mem_pilot_provider_token` values. The provider unit needs the same pilot provider token through its private configuration. Run the following from `ansible/` as the normal deploy operator.

   ```sh
   ansible-playbook -i inventory/hosts.yml claude-mem-pilot.yml --ask-vault-pass \
     -e 'claude_mem_pilot_volume_uuid=<verified-filesystem-uuid>'
   ```

3. Configure the provider route in the deployment that owns CLIProxy. The worker unit requires `claude-mem-pilot-provider.service` and will not start while that unit is missing or failed. Before starting the worker, confirm the provider exists and passes the alias-only and pilot-bearer stripping checks below. Once activation is approved, reload the user manager with `systemctl --user daemon-reload`, then start `claude-mem-pilot.service` with `systemctl --user start`. Enable it after confirming the correct mount, foreground operation and loopback listener.

## Provider route

Stage a separate `claude-mem-pilot-provider.service` on loopback port `37778` in the private CLIProxy deployment. Install it as a systemd user unit under the same operating-system account as the worker, so the worker's `Requires=` resolves in that user manager; a system unit or a unit owned by another account leaves the worker unable to start. Require the dedicated pilot bearer and accept only `POST /v1/chat/completions` with the exact model `lifeos-memory`. Reject other methods, paths, models and credentials before forwarding anything. Reuse the compatible adapter's existing alias selection and quota handling against its configured local CLIProxy upstream. Strip the pilot bearer, inject the approved upstream credential through the private configuration, and leave the existing Serve identity gate and listeners in place. The pilot listener has no Serve, Funnel or other external route. Confirm rejection of unauthorized requests against fixtures, and confirm against a capture fixture that the forwarded request carries the upstream credential and never the pilot bearer. This repository does not define the provider; it is a precondition for starting the worker.

## Activation checks

Use a synthetic marker to check the spool receipt, generated observation, and MCP recall. Check that the worker refuses to start without the expected mount and that a pilot-only restart preserves the marker. Exercise terminal quota, rate-limit retry and authentication failures against fixtures before sending a minimal synthetic generation through the approved model route. Record the selected model, billing path and disk usage. Enable Chroma only for the second synthetic run and check the ARM64 index build on the same volume. Stop the run before free space falls below 8 GiB.

For rollback, use that same account's user manager (`systemctl --user`) to stop and disable only the pilot worker and provider units. Retain the volume and synthetic state.
