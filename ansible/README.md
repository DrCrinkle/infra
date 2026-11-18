# OpenClaw Ansible Deployment

Security-hardened Ansible playbooks for deploying OpenClaw on AlmaLinux/RHEL.

Ported from [openclaw-ansible](https://github.com/openclaw/openclaw-ansible) with AlmaLinux support.

## Quick Start

```bash
cp group_vars/vault.yml.example group_vars/vault.yml
ansible-vault encrypt group_vars/vault.yml
ansible-vault edit group_vars/vault.yml

ansible-playbook site.yml --ask-vault-pass
```

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
| claude_mem_pilot | Synthetic claude-mem pilot worker; separate `claude-mem-pilot.yml` playbook, not in `site.yml` (see [claude-mem-pilot.md](claude-mem-pilot.md)) |

## Configuration

`group_vars/all.yml`:
- `openclaw_install_method`: git or npm
- `openclaw_gateway_bind`: loopback (secure) or lan
- `openclaw_exec_security`: allowlist (safe) or full
- `docker_enabled`: Enable Docker for agent sandboxes
- `tailscale_serve_mode`: serve for HTTPS, off to disable

`group_vars/vault.yml` (encrypted):
- `vault_openclaw_gateway_token`
- `vault_nvidia_api_key`
- `vault_tailscale_auth_key`
- `vault_discord_token`

## Verification

```bash
nmap -p- YOUR_SERVER_IP
```

Should show only port 22 (SSH). All other services locked behind Tailscale.
