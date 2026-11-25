# infra

Infrastructure as code for personal cloud services on Oracle Cloud Infrastructure (OCI).

## Structure

```
├── terraform/     # OCI infrastructure (VCN, compute, bastion)
└── ansible/       # Server configuration (OpenClaw, Docker, Tailscale)
```

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.0
- [Ansible](https://www.ansible.com/) >= 2.12
- OCI CLI configured (`~/.oci/config`)
- Tailscale account

## Quick Start

### 1. Provision Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCI values

terraform init -backend-config="namespace=$TF_VAR_oci_namespace"
terraform plan
terraform apply
```

### 2. Configure Server

```bash
cd ansible
cp group_vars/vault.yml.example group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml  # Add your secrets

# Update inventory/hosts.yml with your server IP
# Pin each host key first; see ansible/README.md#ssh-host-key-bootstrap
ansible-playbook site.yml --ask-vault-pass
```

## What's Deployed

| Component | Purpose |
|-----------|---------|
| VCN + Subnets | Network isolation |
| Compute (A1.Flex) | ARM instance (4 OCPU, 24GB) |
| Bastion | SSH access without public IP |
| OpenClaw | AI gateway with Discord integration |
| Tailscale | Mesh VPN + automatic HTTPS |
| Docker | Agent sandboxes |

## Security

- SSH restricted to bastion/Tailscale
- All services behind Tailscale (no public exposure)
- Secrets encrypted with ansible-vault
- Systemd hardening (NoNewPrivileges, PrivateTmp, etc.)

See [ansible/README.md](ansible/README.md) for security architecture details.
