#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
check_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
check_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN++)); }

echo "=== NAT Instance Verification Script ==="
echo ""

cd "${INFRA_DIR}/terraform"

echo "--- Gathering Terraform outputs ---"
NAT_IP=$(terraform output -raw nat_instance_public_ip 2>/dev/null || echo "")
NAT_OCID=$(terraform output -raw nat_instance_ocid 2>/dev/null || echo "")
OPENCLAW_IP=$(terraform output -raw openclaw_private_ip 2>/dev/null || echo "")

if [ -z "$NAT_IP" ]; then
    check_fail "Could not get NAT instance public IP from Terraform"
    echo "Run 'terraform apply' first"
    exit 1
fi

echo "NAT Public IP: $NAT_IP"
echo "NAT OCID: $NAT_OCID"
echo "OpenClaw Private IP: $OPENCLAW_IP"
echo ""

echo "--- Check 1: OCI VNIC skip_source_dest_check ---"
if [ -n "$NAT_OCID" ]; then
    NAT_VNIC_ID=$(oci compute instance list-vnics --instance-id "$NAT_OCID" 2>/dev/null | jq -r '.data[0].id' || echo "")
    if [ -n "$NAT_VNIC_ID" ]; then
        SKIP_CHECK=$(oci network vnic get --vnic-id "$NAT_VNIC_ID" 2>/dev/null | jq -r '.data."skip-source-dest-check"' || echo "unknown")
        if [ "$SKIP_CHECK" = "true" ]; then
            check_pass "skip_source_dest_check is enabled on NAT VNIC"
        else
            check_fail "skip_source_dest_check is ${SKIP_CHECK} - NAT will not forward traffic!"
        fi
    else
        check_warn "Could not get VNIC ID - verify manually in OCI console"
    fi
else
    check_warn "NAT OCID not available - cannot verify VNIC settings"
fi

echo ""
echo "--- Check 2: SSH connectivity to NAT instance ---"
if ssh -o ConnectTimeout=10 -o BatchMode=yes "opc@${NAT_IP}" 'echo "SSH OK"' 2>/dev/null; then
    check_pass "SSH to NAT instance works"
else
    check_fail "Cannot SSH to NAT instance at ${NAT_IP}"
    echo "  - Verify security list allows SSH from your IP"
    echo "  - Or use Bastion to reach NAT"
    exit 1
fi

echo ""
echo "--- Check 3: cloud-init status ---"
CLOUD_INIT_STATUS=$(ssh "opc@${NAT_IP}" 'cloud-init status 2>/dev/null | grep -oP "status: \K\w+"' || echo "unknown")
if [ "$CLOUD_INIT_STATUS" = "done" ]; then
    check_pass "cloud-init completed successfully"
else
    check_fail "cloud-init status: ${CLOUD_INIT_STATUS}"
    echo "  - Check: ssh opc@${NAT_IP} 'cat /var/log/cloud-init-output.log'"
fi

echo ""
echo "--- Check 4: NAT setup log ---"
if ssh "opc@${NAT_IP}" 'grep -q "NAT masquerade configured" /var/log/nat-setup.log 2>/dev/null'; then
    check_pass "NAT setup script completed"
else
    check_warn "NAT setup log may indicate issues"
    echo "  - Check: ssh opc@${NAT_IP} 'cat /var/log/nat-setup.log'"
fi

echo ""
echo "--- Check 5: IP forwarding ---"
IP_FORWARD=$(ssh "opc@${NAT_IP}" 'sysctl -n net.ipv4.ip_forward' 2>/dev/null || echo "0")
if [ "$IP_FORWARD" = "1" ]; then
    check_pass "IP forwarding is enabled"
else
    check_fail "IP forwarding is disabled (value: ${IP_FORWARD})"
fi

FORWARD_PERSISTENT=$(ssh "opc@${NAT_IP}" 'grep -r "ip_forward.*=.*1" /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null | head -1' || echo "")
if [ -n "$FORWARD_PERSISTENT" ]; then
    check_pass "IP forwarding is persistent"
else
    check_warn "IP forwarding may not persist after reboot"
fi

echo ""
echo "--- Check 6: iptables MASQUERADE rule ---"
MASQ_RULE=$(ssh "opc@${NAT_IP}" 'sudo iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -i masquerade' || echo "")
if [ -n "$MASQ_RULE" ]; then
    check_pass "iptables MASQUERADE rule present"
    echo "  $MASQ_RULE"
else
    NFT_MASQ=$(ssh "opc@${NAT_IP}" 'sudo nft list ruleset 2>/dev/null | grep -i masquerade' || echo "")
    if [ -n "$NFT_MASQ" ]; then
        check_pass "nftables masquerade rule present"
    else
        check_fail "No MASQUERADE rule found"
    fi
