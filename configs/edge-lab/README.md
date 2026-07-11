# edge-lab — tiny public sandbox

AlmaLinux 10 · x86_64 · OCI Always-Free E2.1.Micro (1 OCPU / 1 GB).
Stack: **Caddy** (reverse proxy / static server) + **Bun** (JS/TS runtime) + git.
Reachable over **Tailscale** (`http://edge-lab/`). Not publicly exposed yet.

## Layout

```
/opt/edge-lab/apps/
  hello-static/public/index.html   # static landing page (served at /)
  hello-bun/server.ts              # tiny Bun API (proxied at /api/*)
/etc/caddy/Caddyfile               # Caddy config
/etc/systemd/system/bun-hello.service
```

## Deploy a NEW tiny app

### A. Static site
```bash
sudo mkdir -p /opt/edge-lab/apps/<name>/public
# put files in that public/ dir, then add a route in the Caddyfile:
#   handle_path /<name>/* { root * /opt/edge-lab/apps/<name>/public; file_server }
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

### B. Bun service
```bash
sudo mkdir -p /opt/edge-lab/apps/<name> && cd /opt/edge-lab/apps/<name>
# add server.ts listening on 127.0.0.1:<port> (see hello-bun/server.ts)
# copy the unit, change Description/WorkingDirectory/PORT:
sudo cp /etc/systemd/system/bun-hello.service /etc/systemd/system/<name>.service
sudo systemctl daemon-reload && sudo systemctl enable --now <name>.service
# route it in the Caddyfile:
#   handle /<name>/* { reverse_proxy 127.0.0.1:<port> }
sudo systemctl reload caddy
```

## Go public (when a demo is ready)
1. `terraform/free-micros.tf` → add INGRESS TCP 80 & 443 to the `edge_lab` NSG; `terraform apply`.
2. Point a domain's DNS A record at edge-lab's **public IP** (`terraform output edge_lab_public_ip`).
3. In the Caddyfile replace `:80` with `your-domain.com` — Caddy auto-issues a Let's Encrypt cert and serves HTTPS.

## Handy
```bash
systemctl status caddy bun-hello
sudo caddy validate --config /etc/caddy/Caddyfile
journalctl -u bun-hello -f
curl http://localhost/api/hello
```
