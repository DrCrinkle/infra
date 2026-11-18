# OpenObserve on taylor-pc: deploy runbook (the alternative to LGTM)

One OpenObserve container (logs, metrics and traces, data on local disk) instead of
Grafana + Loki + Tempo + Prometheus. It is the **second option** in
`docs/lgtm-taylor-pc.md` ("Two options"): you pick **one** at rollout, and the LGTM option
stays in the repo untouched. Everything shared (the deploy checkout, the `[!]`/`[pc]`/`[mac]`
legend, the backup scripts, the restic and Gatus secrets, the tailnet ACL) is described once
in that runbook; this file covers only what differs.

**Nothing here has been applied to any host.** Every command is for Taylor to run, phase by
phase, and each phase ends with a rollback.

## License, and what needs the Enterprise edition

Checked against the `v1.1.2` tag of github.com/openobserve/openobserve.

- **The open-source edition is AGPL-3.0.** The repository's `LICENSE` is the GNU Affero
  General Public License v3, and the README says it allows free commercial use. Running it
  unmodified for your own telemetry carries no source-offer duty; AGPL's network clause
  applies if you modify it and let others use it over a network.
- **Enterprise is a separate commercial license**, not AGPL. The README lists what it adds:
  single sign-on (OIDC, OAuth, SAML, LDAP), advanced RBAC with custom roles, audit trails,
  federated search across clusters (Super Cluster), sensitive-data redaction, advanced
  encryption keys, and query/workload management. It also lists a free enterprise tier of up
  to 50 GB/day of ingestion, with registration.
- **This setup needs none of those.** It uses the one root login, local-disk storage and no
  clustering. The practical consequence is **no sign-in from your Tailscale identity**: that
  needs SSO, so you log in to the UI with a password (see "Auth" below).
- **Not verified:** that the `openobserve/openobserve` image is the open-source build. Confirm
  after the first start: the UI's About page shows the edition. If it says Enterprise, stop and
  decide before ingesting anything.

## Choosing between the two

| | **LGTM** (`configs/lgtm`) | **OpenObserve** (`configs/openobserve`) |
|---|---|---|
| Containers | 4 (Grafana, Loki, Tempo, Prometheus) | 1 |
| Memory caps | 4.5 GB total | 2 GB |
| Sign-in | Your Tailscale identity, as Org Admin (`auth.proxy`) | A password you set; no identity sign-in without Enterprise |
| Ingest auth | None (tailnet reachability only) | HTTP basic auth: a login and an ingestion passcode on every node |
| Doors | `:8443` Grafana, `:3100`, `:9090`, `:4317`, `:4318` | `:8443` (UI **and** all HTTP ingest), `:5081` OTLP gRPC |
| Query | LogQL, PromQL, TraceQL, Grafana dashboards | SQL for logs and traces, PromQL for metrics, built-in dashboards |
| Backup pause | 4 containers stopped | 1 container stopped |
| Pinned version | Grafana 13.3.1, Loki 3.7.10, Tempo 3.1.1, Prometheus 3.16.0 | v1.1.2 (v1.2.0 is still a release candidate) |
| Retention | 30 days, three config keys | 30 days, one setting |

Two trade-offs to decide on, not hide:

1. **The ACL cannot separate admins from reporters.** In LGTM the UI is `:8443` and ingest is
   other ports, so the ACL can let a node push without letting it open Grafana. Here one door
   carries both, so any device allowed to ingest can also reach the login page. The protection
   is OpenObserve's own login, not the network.
2. **Treat the ingestion passcode as admin-equivalent** until you have proven otherwise: it is
   the basic-auth password for the user it belongs to, so it may carry that user's full access,
   and it sits in a file on every reporting node. It is rotatable from the UI. Do not assume
   it is write-only.

## What was and was not validated

Run on a Mac with pinned release binaries, nothing installed and no container started:
`scripts/validate-lgtm.sh` (23 checks, shared with the LGTM option).

