# Box configs (sentinel + edge-lab)

Version-controlled copies of the service configs deployed to the two free
E2.1.Micro boxes provisioned in `terraform/free-micros.tf`. These are deployed
manually over Tailscale (scp + `sudo install`), mirroring the repo's
"manual Terraform → config handoff" convention.

```
configs/
  sentinel/
    gatus/config.yaml        -> /etc/gatus/config.yaml
    systemd/gatus.service    -> /etc/systemd/system/gatus.service
  edge-lab/
    caddy/Caddyfile          -> /etc/caddy/Caddyfile
    systemd/caddy.service    -> /etc/systemd/system/caddy.service
    systemd/bun-hello.service -> /etc/systemd/system/bun-hello.service
    apps/hello-static/public/index.html -> /opt/edge-lab/apps/hello-static/public/
    apps/hello-bun/server.ts -> /opt/edge-lab/apps/hello-bun/
    README.md                -> /opt/edge-lab/README.md (on-box deploy guide)
```

## sentinel — Gatus watchdog
Static binary built from source (`github.com/TwiN/gatus`, no prebuilt releases) →
`/usr/local/bin/gatus`. Web UI on `:8080`, tailnet-only (firewalld drop + OCI SL/NSG).
Checks OpenClaw over the tailnet; the `openclaw-gateway` check uses the Tailscale
Serve endpoint (`https://openclaw.tail7c48ec.ts.net/healthz`) because the gateway
is loopback-bound on OpenClaw and exposed to the tailnet only via Serve.
Alerting is a TODO (no ntfy/Telegram creds yet).

## edge-lab — Caddy + Bun sandbox
Caddy (official static binary) serves the static site and reverse-proxies `/api/*`
to a Bun service on `127.0.0.1:3000`. Public 80/443 is deferred — tailnet-only for
now. See `edge-lab/README.md` for deploying new apps and going public.

## Deploy
```bash
# example: push the gatus config + restart
scp configs/sentinel/gatus/config.yaml opc@sentinel:/tmp/
ssh opc@sentinel 'sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl restart gatus'
```

## Observability on taylor-pc (two options) and Alloy
Pick one. `lgtm/`: Grafana, Loki, Tempo and Prometheus as one compose project.
`openobserve/`: a single OpenObserve container. Either is backed up nightly to rsync.net with
restic, and Grafana Alloy reports from every node (`alloy/`, with the OpenObserve variants in
`alloy/openobserve/`). Nothing here is applied by tooling: the runbook lists each Taylor-run
step with its rollback, and `scripts/validate-lgtm.sh` runs every static check.
Start at `docs/lgtm-taylor-pc.md` (the OpenObserve option is `docs/openobserve-taylor-pc.md`); the
tailnet ACL template is `docs/lgtm-tailnet-acl.md`.
