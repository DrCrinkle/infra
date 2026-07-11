#!/bin/bash
# Pre-Ansible Health Check Script
# Run this before ansible-playbook to verify instance health
#
# Usage: ./scripts/pre-ansible-healthcheck.sh <SSH_TARGET>
# Example: ./scripts/pre-ansible-healthcheck.sh opc@10.0.1.100
#          ./scripts/pre-ansible-healthcheck.sh -J opc@NAT_IP opc@PRIVATE_IP

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "Usage: $0 <SSH_TARGET> [SSH_OPTIONS]"
    echo "Example: $0 opc@10.0.1.100"
    echo "         $0 -J opc@NAT_IP opc@PRIVATE_IP"
    exit 1
fi

SSH_ARGS="$@"
FAILED=0

check() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    
    printf "%-40s" "Checking $name..."
    
    result=$(ssh $SSH_ARGS "$cmd" 2>/dev/null) || result="ERROR"
    
    if echo "$result" | grep -qE "$expected"; then
        echo -e "${GREEN}PASS${NC}"
        return 0
    else
        echo -e "${RED}FAIL${NC} (got: $result)"
        return 1
    fi
}

check_warn() {
    local name="$1"
    local cmd="$2"
    local threshold="$3"
    
    printf "%-40s" "Checking $name..."
    
    result=$(ssh $SSH_ARGS "$cmd" 2>/dev/null) || result="ERROR"
    
    if [ "$result" = "ERROR" ]; then
        echo -e "${YELLOW}WARN${NC} (could not check)"
        return 0
    fi
    
    if [ "$result" -lt "$threshold" ]; then
        echo -e "${GREEN}PASS${NC} ($result)"
        return 0
    else
        echo -e "${YELLOW}WARN${NC} ($result exceeds $threshold)"
        return 0
    fi
}

check_min() {
    local name="$1"
    local cmd="$2"
    local threshold="$3"

    printf "%-40s" "Checking $name..."

    result=$(ssh $SSH_ARGS "$cmd" 2>/dev/null) || result="ERROR"

    if [ "$result" = "ERROR" ]; then
        echo -e "${YELLOW}WARN${NC} (could not check)"
        return 0
    fi

    if [ "$result" -ge "$threshold" ]; then
        echo -e "${GREEN}PASS${NC} ($result)"
        return 0
    else
        echo -e "${YELLOW}WARN${NC} ($result below $threshold)"
        return 0
    fi
}

echo "=== Pre-Ansible Instance Health Check ==="
echo "Target: $SSH_ARGS"
echo ""

echo "--- Connectivity ---"
check "SSH access" "echo ok" "ok" || FAILED=1

echo ""
echo "--- System Resources ---"
check_warn "Disk usage (%)" "df / | tail -1 | awk '{print \$5}' | tr -d '%'" "80"
check_min "Memory free (MB)" "free -m | grep Mem | awk '{print \$7}'" "500"
check_warn "Load average (1min)" "cat /proc/loadavg | awk '{print int(\$1)}'" "4"

echo ""
echo "--- Cloud-init Status ---"
check "Cloud-init complete" "cloud-init status 2>/dev/null || echo done" "(done|status: done)" || FAILED=1

echo ""
echo "--- Outbound Connectivity ---"
check "Internet access" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://google.com" "200|301|302" || FAILED=1
check "Tailscale control plane" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://controlplane.tailscale.com" "200|301|302" || FAILED=1

echo ""
echo "--- System Errors ---"
kernel_errors=$(ssh $SSH_ARGS "dmesg 2>/dev/null | grep -ciE '(panic|error|fail)' || true" 2>/dev/null)
kernel_errors=${kernel_errors:-0}
if [ "$kernel_errors" -gt 10 ]; then
    echo -e "Kernel errors: ${YELLOW}$kernel_errors messages${NC} (review with: dmesg | grep -iE 'panic|error|fail')"
else
    echo -e "Kernel errors: ${GREEN}$kernel_errors messages${NC}"
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo -e "=== ${GREEN}Health check PASSED${NC} - safe to run Ansible ==="
    exit 0
else
    echo -e "=== ${RED}Health check FAILED${NC} - fix issues before running Ansible ==="
    exit 1
fi
