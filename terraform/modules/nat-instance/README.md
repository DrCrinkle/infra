# NAT Instance Module (OCI Free Tier)

fck-nat style NAT instance for Oracle Cloud Infrastructure, optimized for the Always Free tier.

## Features

- Uses `VM.Standard.E2.1.Micro` (1 OCPU, 1GB RAM) - Always Free eligible
- IP forwarding and iptables masquerade via cloud-init
- Source/destination check disabled automatically
- **Optional HA mode**: Active/passive failover using both free tier x86 instances

## Usage

### Single Instance (Default)

```hcl
module "nat_instance" {
  source = "./modules/nat-instance"

  compartment_id      = var.compartment_id
  availability_domain = "mBSv:US-SANJOSE-1-AD-1"
  subnet_id           = module.networking.public_subnet_id
  vcn_id              = module.networking.vcn_id
  ssh_public_key      = var.ssh_public_key
  private_subnet_cidr = "10.0.1.0/24"
  image_id            = "ocid1.image.oc1..."  # Oracle Linux x86
}
```

### HA Mode (Two Instances with Failover)

```hcl
module "nat_instance" {
  source = "./modules/nat-instance"

  compartment_id      = var.compartment_id
  availability_domain = "mBSv:US-SANJOSE-1-AD-1"
  subnet_id           = module.networking.public_subnet_id
  vcn_id              = module.networking.vcn_id
  ssh_public_key      = var.ssh_public_key
  private_subnet_cidr = "10.0.1.0/24"
  image_id            = "ocid1.image.oc1..."

  # HA configuration
  enable_ha      = true
  route_table_id = module.networking.private_route_table_id
}
```

## HA Mode Details

When `enable_ha = true`:

1. **Primary instance** handles all NAT traffic initially
2. **Standby instance** monitors primary via ICMP ping every 10 seconds
3. After 3 consecutive failures (~30 seconds), standby:
   - Updates the route table to point to itself
   - Logs the failover to syslog
   - Continues operating as the new primary

### Requirements for HA

- Both free tier x86 instances will be used
- `route_table_id` must be provided (the private subnet's route table)
- IAM dynamic group and policy are created automatically for route table updates

### Monitoring Failover

On the standby instance:
```bash
journalctl -u nat-failover -f
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| compartment_id | OCI Compartment OCID | string | - | yes |
| availability_domain | Availability domain for instances | string | - | yes |
| subnet_id | Public subnet OCID | string | - | yes |
| vcn_id | VCN OCID | string | - | yes |
| ssh_public_key | SSH public key | string | - | yes |
| private_subnet_cidr | CIDR of private subnet using NAT | string | `10.0.1.0/24` | no |
| image_id | Oracle Linux x86 image OCID | string | - | yes |
| display_name | Instance display name | string | `fck-nat` | no |
| enable_ha | Enable HA with standby instance | bool | `false` | no |
| route_table_id | Route table OCID (required if enable_ha) | string | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| instance_id | Primary NAT instance OCID |
| private_ip | Primary instance private IP |
| private_ip_id | Primary instance private IP OCID (for route tables) |
| public_ip | Primary instance public IP |
| security_list_id | NAT security list OCID |
| standby_instance_id | Standby instance OCID (null if HA disabled) |
| standby_private_ip | Standby instance private IP |
| standby_private_ip_id | Standby instance private IP OCID |
