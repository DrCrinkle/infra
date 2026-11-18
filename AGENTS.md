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
├── ansible/            # Server config (7 roles, systemd user services)
│   ├── roles/          # common, firewall, docker, nodejs, tailscale, openclaw, claude_mem_pilot
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
| Public IPs on compute *(see exception)* | Default: access via Bastion/Tailscale. **Exception — the "sealed egress-only public IP" pattern:** an instance may take an ephemeral public IP *only if* ingress stays fully sealed (subnet SL allows no internet inbound; per-VNIC NSG allows only Tailscale UDP 41641; firewalld drop zone) so the public IP is egress-only and Tailscale remains the sole way in. Instances using it: **OpenClaw** (2026-05-30, ~4 Gbps IGW egress + NAT router), **sentinel** and **edge-lab** (2026-07-10, the two free E2.1.Micro boxes — see `free-micros.tf`). Do not add a public IP to any instance without this exact seal. |
| `0.0.0.0/0` ingress | Never except LB ports 80/443 |
| Running as root | Use systemd user services |
| Same KMS key for state+app | Separate encryption domains |

## UNIQUE STYLES

- **OpenClaw-as-NAT (since 2026-05-30)**: The dedicated fck-nat micro instance was removed. OpenClaw (public subnet, A1.Flex) is the private subnet's NAT router via `skip_source_dest_check` + nftables masquerade (`ip saddr 10.0.1.0/24 … masquerade`) + `ip_forward`. Replaced the E2.1.Micro NAT, which capped egress at ~48 Mbps.
- **Hermes co-located on OpenClaw (since ~2026-07-07)**: The Hermes messaging-gateway agent runs alongside OpenClaw on the same A1 instance as a `systemctl --user` service (user `opc`, enabled + `Linger=yes`, survives reboot). Check it with `systemctl --user is-active hermes-gateway.service` — **system-scope `systemctl is-active` reports "inactive"/not-found because it's a user unit.** Kept co-located deliberately (box idles at ~1.5 GiB of 24; a dedicated instance would split the 4/24 A1 free pool). Split only when the private-subnet DB tier goes live or Hermes handles untrusted inbound — then move Hermes to a free E2.1.Micro.
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
| ARM A1.Flex *(see note)* | Flat 4 OCPU + 24GB always-on (PAYG not charged over the metered cap — see note) |
| x86 E2.1.Micro | 2 instances |
| Block Storage | 200GB total |
| Object Storage | 20GB |
| Outbound Data Transfer | 10TB/month |

> **A1.Flex note (updated 2026-07-07):** Oracle's docs list a metered A1 Always Free model (**1,500 OCPU-hrs + 9,000 GB-hrs/month** = 2 OCPU + 12GB continuous), changed silently ~2026-06 from the old flat **4 OCPU / 24GB always-on**. **This account is a PAYG account and is NOT charged for A1 over that cap** — two consecutive months observed at **$0** despite running ~75% over cap (June 1–July 7 2026: ~2,630 OCPU-hrs + ~15,782 GB-hrs, all $0.00 via `oci usage-api`). The 2026-06-19 downgrade to 2/12 was an unnecessary precaution; **OpenClaw was restored to 4 OCPU / 24GB on 2026-07-07** (in-place `shape_config` resize — `update in-place, 0 to destroy`, ~2m11s reboot, same OCID/IPs). OpenClaw now consumes the full tenancy A1 free pool. Caveat: metered enforcement differs by account type — free-only accounts may have resources *reclaimed/disabled*; PAYG (this account) is simply not billed for the Always Free A1 allotment. Verify the bill after adding any new A1 instance. Idle reclamation: instance reclaimed if 95th-pct CPU/network/memory all <20% over any 7-day window.

## NOTES

- **Bastion sessions expire**: Recreate via OCI Console or CLI
- **Tailscale auth keys expire**: Check `vault.yml` before migration
- **Clock drift breaks Tailscale**: `chronyc makestep` runs in tailscale role
- **State backup before migration**: `scripts/backup-pre-migration.sh`
- **CLAUDE.md files**: Contain auto-generated memory context only
