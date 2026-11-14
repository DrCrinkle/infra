#!/usr/bin/env bash
# scripts/validate-lgtm.sh: every static check for the LGTM stack in one run.
#
# Static means: the configs parse under the pinned component binaries, the scripts
# lint, and the contract and behavior tests pass. Nothing here starts a container,
# touches a host or proves the stack runs.
#
# Tools are taken from the environment or PATH, so a pinned release binary works
# without installing anything:
#   PROMTOOL (Prometheus 3.16.0)  LOKI (3.7.10)  TEMPO (3.1.1)  ALLOY (1.21.3 or 1.22.0)
#   DOCKER_COMPOSE (default: `docker compose`; `config` needs no daemon)
# A check whose tool is missing is reported SKIP and the run exits non-zero, because
# an unavailable check is not a pass. Set LGTM_ALLOW_SKIP=1 to accept skips.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo" || exit 1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 failn=0 skip=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; failn=$((failn + 1)); }
skipped() { printf 'SKIP  %s (%s not found)\n' "$1" "$2"; skip=$((skip + 1)); }

# check NAME CMD...: run CMD, show its output only on failure.
check() {
  local name=$1
  shift
  if out="$("$@" 2>&1)"; then ok "$name"; else
    bad "$name"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}
have() { command -v "$1" >/dev/null 2>&1; }

check "contract test" bun scripts/test-lgtm-contract.ts
check "backup behavior test (stubbed tools)" bun scripts/test-lgtm-backup.ts

if have shellcheck; then
  check "shellcheck (style)" shellcheck -x -P SCRIPTDIR -S style \
    configs/lgtm/serve.sh configs/lgtm/backup/*.sh scripts/validate-lgtm.sh
else skipped "shellcheck" shellcheck; fi

# docker compose config resolves interpolation and env_file; give it a throwaway HOME.
mkdir -p "$tmp/home/.config/lgtm"
printf 'GF_SECURITY_ADMIN_PASSWORD=%s\nGF_SERVER_ROOT_URL=%s\n' placeholder https://example.invalid:8443/ >"$tmp/home/.config/lgtm/lgtm.env"
read -r -a compose <<<"${DOCKER_COMPOSE:-docker compose}"
if "${compose[@]}" version >/dev/null 2>&1; then
  check "docker compose config" env HOME="$tmp/home" "${compose[@]}" -f configs/lgtm/compose.yaml config --quiet
else skipped "docker compose config" "docker compose"; fi

# The drill override is merged with the live file: after the merge it must not mount
# live data, publish a live port, or leave loopback.
drill_config() {
  local out
  out="$(env HOME="$tmp/home" "${compose[@]}" -p lgtm-drill -f configs/lgtm/compose.yaml -f configs/lgtm/drill/compose.drill.yaml config)" || return 1
  if grep -q '/srv/lgtm/data' <<<"$out"; then echo "merged drill config still mounts live data"; return 1; fi
  if grep -E 'published: "?(3100|3200|3300|4317|4318|9090)"?$' <<<"$out"; then echo "merged drill config collides with a live port"; return 1; fi
  if grep -E 'host_ip:' <<<"$out" | grep -v -q '127.0.0.1'; then echo "merged drill config leaves loopback"; return 1; fi
}
if "${compose[@]}" version >/dev/null 2>&1; then
  check "docker compose config (drill override merged)" drill_config
else skipped "docker compose config (drill override merged)" "docker compose"; fi

promtool="${PROMTOOL:-promtool}"
if have "$promtool"; then check "promtool check config" "$promtool" check config configs/lgtm/prometheus.yml
else skipped "promtool check config" promtool; fi

loki="${LOKI:-loki}"
if have "$loki"; then check "loki -verify-config" "$loki" -config.file=configs/lgtm/loki.yaml -verify-config
else skipped "loki -verify-config" loki; fi

tempo="${TEMPO:-tempo}"
if have "$tempo"; then check "tempo -config.verify" "$tempo" -config.file=configs/lgtm/tempo.yaml -config.verify=true
else skipped "tempo -config.verify" tempo; fi

alloy="${ALLOY:-alloy}"
if have "$alloy"; then
  printf 'host.invalid\n' >"$tmp/lgtm-host"
  for f in configs/alloy/*.alloy; do
    check "alloy fmt --test $(basename "$f")" "$alloy" fmt --test "$f"
    check "alloy validate $(basename "$f")" env LGTM_HOST_FILE="$tmp/lgtm-host" "$alloy" validate "$f"
  done
else skipped "alloy fmt/validate" alloy; fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$failn" "$skip"
((failn == 0)) || exit 1
if ((skip > 0)) && [[ "${LGTM_ALLOW_SKIP:-0}" != 1 ]]; then
  echo "skipped checks are not passes; install or point at the tools, or set LGTM_ALLOW_SKIP=1" >&2
  exit 2
fi
