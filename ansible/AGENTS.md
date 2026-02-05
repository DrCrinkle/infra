# ANSIBLE KNOWLEDGE BASE

## OVERVIEW

Security-hardened server configuration for AlmaLinux/RHEL. Deploys OpenClaw as unprivileged systemd user service with 4-layer defense.

## STRUCTURE

```
ansible/
├── site.yml                    # Main playbook
├── inventory/
│   ├── hosts.yml               # Production inventory
│   └── hosts.local.yml         # Local/dev inventory
├── group_vars/
│   └── all/
│       ├── vars.yml            # Configuration variables
│       └── vault.yml           # Secrets (ansible-vault encrypted)
└── roles/
    ├── common/                 # Base packages, user lingering
    ├── firewall/               # firewalld + Docker isolation
    ├── docker/                 # Docker CE with security config
    ├── nodejs/                 # Node.js 22.x, unprivileged npm
    ├── tailscale/              # Mesh VPN + NTP sync
    └── openclaw/               # App deployment, systemd user service
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Add new role | `roles/` (copy existing structure) |
| Add secret | `group_vars/all/vault.yml` |
| Change app config | `roles/openclaw/templates/` |
| Modify firewall | `roles/firewall/tasks/main.yml` |
| Update target host | `inventory/hosts.yml` |

## ROLE EXECUTION ORDER

```
site.yml
  1. common      → Base setup, enable lingering
  2. firewall    → Lock down before services
  3. docker      → Runtime (conditional)
  4. nodejs      → Runtime
  5. tailscale   → Secure tunnel (conditional)
  6. openclaw    → Application
```

## CONVENTIONS

### Secrets
- Store in `group_vars/all/vault.yml`
- Prefix with `vault_` (e.g., `vault_discord_token`)
- Reference as `{{ vault_* }}` in templates
- Run with `--ask-vault-pass`

### Services
- Use systemd **user** scope (`~/.config/systemd/user/`)
- Enable lingering: `loginctl enable-linger {{ ansible_user }}`
- Bind to loopback, expose via Tailscale Serve

### Firewall
- Default zone: `drop`
- Allowed: SSH, Tailscale (41641/udp)
- Docker isolation: DOCKER-USER chain blocks eth0→containers

## 4-LAYER SECURITY

| Layer | Implementation |
|-------|---------------|
| 1. Network | firewalld drop zone, explicit allows only |
| 2. Container | DOCKER-USER chain: `-i eth0 -j DROP` |
| 3. Application | Loopback bind + Tailscale Serve |
| 4. Process | Systemd: NoNewPrivileges, PrivateTmp |

## ANTI-PATTERNS

| Pattern | Why |
|---------|-----|
| Run as root | Use systemd user services |
| Public port binds | Bind loopback, use Tailscale |
| Skip `--ask-vault-pass` | Secrets won't decrypt |
| Forget lingering | User services die on logout |

## COMMANDS

```bash
# Full deployment
ansible-playbook site.yml --ask-vault-pass

# Single role
ansible-playbook site.yml --tags openclaw --ask-vault-pass

# Dry run
ansible-playbook site.yml --check --ask-vault-pass

# Edit secrets
ansible-vault edit group_vars/all/vault.yml
```

## VARIABLES (KEY)

| Variable | Default | Notes |
|----------|---------|-------|
| `openclaw_install_method` | git | git or npm |
| `openclaw_gateway_bind` | loopback | loopback or lan |
| `openclaw_exec_security` | allowlist | allowlist or full |
| `docker_enabled` | true | Skip docker role if false |
| `tailscale_enabled` | true | Skip tailscale role if false |

## NOTES

- **AlmaLinux 10**: Docker uses CentOS 9 repo (compatibility hack)
- **Clock drift**: tailscale role runs `chronyc makestep` (auth fails if clock wrong)
- **Pre-flight check**: `scripts/pre-ansible-healthcheck.sh` verifies connectivity
- **NPM global**: Uses `~/.npm-global` to avoid sudo