| Check | Result |
|---|---|
| `docker compose config` for the OpenObserve compose and the drill override merged | passes; the merged drill keeps no live mount and no live port |
| `alloy fmt --test` and `alloy validate`, three OpenObserve configs, Alloy 1.21.3 and 1.22.0 | pass |
| `taylor-pc.alloy` (OpenObserve) run for 34 s against a loopback stand-in for `:5080` | remote-write arrived at `/api/default/prometheus/api/v1/write` with basic auth; the login came from a file and the passcode from `password_file` (a trailing newline in the file was trimmed) |
| Loki push block run against the same stand-in | arrived at `/api/default/loki/api/v1/push` with the same basic auth |
| Image digest, env var names, routes | resolved from the registry and the `v1.1.2` source (see below) |
| Contract tests: pinned image, loopback ports, 30-day retention, no secret in compose, Alloy auth from files, one option's probes live | pass; every injected fault was caught |
| Memory sizing under `mem_limit: 2g` | source-read: OpenObserve derives its caches from the cgroup limit, not the host's 125 GB; not yet run |

From the `v1.1.2` source: `ZO_ROOT_USER_EMAIL`, `ZO_ROOT_USER_PASSWORD`, `ZO_DATA_DIR`,
`ZO_COMPACT_DATA_RETENTION_DAYS` (default 3650), `ZO_TELEMETRY` and `ZO_WEB_URL` exist;
HTTP defaults to 5080 and gRPC to 5081; the routes are `/healthz`,
`/api/{org}/prometheus/api/v1/write`, `/api/{org}/loki/api/v1/push`,
`/api/{org}/v1/{logs,metrics,traces}`, `/api/{org}/passcode` and `/api/{org}/_search`; the
Loki endpoint names the stream from the `stream_name` label.

**Not proven, and measured in the phases below:** the container starts and runs as uid 1000
on the bind mount; the edition is open source; Serve doors on a real tailscaled; basic auth
and ingestion against the real server (the stand-in only proves what Alloy sends); that
retention deletes (it only shows after data is 30 days old); the real backup pause; the
drill's `_search` request shape; the Gatus probes against a live door. No OpenObserve server
was run: the `v1.1.2` release has no downloadable assets (checked), and a Linux image cannot
run on the Mac without starting a container.

## Phase 1: the stack

1. **[!] Deploy checkout**, as in `docs/lgtm-taylor-pc.md` Phase 1 step 1.
2. **[pc] Data directories** (uid 1000 must own them):
   ```bash
   test "$(id -u)" = 1000 || { echo "uid is not 1000: stop"; exit 1; }
   sudo install -d -o "$USER" -g "$USER" -m 0750 /srv/lgtm /srv/lgtm/staging /srv/lgtm/data /srv/lgtm/data/openobserve
   ```
   The root is named `lgtm` for both options so one backup copy and one restic path serve either.
3. **[pc] Secrets file.** You choose the login email; the password is random. Nothing is echoed:
   ```bash
   install -d -m 700 ~/.config/lgtm
   ( umask 077
     read -r -p 'OpenObserve login email: ' E
     printf 'ZO_ROOT_USER_EMAIL=%s\n' "$E" > ~/.config/lgtm/openobserve.env
     printf 'ZO_ROOT_USER_PASSWORD=%s\n' "$(openssl rand -base64 24)" >> ~/.config/lgtm/openobserve.env
     printf 'ZO_WEB_URL=https://%s:8443\n' "$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')" >> ~/.config/lgtm/openobserve.env
     unset E )
   stat -c '%a' ~/.config/lgtm/openobserve.env     # expect 600
   ```
4. **[!] Put the login password in Bitwarden.** It is the human login you will type into the
   UI, so it belongs there. pc to Mac clipboard with no echo, then clear:
   ```bash
   ssh pc "grep '^ZO_ROOT_USER_PASSWORD=' ~/.config/lgtm/openobserve.env | cut -d= -f2-" | pbcopy
   ```
   Paste into a new Bitwarden item ("OpenObserve root login", with the email), then:
   ```bash
   pbcopy </dev/null
   ```
