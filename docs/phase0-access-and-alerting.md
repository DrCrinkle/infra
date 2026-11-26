# Phase 0: SSH resilience, gateway check, ntfy alerting

Nothing here has been applied to any host. Every command below is for a human to
approve and run from taylor-pc (the only machine that reaches `opc@` today).

## 1. Second SSH key (`ansible/access.yml`)

Today one key (taylor-pc `~/.ssh/id_ed25519`) is the only way into openclaw,
sentinel and edge-lab. `access.yml` adds the Mac's ED25519 public key, additively
(`exclusive: false`), via `ansible.posix.authorized_key` only.

The local inventory (`ansible/inventory/hosts.local.yml`, gitignored) must list
openclaw, sentinel and edge-lab under group `oci`.

```bash
# on taylor-pc, in ~/projects/infra/ansible; dry run first, one host at a time
ansible-playbook access.yml --limit sentinel --check --diff
ansible-playbook access.yml --limit sentinel
# repeat for edge_lab and openclaw (use the inventory host names)
```

Then on the Mac: `ssh-keygen -R edge-lab` (stale host key), and verify
`ssh opc@sentinel true`, `ssh opc@edge-lab true`, `ssh opc@openclaw true`.

Rollback (the existing key is never touched):
`ansible-playbook access.yml --limit <host> -e ssh_authorized_keys_state=absent`

## 2. The `openclaw-gateway` check (down since 2026-11-13T06:27Z)

Decision: **restore the Serve route; do not retarget the check.**

Read-only evidence from openclaw, 2026-11-14:

- `openclaw.json` still sets `gateway.tailscale.mode: "serve"`, so the gateway is
  configured to be exposed through Serve on :443. Nothing in the repo or notes
  records a decision to drop that.
- The gateway runs (`openclaw-gateway.service` active since 2026-11-11 06:38 UTC)
  and `curl http://127.0.0.1:18789/healthz` returns 200.
- `tailscaled` restarted at 2026-11-13 06:27:02 UTC. Its log then re-creates Serve
  handlers only for 127.0.0.1:18318, :3131 and :9121. The failure begins at
  06:27:55Z, 53 s later. No :443 gateway route exists in
  `tailscale serve status --json` (routes: :10000, :8443, `svc:hermes`).
- Shell history shows `tailscale serve --https=443 off` run twice next to
  `serve --bg 9119` (a Hermes dashboard experiment, since replaced by `svc:hermes`).
  That was about Hermes. No history line deliberately removes the gateway route.
- The other three tailnet doors are other apps (:8443, :10000, svc:hermes), so none
  is a replacement for the gateway.

Not determined: whether the nightly ~06:xx UTC flaps since September come from the
same tailscaled restart (likely, since the failure starts right after one) and why
the route is not persisted. Treat a route that vanishes on restart as the next thing
to fix after restoring it.

Restore (Taylor-run on openclaw; changes Serve config, so approve first):

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
sudo tailscale serve status         # :443 -> 127.0.0.1:18789 present
curl -s -o /dev/null -w '%{http_code}\n' https://openclaw.tail7c48ec.ts.net/healthz   # 200, from a tailnet node
```

Rollback: `sudo tailscale serve --https=443 off`.

## 3. ntfy alerting on sentinel

Committed config uses `topic: "${NTFY_TOPIC}"`; the topic never enters Git.
`gatus.service` loads `/etc/gatus/gatus.env` (no `-` prefix, so a missing file
stops the unit rather than alerting a public topic literally named `${NTFY_TOPIC}`).

Order matters: **gateway route restored (section 2) first, env file next, config
last**, otherwise the gateway check pages on the first three failures.

Taylor-run steps:

1. Create a random topic and subscribe in the ntfy iPhone app, e.g.
   `openssl rand -hex 16`, topic `infra-<that value>`. Do not paste it in chat or Git.
2. On sentinel, write the env file without echoing the value to a transcript:
   ```bash
   read -rs T && printf 'NTFY_TOPIC=%s\n' "$T" | ssh opc@sentinel 'sudo install -m0600 -o root -g root /dev/stdin /etc/gatus/gatus.env'; unset T
   ```
3. From the repo (taylor-pc), deploy unit then config:
   ```bash
   scp configs/sentinel/systemd/gatus.service configs/sentinel/gatus/config.yaml opc@sentinel:/tmp/
   ssh opc@sentinel 'sudo install -m0644 /tmp/gatus.service /etc/systemd/system/gatus.service && sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl daemon-reload && sudo systemctl restart gatus && systemctl is-active gatus'
   ```
4. Fire one test alert: on openclaw `sudo tailscale serve --https=443 off` for
   ~4 minutes (3 failures at 60 s), confirm the phone buzzes, then restore the route
   and confirm the resolved notice. Record the time in the ISA.

Rollback: reinstall the previous `config.yaml` and `gatus.service` from Git history,
`daemon-reload`, restart. `gatus.env` can stay or be removed.

When the taylor-pc `sentinel` role lands in Git, it must write `gatus.env` from the
vault (`vault_ntfy_topic`) and copy the new unit; it copies `config.yaml` verbatim,
which is correct.

## 4. ISA criteria for Phase 0

`ISA.md` is not in `origin/main` (untracked on taylor-pc), so these rows are
shipped here to paste into its Test Strategy and Features. Numbering continues from
ISC-12 there.

| isc | type | check | threshold | tool | anchors_to |
|---|---|---|---|---|---|
| ISC-13 | live | At least 2 independent keys reach every OCI host as `opc` | 2 distinct fingerprints succeed per host | `ssh -o IdentitiesOnly=yes -i <key> opc@<host> true` from taylor-pc and the Mac | Vision |
| ISC-13.1 | static | `access.yml` applies `authorized_key` additively | contract test passes | `bun scripts/test-phase0-contract.ts` | Constraints |
| ISC-14 | static | Gatus alerts to ntfy with the topic supplied by environment only | no topic literal in tracked files; `${NTFY_TOPIC}` and `EnvironmentFile=` present | contract test | Constraints |
| ISC-14.1 | live | A synthetic failure reaches the phone and resolves | notification and resolved notice, timestamps recorded | stop the gateway route 4 min | Vision |
| ISC-15 | live | The `openclaw-gateway` check is green and stays green across a tailscaled restart | healthy after restart | Gatus API `/api/v1/endpoints/statuses` | Vision |

Features: F3 (independent micro hosts) gains ISC-13 to ISC-15, each `[ ]` until its
live check is recorded. Decision entry: 2026-11-14, gateway route restored rather
than check retargeted (section 2).
