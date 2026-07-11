#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${INFRA_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

OPENCLAW_USER="${OPENCLAW_USER:-opc}"
OPENCLAW_IP="${OPENCLAW_IP:-}"

if [ -z "$OPENCLAW_IP" ]; then
    if [ -d "${INFRA_DIR}/terraform" ]; then
        OPENCLAW_IP=$(cd "${INFRA_DIR}/terraform" && terraform output -raw openclaw_private_ip 2>/dev/null || true)
    fi
fi

if [ -z "$OPENCLAW_IP" ]; then
    log_error "Could not resolve OpenClaw IP. Set OPENCLAW_IP or run after terraform outputs are available."
    exit 1
fi

mkdir -p "$BACKUP_DIR"

log_info "=== Pre-Migration Backup Script ==="
log_info "Timestamp: $TIMESTAMP"
log_info "Target: ${OPENCLAW_USER}@${OPENCLAW_IP}"
log_info "Backup directory: $BACKUP_DIR"
echo ""

log_info "Step 1: Backing up Terraform state..."
cd "${INFRA_DIR}/terraform"
if [ -f terraform.tfstate ]; then
    cp terraform.tfstate "${BACKUP_DIR}/terraform.tfstate.backup.${TIMESTAMP}"
    log_info "Local state backed up"
else
    log_warn "No local terraform.tfstate found (may be using remote backend)"
fi

terraform state list > "${BACKUP_DIR}/terraform-resources-${TIMESTAMP}.txt" 2>/dev/null || log_warn "Could not list terraform resources"
log_info "Resource list saved"

log_info "Step 2: Recording Tailscale device ID..."
TAILSCALE_DEVICE_ID=$(ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'tailscale status --json 2>/dev/null | jq -r .Self.ID' 2>/dev/null || echo "unknown")
echo "OLD_TAILSCALE_DEVICE_ID=${TAILSCALE_DEVICE_ID}" > "${BACKUP_DIR}/tailscale-device-${TIMESTAMP}.txt"
log_info "Tailscale device ID: ${TAILSCALE_DEVICE_ID}"

log_info "Step 3: Documenting current system state..."
ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'rpm -qa | sort' > "${BACKUP_DIR}/packages-${TIMESTAMP}.txt" 2>/dev/null || log_warn "Could not get package list"
ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'systemctl list-unit-files --state=enabled' > "${BACKUP_DIR}/services-${TIMESTAMP}.txt" 2>/dev/null || log_warn "Could not get service list"
ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'docker ps -a' > "${BACKUP_DIR}/docker-containers-${TIMESTAMP}.txt" 2>/dev/null || log_warn "Could not get docker containers"
ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'docker volume ls' > "${BACKUP_DIR}/docker-volumes-${TIMESTAMP}.txt" 2>/dev/null || log_warn "Could not get docker volumes"
log_info "System state documented"

log_info "Step 4: Creating data backup on remote host..."
ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'sudo tar -czvf /tmp/openclaw-backup.tar.gz \
    /home/opc/.openclaw \
    /home/opc/workspace \
    /home/opc/workspaces \
    /home/opc/openclaw \
    /home/opc/.config/systemd/user/openclaw* \
    /etc/systemd/system/openclaw* \
    2>/dev/null || true'

REMOTE_SIZE=$(ssh "${OPENCLAW_USER}@${OPENCLAW_IP}" 'ls -lh /tmp/openclaw-backup.tar.gz 2>/dev/null | awk "{print \$5}"' || echo "unknown")
log_info "Remote backup created: ${REMOTE_SIZE}"

log_info "Step 5: Transferring backup to local machine..."
rsync --progress --partial "${OPENCLAW_USER}@${OPENCLAW_IP}:/tmp/openclaw-backup.tar.gz" "${BACKUP_DIR}/openclaw-backup-${TIMESTAMP}.tar.gz"

LOCAL_SIZE=$(ls -lh "${BACKUP_DIR}/openclaw-backup-${TIMESTAMP}.tar.gz" | awk '{print $5}')
log_info "Local backup saved: ${LOCAL_SIZE}"

log_info "Step 6: Verifying backup integrity..."
FILE_COUNT=$(tar -tzf "${BACKUP_DIR}/openclaw-backup-${TIMESTAMP}.tar.gz" 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -lt 10 ]; then
    log_error "Backup may be incomplete - only ${FILE_COUNT} files found"
    exit 1
fi
log_info "Backup contains ${FILE_COUNT} files"

log_info "Step 7: Testing Ansible vault access..."
cd "${INFRA_DIR}/ansible"
if ansible-vault view group_vars/all/vault.yml --ask-vault-pass > /dev/null 2>&1; then
    log_info "Vault access verified"
else
    log_warn "Could not verify vault access - ensure you know the vault password"
fi

echo ""
log_info "=== Backup Summary ==="
echo "Terraform state: ${BACKUP_DIR}/terraform.tfstate.backup.${TIMESTAMP}"
echo "Resource list: ${BACKUP_DIR}/terraform-resources-${TIMESTAMP}.txt"
echo "Tailscale device: ${BACKUP_DIR}/tailscale-device-${TIMESTAMP}.txt"
echo "System packages: ${BACKUP_DIR}/packages-${TIMESTAMP}.txt"
echo "System services: ${BACKUP_DIR}/services-${TIMESTAMP}.txt"
echo "Data backup: ${BACKUP_DIR}/openclaw-backup-${TIMESTAMP}.tar.gz (${LOCAL_SIZE}, ${FILE_COUNT} files)"
echo ""
log_info "=== Pre-migration backup complete ==="

git tag -a "migration-start-${TIMESTAMP}" -m "Pre-migration backup point" 2>/dev/null || log_warn "Could not create git tag"