5. **[pc] Preflight and start:**
   ```bash
   docker compose -f ~/deploy/infra/configs/openobserve/compose.yaml config --quiet && echo compose-ok
   ss -ltnH '( sport = :5080 or sport = :5081 )'      # expect no output
   docker compose -f ~/deploy/infra/configs/openobserve/compose.yaml pull
   docker compose -f ~/deploy/infra/configs/openobserve/compose.yaml up -d
   sleep 15; curl -fsS http://127.0.0.1:5080/healthz; echo
   docker compose -f ~/deploy/infra/configs/openobserve/compose.yaml logs --tail 40 | grep -i -E 'permission denied|read-only file system|panic' || echo "no obvious errors"
   ```
   A `permission denied` line means the image does not run cleanly as uid 1000 on this mount:
   stop and report it, do not `chmod -R 777`.
6. **[pc] Serve doors** (asks for your sudo password):
   ```bash
   ~/deploy/infra/configs/openobserve/serve.sh on
   ```
   The output must still list the existing `:443` route. If the LGTM option's `:8443` door is
   still on, remove it first with `configs/lgtm/serve.sh off`.
7. **[!] Verify from the Mac:**
   ```bash
   H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); curl -fsS "https://$H:8443/healthz"; echo
   ```
   Then open `https://$H:8443/` in a browser and sign in with the email and the Bitwarden
   password. Open the About page and confirm the edition is **open source**.
8. **[!] What the container actually received** (retention and telemetry settings):
   ```bash
   ssh pc "docker inspect openobserve-openobserve-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^ZO_(COMPACT_DATA_RETENTION_DAYS|TELEMETRY|DATA_DIR)='"
   ```
   Expect `30`, `false`, `/data`. Retention is applied by compaction to data older than the
   limit, so deletion itself cannot be seen until data is 30 days old (ISC-30).

**Rollback 1:** `docker compose -f ~/deploy/infra/configs/openobserve/compose.yaml down` (data
is kept) and `~/deploy/infra/configs/openobserve/serve.sh off`. Erasing `/srv/lgtm/data/openobserve`
is a separate, explicit decision.

## Phase 2: paging (needs PR #1 applied)

Same prerequisites and steps as `docs/lgtm-taylor-pc.md` Phase 2, with two differences:

- `taylor-pc-reachable` and the `lgtm-backup` heartbeat are shared and need no change.
- Sentinel's config ships the OpenObserve probes **disabled** and the LGTM probes enabled.
  Flip them in a follow-up change before installing the config: set `enabled: false` on
  `lgtm-grafana`, `lgtm-loki-ready` and `lgtm-prometheus-ready`, and `enabled: true` on
  `openobserve-health` and `openobserve-grpc`. Exactly one option's set may be live (the
  sentinel contract test enforces it), because a live probe for a stack that is not running
  pages forever.
- **Guard before the `scp`** in the LGTM runbook's Phase 2 step 2. Following that step verbatim
  with the unflipped file ships the `lgtm-*` probes live against a stack that is not running,
  and they page after five minutes. **[pc]** Stop unless the checkout has the flip:
  ```bash
  F=~/deploy/infra/configs/sentinel/gatus/config.yaml
  test "$(awk '/- name: openobserve-health/{f=1} f&&/enabled:/{print $2; exit}' "$F")" = true \
    && test -n "$(awk '/- name: lgtm-grafana/{f=1;next} f&&/- name:/{exit} f&&/enabled: false/{print "off"}' "$F")" \
    || { echo "this checkout still has the LGTM probes live: flip them first"; exit 1; }
  ```

| Probe | Pages when |
|---|---|
| `openobserve-health` (`:8443/healthz`) | OpenObserve or its Serve route down for 5 min |
| `openobserve-grpc` (TCP `:5081`) | the gRPC forwarder down for 5 min |

Both use `failure-threshold: 5`, so the nightly backup pause never pages. To fire a test alert,
stop the container for 6 minutes, as in the LGTM runbook:
`docker compose -f ~/deploy/infra/configs/openobserve/compose.yaml stop` then `start`.

**Rollback 2:** reinstall the previous `config.yaml` from Git on sentinel and restart Gatus.

## Before Phase 3: tighten the tailnet ACL

`docs/lgtm-tailnet-acl.md`, with the OpenObserve variant at the end: one door, so the ACL
cannot keep reporters off the login page.

## Phase 3: Alloy on every node

