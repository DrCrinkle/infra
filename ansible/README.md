# OpenClaw Ansible Deployment

Security-hardened Ansible playbooks for deploying OpenClaw on AlmaLinux/RHEL.

Ported from [openclaw-ansible](https://github.com/openclaw/openclaw-ansible) with AlmaLinux support.

## Quick Start

`inventory/hosts.local.yml` is private. Set each host's address or SSH alias,
user, port, and any jump host there or in your local SSH config.

```bash
ansible-vault create group_vars/all/vault.yml
ansible-playbook -i inventory/hosts.local.yml site.yml --ask-vault-pass
```

Use `group_vars/vault.yml.example` as the variable list. In the private Vault, set
`vault_openclaw_vault_id` to the value of
`terraform -chdir=../terraform output -raw openclaw_vault_ocid` from an initialized
Terraform checkout. OpenClaw recovery installs the ID for the SSH user with
mode `0600` before replacing the resolver. The OCI Vault must already contain the
`gateway-auth-token`, `discord-token`, and `memorysearch-remote-apikey` secrets
and grant the guest instance principal access. A fresh seed references all
three as OCI exec SecretRefs, so no credential is written to `openclaw.json`.

## SSH host key bootstrap

Pin the host keys for **OpenClaw**, **Sentinel**, and **Edge Lab** on the
controller before deploying. Obtain each guest's public host key from an
authenticated OCI console session or from an SSH session that already checks
that guest against an independently trusted pin. For Sentinel and Edge Lab,
an existing trusted controller can retrieve the keys over its guest SSH
connections. Keep strict checking enabled on each hop, including on jump hosts.

On each guest, use the console or the verified SSH session to read the key
and its fingerprint.

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Transfer that public key to the controller, compare its fingerprint with the
one from the trusted session, and add it to the controller's `~/.ssh/known_hosts`.
Repeat for each guest. The lookup name is the SSH destination, `[host]:port`
for a nonstandard port, or the configured `HostKeyAlias` if you set one.

```bash
ssh-keygen -lf "$verified_public_key_file"
printf '%s %s\n' "$known_hosts_name" \
  "$(awk '{print $1, $2}' "$verified_public_key_file")" >> ~/.ssh/known_hosts
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no \
  "$ssh_destination" true
```

Use the same route, user, and port as the inventory for the connection test.
Ansible rejects an unknown or changed key. If a guest was rebuilt or its key
rotated, verify the replacement over the trusted console before updating the
pin.

## OpenClaw recovery preview

```bash
ansible-playbook -i inventory/hosts.local.yml site.yml --limit openclaw \
  --tags openclaw_recovery --check --diff --ask-vault-pass
```

On an existing host, the task that compares the OpenClaw config reports
`ok` when the recovery invariants match. Secret-bearing tasks suppress
their diffs and results. An existing config can be checked without the private
Vault file, in which case the preview checks the vault-ID file's presence
and permissions. With the private Vault loaded, it also compares the file
contents. A fresh-host preview needs the Discord allowlist and guild variables from the
private Vault.

## 4-Layer Security Architecture

1. **Firewall (firewalld)**: Drop zone default, SSH + Tailscale only
2. **Docker Isolation**: DOCKER-USER chain blocks external container access
3. **Gateway**: Loopback bind + Tailscale Serve for HTTPS
4. **Systemd Hardening**: NoNewPrivileges, PrivateTmp, ProtectSystem

## What Gets Installed

- **firewalld**: Drop zone, SSH/Tailscale ports only
- **Docker CE**: Agent sandboxes with network isolation
- **Tailscale**: Mesh VPN with automatic HTTPS (Tailscale Serve)
- **Node.js 22.x**: Runtime
- **OpenClaw**: Gateway with systemd hardening

## Roles

| Role | Purpose |
|------|---------|
| common | Base packages, user lingering |
| firewall | firewalld + Docker isolation rules |
| docker | Docker CE with security config |
| nodejs | Node.js 22.x via NodeSource |
| tailscale | Mesh VPN + auth |
| openclaw | Gateway, config, systemd service |

## Configuration

`group_vars/all/vars.yml`:
- `openclaw_install_method`: git or npm
- `openclaw_gateway_bind`: loopback (secure) or lan
- `openclaw_exec_security` and `openclaw_exec_ask`: defaults for the fresh host's approvals file
- `docker_enabled`: Enable Docker for agent sandboxes
- `tailscale_serve_mode`: serve for HTTPS, off to disable

`group_vars/all/vault.yml` (encrypted):
- `vault_openclaw_vault_id`
- `vault_tailscale_auth_key`

## Verification

```bash
nmap -p- YOUR_SERVER_IP
```

Should show only port 22 (SSH). All other services locked behind Tailscale.