fi

IPTABLES_SAVED=$(ssh "opc@${NAT_IP}" 'cat /etc/sysconfig/iptables 2>/dev/null | grep -i masquerade' || echo "")
if [ -n "$IPTABLES_SAVED" ]; then
    check_pass "iptables rules saved for persistence"
else
    FW_MASQ=$(ssh "opc@${NAT_IP}" 'sudo firewall-cmd --query-masquerade 2>/dev/null' || echo "no")
    if [ "$FW_MASQ" = "yes" ]; then
        check_pass "firewalld masquerade enabled for persistence"
    else
        check_warn "NAT rules may not persist after reboot"
    fi
fi

echo ""
echo "--- Check 7: Conntrack settings ---"
CONNTRACK_MAX=$(ssh "opc@${NAT_IP}" 'sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null' || echo "0")
if [ "$CONNTRACK_MAX" -ge 65536 ]; then
    check_pass "conntrack_max is ${CONNTRACK_MAX}"
else
    check_warn "conntrack_max is ${CONNTRACK_MAX} (recommend 131072+)"
fi

echo ""
echo "--- Check 8: NAT instance outbound connectivity ---"
NAT_OUTBOUND=$(ssh "opc@${NAT_IP}" 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://google.com' 2>/dev/null || echo "000")
if [ "$NAT_OUTBOUND" = "200" ] || [ "$NAT_OUTBOUND" = "301" ] || [ "$NAT_OUTBOUND" = "302" ]; then
    check_pass "NAT instance has outbound HTTPS connectivity"
else
    check_fail "NAT instance cannot reach internet (HTTP status: ${NAT_OUTBOUND})"
fi

echo ""
echo "--- Check 9: UDP egress (for Tailscale) ---"
UDP_TEST=$(ssh "opc@${NAT_IP}" 'timeout 3 nc -u -z 8.8.8.8 53 2>&1 && echo "OK"' || echo "FAIL")
if [[ "$UDP_TEST" == *"OK"* ]] || [[ "$UDP_TEST" == *"succeeded"* ]]; then
    check_pass "UDP egress works"
else
    check_warn "UDP egress test inconclusive - Tailscale may use DERP relay"
fi

echo ""
echo "--- Check 10: OpenClaw connectivity through NAT ---"
if [ -n "$OPENCLAW_IP" ]; then
    OPENCLAW_OUTBOUND=$(ssh "opc@${NAT_IP}" "ssh -o ConnectTimeout=5 -o BatchMode=yes opc@${OPENCLAW_IP} 'curl -s -o /dev/null -w \"%{http_code}\" --max-time 10 https://google.com' 2>/dev/null" || echo "000")
    if [ "$OPENCLAW_OUTBOUND" = "200" ] || [ "$OPENCLAW_OUTBOUND" = "301" ] || [ "$OPENCLAW_OUTBOUND" = "302" ]; then
        check_pass "OpenClaw has outbound connectivity through NAT"
    else
        check_fail "OpenClaw cannot reach internet through NAT (HTTP status: ${OPENCLAW_OUTBOUND})"
    fi
    
    TAILSCALE_CONTROL=$(ssh "opc@${NAT_IP}" "ssh -o ConnectTimeout=5 -o BatchMode=yes opc@${OPENCLAW_IP} 'curl -s -o /dev/null -w \"%{http_code}\" --max-time 10 https://controlplane.tailscale.com' 2>/dev/null" || echo "000")
    if [ "$TAILSCALE_CONTROL" = "200" ] || [ "$TAILSCALE_CONTROL" = "301" ] || [ "$TAILSCALE_CONTROL" = "302" ] || [ "$TAILSCALE_CONTROL" = "404" ]; then
        check_pass "OpenClaw can reach Tailscale control plane"
    else
        check_fail "OpenClaw cannot reach Tailscale control plane (HTTP status: ${TAILSCALE_CONTROL})"
    fi
else
    check_warn "OpenClaw IP not available - skipping transit verification"
    echo "  This is expected if openclaw hasn't been created yet"
fi

echo ""
echo "=========================================="
echo "         VERIFICATION SUMMARY"
echo "=========================================="
echo -e "${GREEN}PASSED: ${PASS}${NC}"
echo -e "${YELLOW}WARNINGS: ${WARN}${NC}"
echo -e "${RED}FAILED: ${FAIL}${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}=== STOP GATE: Fix failures before proceeding ===${NC}"
    exit 1
elif [ "$WARN" -gt 3 ]; then
    echo -e "${YELLOW}=== Multiple warnings - review before proceeding ===${NC}"
    exit 0
else
    echo -e "${GREEN}=== All critical checks passed ===${NC}"
    exit 0
fi