Use the files in `configs/alloy/openobserve/`, **not** the LGTM ones. Each node needs three
one-line files: the stack host, the login, and the ingestion passcode. None is committed.

1. **[!] Get the ingestion passcode** from the OpenObserve UI (the ingestion page shows it;
   `GET /api/default/passcode` returns the same value and `PUT` rotates it). Copy it to the Mac
   clipboard. In each node step below, the Mac validates it is one non-empty token before
   writing it, and you clear the clipboard at the end.

   **Prove the passcode works as the basic-auth password before it goes to any node.** The node
   configs assume it does; this is unverified. With the passcode on the clipboard, **[!]**:
   ```bash
   H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); U=$(ssh pc "grep '^ZO_ROOT_USER_EMAIL=' ~/.config/lgtm/openobserve.env | cut -d= -f2-"); P=$(pbpaste)
   curl -s -o /dev/null -w 'without credentials: %{http_code}\n' "https://$H:8443/api/default/prometheus/api/v1/labels"
   printf 'user = "%s:%s"\n' "$U" "$P" | curl -s -o /dev/null -w 'with the passcode:    %{http_code}\n' -K - "https://$H:8443/api/default/prometheus/api/v1/labels"; unset P
   ```
   Expect `401` then `200`. If the passcode is **rejected**, stop: do not distribute it. The
   fallback is to put the root password in `oo-passcode` on each node instead, which puts an
   admin credential on every node, so that is a decision for you rather than a default.
