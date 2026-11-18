#!/usr/bin/env bash
# configs/openobserve/serve.sh: put OpenObserve on the tailnet through Tailscale Serve.
#
# Run in YOUR OWN terminal on taylor-pc: it calls sudo, and a `!` line cannot
# take sudo's password. No Serve operator is set on taylor-pc, so changing Serve
# needs root.
#
#   serve.sh on       add the two Serve doors (idempotent)
#   serve.sh off      remove exactly those two doors
#   serve.sh status   print the current Serve config
#
# Doors (loopback target -> Serve):
#   https :8443 -> 127.0.0.1:5080   UI and every HTTP API (login, Prometheus
#                                   remote-write, Loki push, OTLP over HTTP)
#   tcp   :5081 -> 127.0.0.1:5081   OTLP over gRPC
#
# :8443 is the same door configs/lgtm/serve.sh uses for Grafana: run one option or
# the other. HTTPS :443 already serves another app on this host. This script never
# touches it, and it never runs `tailscale serve reset`, which would drop every route.
set -euo pipefail

action="${1:-}"

ts() { sudo tailscale "$@"; }

on() {
  ts serve --bg --https=8443 http://127.0.0.1:5080
  ts serve --bg --tcp=5081 tcp://127.0.0.1:5081
}

off() {
  ts serve --https=8443 off
  ts serve --tcp=5081 off
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
