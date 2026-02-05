# Terraform - OCI Infrastructure

Oracle Cloud Infrastructure provisioning for personal cloud services.

## Resources

| Resource | Description |
|----------|-------------|
| VCN | Virtual cloud network (10.0.0.0/16) |
| Subnet | Public subnet with NAT egress (no public IPs on instances) |
| NAT Gateway | Outbound internet access |
| Internet Gateway | For future load balancer use |
| Compute | ARM A1.Flex (4 OCPU, 24GB RAM) |
| Bastion | SSH access without exposing instances |

## Usage

```bash
# Configure credentials
cp terraform.tfvars.example terraform.tfvars
# Edit with your OCI values

# Initialize with remote state
terraform init -backend-config="namespace=$TF_VAR_oci_namespace"

# Preview and apply
terraform plan
terraform apply
```

## Variables

| Variable | Description |
|----------|-------------|
| `compartment_id` | OCI tenancy/compartment OCID |
| `oci_namespace` | Object Storage namespace (for state backend) |
| `region` | OCI region (default: us-sanjose-1) |
| `ssh_public_key` | SSH public key for instance access |

## Modules

### Security

Cloud Guard, OCI Vault/KMS, vulnerability scanning, and IAM policies.

```hcl
module "security" {
  source         = "./modules/security"
  compartment_id = var.compartment_id
  tenancy_id     = var.tenancy_id
  region         = var.region
}
```

Provides:
- **Cloud Guard** - Threat detection and compliance monitoring
- **OCI Vault + KMS** - Encryption key management (20 keys free)
- **Vulnerability Scanning** - Weekly CVE scans
- **IAM Policies** - Service permissions for KMS and Cloud Guard

### Networking

VCN, subnet, gateways, and security lists.

```hcl
module "networking" {
  source             = "./modules/networking"
  compartment_id     = var.compartment_id
  vcn_name           = "My VCN"
  vcn_cidr_blocks    = ["10.0.0.0/16"]
  public_subnet_cidr = "10.0.0.0/24"
}
```

## State Backend

Uses OCI Object Storage:

```hcl
backend "oci" {
  bucket = "terraform-state"
  key    = "infra/terraform.tfstate"
  region = "us-sanjose-1"
}
```

Create the bucket manually before first init.

## Security

All features stay within OCI Always Free tier:

| Feature | Status |
|---------|--------|
| Cloud Guard | Enabled (threat detection) |
| OCI Vault + KMS | Enabled (encryption keys) |
| Vulnerability Scanning | Weekly scans |
| Boot Volume Encryption | Available |
| No Public IPs | Instances accessed via Bastion/Tailscale |
| SSH Restricted | VCN CIDR only |