2. **taylor-pc [pc]** (it pushes to the container's loopback port, so it needs no host file):
   ```bash
   sudo pacman -S --needed grafana-alloy
   systemctl cat grafana-alloy | grep -E 'User=|EnvironmentFile=|ExecStart='   # confirm the unit
   grep '^CONFIG_FILE' /etc/default/grafana-alloy                               # expect /etc/grafana-alloy (a directory)
   sudo usermod -aG docker grafana-alloy
   sudo install -m 0644 ~/deploy/infra/configs/alloy/openobserve/taylor-pc.alloy /etc/grafana-alloy/config.alloy
   grep '^ZO_ROOT_USER_EMAIL=' ~/.config/lgtm/openobserve.env | cut -d= -f2- | sudo tee /etc/grafana-alloy/oo-user >/dev/null
   ```
   Then the passcode, from the Mac **[!]**: it is written to a private temp file on pc, never
   to a terminal (`sudo` cannot be fed a password and a passcode on the same pipe):
   ```bash
   P=$(pbpaste); case "$P" in ""|*[[:space:]]*) echo "clipboard is not one token: stop" >&2;; *) printf '%s' "$P" | ssh pc 'umask 077; cat > ~/.config/lgtm/oo-passcode.tmp' ;; esac; unset P
   ```
   Then **[pc]**, which installs it for the service user, deletes the temp file and starts Alloy:
   ```bash
   sudo install -m 0640 -o root -g grafana-alloy ~/.config/lgtm/oo-passcode.tmp /etc/grafana-alloy/oo-passcode && shred -u ~/.config/lgtm/oo-passcode.tmp
   sudo systemctl enable --now grafana-alloy
   journalctl -u grafana-alloy -n 30 --no-pager
   ```
3. **OCI nodes [!]**: sentinel first as the canary, then edge-lab, then openclaw. Install the
   RPM exactly as in `docs/lgtm-taylor-pc.md` Phase 3b (checksum-verified), then, per node:
   ```bash
   scp ~/deploy/infra/configs/alloy/openobserve/linux.alloy opc@<node>:/tmp/
   H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); printf '%s\n' "$H" | ssh opc@<node> 'sudo tee /etc/alloy/lgtm-host >/dev/null'
   ssh pc "grep '^ZO_ROOT_USER_EMAIL=' ~/.config/lgtm/openobserve.env | cut -d= -f2-" | ssh opc@<node> 'sudo tee /etc/alloy/oo-user >/dev/null'
   P=$(pbpaste); case "$P" in ""|*[[:space:]]*) echo "clipboard is not one token: stop" >&2;; *) printf '%s' "$P" | ssh opc@<node> 'sudo install -m 0640 -o root -g alloy /dev/stdin /etc/alloy/oo-passcode' ;; esac; unset P
   ssh opc@<node> 'sudo install -m 0644 /tmp/linux.alloy /etc/alloy/config.alloy; sudo usermod -aG systemd-journal alloy; sudo systemctl enable --now alloy; sleep 5; journalctl -u alloy -n 20 --no-pager'
   ```
4. **The Macs [mac]**, one at a time:
   ```bash
   brew install grafana-alloy
   D=/opt/homebrew/etc/grafana-alloy
   H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); printf '%s\n' "$H" > $D/lgtm-host
   ssh pc "grep '^ZO_ROOT_USER_EMAIL=' ~/.config/lgtm/openobserve.env | cut -d= -f2-" > $D/oo-user
   ( umask 077; pbpaste | tr -d '[:space:]' > $D/oo-passcode )
   install -m 0644 <path-to-checkout>/configs/alloy/openobserve/macos.alloy $D/config.alloy
   brew services start grafana-alloy
   ```
5. **Clear the clipboard** once every node has its passcode: `pbcopy </dev/null`.
6. **Verify.** In the UI: Logs shows streams `journal` and `docker` (taylor-pc, per `host`) and
   `journal` from each Linux node; Metrics shows `up` with `job="integrations/unix"` for every
   node. One API check from the Mac (credentials via a config on stdin, so nothing lands in `ps`):
   ```bash
   H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); U=$(ssh pc "grep '^ZO_ROOT_USER_EMAIL=' ~/.config/lgtm/openobserve.env | cut -d= -f2-"); P=$(pbpaste); printf 'user = "%s:%s"\n' "$U" "$P" | curl -fsS -K - -G "https://$H:8443/api/default/prometheus/api/v1/query" --data-urlencode 'query=count by (host) (up{job="integrations/unix"})' | jq -r '.data.result[] | "\(.metric.host) \(.value[1])"'
   ```
   (the clipboard must hold the **login** password for this one, not the passcode: copy it
   again as in Phase 1 step 4, run the check, then `pbcopy </dev/null`).

**Rollback 3:** taylor-pc `sudo systemctl disable --now grafana-alloy`; OCI nodes
`ssh opc@<node> 'sudo systemctl disable --now alloy'`; Macs `brew services stop grafana-alloy`.
To revoke a node's access, rotate the passcode (`PUT /api/default/passcode`) and redistribute it.

## Phase 4: backup

Identical to `docs/lgtm-taylor-pc.md` Phase 4, with these differences:

- **Select the stack for the backup.** After Phase 2 wrote `~/.config/lgtm/backup.env`, set
  `LGTM_STACK=openobserve` in it (a non-secret line; the default is `lgtm`):
  ```bash
  grep -q '^LGTM_STACK=' ~/.config/lgtm/backup.env && sed -i 's/^LGTM_STACK=.*/LGTM_STACK=openobserve/' ~/.config/lgtm/backup.env || echo 'LGTM_STACK=openobserve' >> ~/.config/lgtm/backup.env
  ```
  The job then stops and restarts only the `openobserve` container around the copy.
- **Step 7's watcher** checks `http://127.0.0.1:5080/healthz` instead of Loki and Prometheus:
  replace both `curl` URLs in it with that one.
- **Drill A** uses the OpenObserve override and queries (run it the day after the first backup;
  the queries look at data at least 24 hours old):
  ```bash
  sudo install -d -o "$USER" -g "$USER" /srv/lgtm-drill
  ( set -a; . ~/.config/lgtm/backup.env; set +a
    export RESTIC_PASSWORD_FILE="$HOME/.config/lgtm/restic.pass"
    restic restore latest --target /srv/lgtm-drill )
  cd ~/deploy/infra/configs/openobserve && docker compose -p openobserve-drill -f compose.yaml -f drill/compose.drill.yaml up -d
  sleep 15; curl -fsS http://127.0.0.1:15080/healthz; echo
  U=$(grep '^ZO_ROOT_USER_EMAIL=' ~/.config/lgtm/openobserve.env | cut -d= -f2-); P=$(grep '^ZO_ROOT_USER_PASSWORD=' ~/.config/lgtm/openobserve.env | cut -d= -f2-)
  printf 'user = "%s:%s"\n' "$U" "$P" | curl -fsS -K - -G http://127.0.0.1:15080/api/default/prometheus/api/v1/query --data-urlencode 'query=count(up)' --data-urlencode "time=$(date -u -d '-26 hours' +%s)" | jq '.data.result'
  printf 'user = "%s:%s"\n' "$U" "$P" | curl -fsS -K - -H 'Content-Type: application/json' -X POST http://127.0.0.1:15080/api/default/_search -d "{\"query\":{\"sql\":\"select count(*) as c from \\\"journal\\\"\",\"start_time\":$(date -d '-48 hours' +%s)000000,\"end_time\":$(date -d '-25 hours' +%s)000000}}" | jq '.hits'
  unset U P
  ```
  **Pass:** `healthz` answers, the PromQL result is non-empty with a value above 0, and the
  search returns a count above 0. The `_search` body follows OpenObserve's search API and has
  not been run; if the server rejects it, check the same window in the drill UI over an SSH
  tunnel to `127.0.0.1:15080`. Clean up (the removal is a delete: confirm first):
  ```bash
  docker compose -p openobserve-drill down
  rm -rf /srv/lgtm-drill
  ```
- **Drill B** (the Mac, with the Bitwarden restic password): restore with
  `--include '*/openobserve/*'` instead of `*/grafana/*`, and pass when files are restored
  under `openobserve/` and `restic check` exits 0.

**Rollback 4:** as in the LGTM runbook: disable the two user timers. Switching option later
means setting `LGTM_STACK` back and `down`-ing the other stack; the data directories do not
collide.

## Secrets: where each one lives

| Secret | Created in | Lives in | Never in |
|---|---|---|---|
| OpenObserve root password | Phase 1 step 3 | taylor-pc `openobserve.env` (0600) **and** the Bitwarden item | Git, a transcript |
| Ingestion passcode | the UI, Phase 3 step 1 | `oo-passcode` on each node (0640 or 0600); the Mac clipboard briefly | Git, a transcript, a URL |
| Login email | Phase 1 step 3 | `openobserve.env` on taylor-pc, `oo-user` on each node | Git |

Backup, Gatus and restic secrets are unchanged: see `docs/lgtm-taylor-pc.md`.

## ISA criteria (OpenObserve option)

Numbering continues from the LGTM rows (ISC-16 to ISC-24). Live rows stay `[ ]` until the
check is recorded with a date.

| isc | type | check | threshold | tool | anchors_to |
|---|---|---|---|---|---|
| ISC-25 | static | The OpenObserve image is pinned by stable tag and digest, ports are loopback-only, retention is 30 days, no secret is in the compose file | contract test passes | `bun scripts/test-lgtm-contract.ts` | Constraints |
| ISC-25.1 | static | Alloy sends to OpenObserve with basic auth from files, never inline | contract test passes | contract test | Constraints |
| ISC-26 | live | The container runs as uid 1000 and answers | `/healthz` 200 locally and through the door; no permission errors | Phase 1 steps 5 and 7 | Vision |
| ISC-26.1 | live | The running edition is open source | About page says so | Phase 1 step 7 | Constraints |
| ISC-27 | live | Only the two Serve doors were added and `:443` is untouched | `tailscale serve status` | `serve.sh status` | Constraints |
| ISC-28 | live | Every node's metrics and logs arrive | `up` per node; `journal` stream per Linux node | Phase 3 step 6 | Vision |
| ISC-29 | live | A stack outage pages and resolves, and only this option's probes are live | notification and resolved notice, timestamps | Phase 2 | Vision |
| ISC-30 | live | Retention deletes data older than 30 days | at day 31, the earliest record in a stream is not older than 31 days | UI stream stats | Constraints |
| ISC-31 | live | The nightly backup completes with a short pause, and a restore is queryable | `writers down` under 90 s; Drill A and B pass | Phase 4 | Vision |

## Not in this PR

- Grafana-style alert rules and dashboards for OpenObserve (its alerts and dashboards are
  configured in the UI).
- An OpenObserve-specific Ansible role, the ACL policy itself, and optional OTLP traces from
  applications (the gRPC door exists for them).
- Anything on taylor-pc: this PR changes no host.
