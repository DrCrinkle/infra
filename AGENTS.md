# PROJECT KNOWLEDGE BASE

**Generated:** 2026-02-05
**Commit:** 91c1665
**Branch:** main

## OVERVIEW

Infrastructure-as-Code for personal cloud services on OCI (Oracle Cloud Infrastructure). Terraform provisions resources, Ansible configures them. Optimized for OCI Always Free tier with custom NAT instance and 4-layer security.

## STRUCTURE

```
infra/
├── terraform/          # OCI provisioning (VCN, compute, bastion, NAT)
│   └── modules/        # networking, nat-instance, security
├── ansible/            # Server config (6 roles, systemd user services)
│   ├── roles/          # common, firewall, docker, nodejs, tailscale, openclaw
│   └── group_vars/     # vars.yml + vault.yml (encrypted)
├── scripts/            # Verification scripts (verify-nat.sh, healthcheck)
└── backups/            # Pre-migration state backups
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add OCI resource | `terraform/main.tf` | Use existing modules when possible |
| Modify network rules | `terraform/modules/networking/main.tf` | OCI Security Lists are allow-only |
| Change NAT config | `terraform/modules/nat-instance/` | Has HA failover capability |
| Add Ansible role | `ansible/roles/` | Follow existing pattern |
| Add secrets | `ansible/group_vars/all/vault.yml` | Prefix with `vault_`, encrypt with ansible-vault |
| Verify NAT works | `scripts/verify-nat.sh` | Run after terraform apply |

## CONVENTIONS

### Terraform
- Remote state in OCI Object Storage (`terraform-state` bucket)
- Modules: `networking`, `nat-instance`, `security`
- 90s `time_sleep` after NAT creation (cloud-init completion)

### Ansible
- Secrets prefixed `vault_*` in `group_vars/all/vault.yml`
- Services run as systemd user units (not root)
- `loginctl enable-linger` for persistent user services

### Security (4-Layer Defense)
1. **Firewall**: `firewalld` drop zone default, SSH + Tailscale only
2. **Docker**: DOCKER-USER chain blocks external container access
3. **Gateway**: Services bind to loopback, exposed via Tailscale Serve
4. **Systemd**: NoNewPrivileges, PrivateTmp, ProtectSystem

## ANTI-PATTERNS (THIS PROJECT)

| Pattern | Why Forbidden |
|---------|---------------|
| Public IPs on compute *(see exception)* | Default: access via Bastion/Tailscale. **Exception (2026-05-30): OpenClaw runs in the public subnet with an ephemeral public IP for direct ~4 Gbps IGW egress. Ingress is still fully sealed (subnet SL allows no internet inbound; NSG allows only Tailscale UDP 41641; firewalld drop zone). The public IP is egress-only — Tailscale remains the sole way in.** Do not add public IPs to other instances. |
| `0.0.0.0/0` ingress | Never except LB ports 80/443 |
| Running as root | Use systemd user services |
| Same KMS key for state+app | Separate encryption domains |

## UNIQUE STYLES

- **OpenClaw-as-NAT (since 2026-05-30)**: The dedicated fck-nat micro instance was removed. OpenClaw (public subnet, A1.Flex) is the private subnet's NAT router via `skip_source_dest_check` + nftables masquerade (`ip saddr 10.0.1.0/24 … masquerade`) + `ip_forward`. Replaced the E2.1.Micro NAT, which capped egress at ~48 Mbps.
- **Manual Terraform→Ansible handoff**: Update `inventory/hosts.yml` with IP after `terraform apply`
- **AlmaLinux 10 + CentOS 9 repos**: Docker CE uses CentOS 9 repo for compatibility

## COMMANDS

```bash
# Infrastructure
cd terraform
terraform init -backend-config="namespace=$TF_VAR_oci_namespace"
terraform plan
terraform apply

# Verification
./scripts/verify-nat.sh

# Configuration
cd ansible
ansible-playbook site.yml --ask-vault-pass

# Secrets
ansible-vault edit group_vars/all/vault.yml
```

## OCI FREE TIER LIMITS

| Resource | Limit |
|----------|-------|
| ARM A1.Flex *(see note)* | Metered: 1,500 OCPU-hrs + 9,000 GB-hrs/month (= 2 OCPU + 12GB run 24/7) |
| x86 E2.1.Micro | 2 instances |
| Block Storage | 200GB total |
| Object Storage | 20GB |
| Outbound Data Transfer | 10TB/month |

> **A1.Flex note (changed ~2026-06, silently):** Oracle moved A1 Always Free from a flat **4 OCPU / 24GB always-on** to a metered **1,500 OCPU-hrs + 9,000 GB-hrs/month** model — effectively **2 OCPU + 12GB** if run continuously. Oracle published **no announcement** and made **no official statement about grandfathering** existing instances — the only official artifact is the docs page listing the new numbers. This account showed **$0 on 1,776 OCPU-hrs as of 2026-06-19** (an *observation*, not a documented guarantee — possibly billing lag, not policy). Because there is no documented protection, OpenClaw was **downgraded to 2 OCPU / 12GB on 2026-06-19** so it sits inside the new caps under both the old and new models. Note: consequences of exceeding the cap differ by account type — PAYG may be *charged*, free-only may have resources *reclaimed/disabled* (both per secondhand Oracle Support reports, not official). Idle reclamation: instance reclaimed if 95th-pct CPU/network/memory all <20% over any 7-day window.

## NOTES

- **Bastion sessions expire**: Recreate via OCI Console or CLI
- **Tailscale auth keys expire**: Check `vault.yml` before migration
- **Clock drift breaks Tailscale**: `chronyc makestep` runs in tailscale role
- **State backup before migration**: `scripts/backup-pre-migration.sh`
- **CLAUDE.md files**: Contain auto-generated memory context only
