#!/usr/bin/env bash
# configs/lgtm/serve.sh: put the LGTM stack on the tailnet through Tailscale Serve.
#
# Run in YOUR OWN terminal on taylor-pc: it calls sudo, and a `!` line cannot
# take sudo's password. No Serve operator is set on taylor-pc, so changing Serve
# needs root.
#
#   serve.sh on       add the five Serve doors (idempotent)
#   serve.sh off      remove exactly those five doors
#   serve.sh status   print the current Serve config
#
# Doors (loopback target -> Serve):
#   https :8443 -> 127.0.0.1:3300   Grafana UI
#   tcp   :3100 -> 127.0.0.1:3100   Loki push + /ready
#   tcp   :9090 -> 127.0.0.1:9090   Prometheus remote-write, OTLP, /-/ready
#   tcp   :4317 -> 127.0.0.1:4317   Tempo OTLP gRPC
#   tcp   :4318 -> 127.0.0.1:4318   Tempo OTLP HTTP
#
# HTTPS :443 already serves another app on this host. This script never touches
# it, and it never runs `tailscale serve reset`, which would drop every route.
set -euo pipefail

action="${1:-}"
tcp_ports=(3100 9090 4317 4318)

ts() { sudo tailscale "$@"; }

on() {
  ts serve --bg --https=8443 http://127.0.0.1:3300
  local p
  for p in "${tcp_ports[@]}"; do
    ts serve --bg --tcp="$p" "tcp://127.0.0.1:$p"
  done
}

off() {
  ts serve --https=8443 off
  local p
  for p in "${tcp_ports[@]}"; do
    ts serve --tcp="$p" off
  done
}

case "$action" in
  on) on ;;
  off) off ;;
  status) ;;
  *)
    echo "usage: $0 on|off|status" >&2
    exit 2
    ;;
esac

tailscale serve status
echo "check: the existing :443 route must still be listed above, untouched."
