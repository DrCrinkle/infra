#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="${INFRA_DIR}/terraform"
OUT_FILE="${1:-${INFRA_DIR}/ansible/inventory/hosts.yml}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "ERROR: terraform is required but not found in PATH" >&2
  exit 1
fi

if [ ! -d "$TF_DIR" ]; then
  echo "ERROR: terraform directory not found at ${TF_DIR}" >&2
  exit 1
fi

OPENCLAW_IP=$(cd "$TF_DIR" && terraform output -raw openclaw_private_ip)
NAT_PRIVATE_IP=$(cd "$TF_DIR" && terraform output -raw nat_instance_private_ip)
NAT_PUBLIC_IP=$(cd "$TF_DIR" && terraform output -raw nat_instance_public_ip)

mkdir -p "$(dirname "$OUT_FILE")"

cat > "$OUT_FILE" <<EOF
all:
  children:
    oci:
      hosts:
        openclaw:
          ansible_host: ${OPENCLAW_IP}
          ansible_user: opc
          ansible_python_interpreter: /usr/bin/python3
          ansible_ssh_common_args: '-o ProxyJump=opc@${NAT_PUBLIC_IP}'
        nat:
          ansible_host: ${NAT_PUBLIC_IP}
          ansible_user: opc
          ansible_python_interpreter: /usr/bin/python3
          nat_private_ip: ${NAT_PRIVATE_IP}
EOF

echo "Wrote inventory to ${OUT_FILE}"
echo "Note: ansible/ansible.cfg currently defaults to inventory/hosts.local.yml."
