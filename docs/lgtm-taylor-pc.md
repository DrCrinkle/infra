# Personal LGTM on taylor-pc: deploy runbook

Grafana, Loki, Tempo and Prometheus in one `docker compose` project on taylor-pc, a
Grafana Alloy on every node, a nightly restic backup to rsync.net, and sentinel's Gatus
as the pager that survives taylor-pc dying.

**Nothing in this repository has been applied to any host.** Every command below is for
Taylor to run, phase by phase, and each phase ends with a rollback.

## How the pieces fit

```
 every node (Alloy) ──tailnet──▶ Tailscale Serve doors on taylor-pc ──▶ 127.0.0.1
                                  :8443 Grafana      → :3300 (host network)
                                  :3100 Loki         → container
                                  :9090 Prometheus   → container
                                  :4317/:4318 Tempo  → container

 03:30 nightly:  stop 4 containers → rsync to /srv/lgtm/staging → start → restic → rsync.net
                                                                            │
 sentinel Gatus ── probes the same doors; backup pushes its heartbeat ◀─────┘
```

| Component | Version | Where it runs |
|---|---|---|
| Grafana | 13.3.1 | container, host network, `127.0.0.1:3300` |
| Loki | 3.7.10 | container, `127.0.0.1:3100`, 30 days |
| Tempo | 3.1.1 | container, `127.0.0.1:3200/4317/4318`, 30 days, no Kafka |
| Prometheus | 3.16.0 | container, `127.0.0.1:9090`, 30 days (50 GB guard) |
| Alloy | 1.22.0 (configs also validated on 1.21.3) | host package on every node |
| restic | pacman `restic` | host, taylor-pc |

Data lives in `/srv/lgtm/data` on the local NVMe. Images are pinned by tag and digest, and
no container carries a Watchtower label, so nothing auto-updates.

## How to read the steps

- **[!]** paste into your coding-agent session on the Mac with the `!` prefix, so the
  command runs from there. These need no sudo and print no secret.
- **[pc]** run in your **own terminal on taylor-pc**. These need `sudo`, whose password
  a `!` line cannot take, or they are interactive.
- **[mac]** run on the Mac in your own terminal.

**The `[pc]` blocks are bash.** CachyOS ships fish as its default shell, and fish rejects
`( ... )`, `$(...)` assignments and `for ... do`. If your prompt on taylor-pc is fish, type
`bash` first. The `[!]` one-liners that run `ssh pc '...'` are plain commands and work from
any shell.

`ssh pc` means your existing alias for taylor-pc. A `$H` on the Mac is a tailnet name
looked up at run time, so no tailnet name or address is typed or committed:

```bash
H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")')
```

## Order and prerequisites

1. **PR #1 is merged** (https://github.com/DrCrinkle/infra/pull/1: second SSH key, Gatus
   ntfy alerting, gateway route), and this branch is based on it. Phase 2 needs it **applied**
   to sentinel: until then sentinel has no alerting, and this PR's Gatus checks use its
   `alerting.ntfy` block. Phases 1 and 3 do not depend on it. Phase 4 uses the `backup.env`
   that Phase 2 step 1 writes, so in practice it follows Phase 2.
2. **The tailnet ACL comes before any door opens:** `docs/lgtm-tailnet-acl.md`, in the admin
   console, applied before Phase 1 step 6. The ingest doors have no auth of their own.
3. Phases run in order 1, 2, 3, 4. Phase 5 (Grafana alert rules) is not part of this PR.

## What was and was not validated

Run on the Mac with release binaries at the pinned versions, checksum-verified, nothing
installed and nothing started: `scripts/validate-lgtm.sh`.

| Check | Result |
|---|---|
| `docker compose config` (compose v5.7.1, no daemon), including the drill override merged | passes; merged drill config keeps no live mount, no live port |
| `promtool check config` 3.16.0, `loki -verify-config` 3.7.10, `tempo -config.verify` 3.1.1 | pass; each rejects a deliberately misspelled retention key |
| Loki `limits_config.deletion_mode: disabled` | parses; Loki rejects an invalid mode; `-print-config-stderr` shows `deletion_mode: disabled`, `retention_enabled: true` and a 30d retention period |
| `alloy fmt --test` and `alloy validate`, 1.21.3 and 1.22.0, all three configs | pass |
| `shellcheck -S style`, contract test, stubbed backup behavior test | pass. Faults were injected by hand while writing them and each was caught; the injection harness is **not committed**, so that is not reproducible from this repo |
| `macos.alloy` as committed, run for 34 s against a loopback sink | read the host file, pushed to `:9090/api/v1/write` and `:3100/loki/api/v1/push`, no errors or warnings. `linux.alloy` and `taylor-pc.alloy` were not run as committed (they need Linux journald and Docker); they were validated and formatted only |

**Not proven, and measured in the phases below:** containers start, run as UID 1000 on
the bind mounts, and apply retention; `serve.sh` against a real tailscaled; Grafana
`auth.proxy` login and the Admin role; `loki.source.journal` and the Docker log source on
Linux; restic over SFTP to rsync.net; the real pause length; Gatus accepting the push.
`alloy validate` also does not evaluate component arguments, so the URL building was
checked by actually running Alloy, not by validate.

## Before any door opens: the tailnet ACL

Do `docs/lgtm-tailnet-acl.md` in the admin console **now**, before Phase 1 step 6. The five Serve
doors are open to every device on your Tailscale login until it is applied: they can push to, read
from and be Org Admin on the stack. Steps 1 to 5 of Phase 1 open no door, so they can run first.
Include tagging sentinel (the doc says why and how).

## Phase 1: the stack

1. **[!] Deploy checkout** (clean, read-only, kept apart from the dirty `~/projects/infra`).
   Until this PR is merged, check out its branch instead of `main`:
   ```bash
   ssh pc 'git clone https://github.com/DrCrinkle/infra ~/deploy/infra'
   # before the merge only:
   ssh pc 'git -C ~/deploy/infra fetch origin fm/lgtm-pc-build && git -C ~/deploy/infra checkout fm/lgtm-pc-build'
   # later updates:
   ssh pc 'git -C ~/deploy/infra pull --ff-only'
   ```
2. **[pc] Data directories** (uid 1000 must own them: the containers run as 1000):
   ```bash
   test "$(id -u)" = 1000 || { echo "uid is not 1000: stop"; exit 1; }
   sudo install -d -o "$USER" -g "$USER" -m 0750 /srv/lgtm /srv/lgtm/staging \
     /srv/lgtm/data /srv/lgtm/data/{grafana,loki,tempo,prometheus}
   ```
3. **[pc] Secrets file** (random break-glass password, no value echoed):
   ```bash
   install -d -m 700 ~/.config/lgtm
   ( umask 077
     printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 24)" > ~/.config/lgtm/lgtm.env
     printf 'GF_SERVER_ROOT_URL=https://%s:8443/\n' \
       "$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')" >> ~/.config/lgtm/lgtm.env )
   stat -c '%a' ~/.config/lgtm/lgtm.env     # expect 600
   ```
   The break-glass login is user `admin` with that password. It exists only on this host.
   Read it when you need it with `grep '^GF_SECURITY_ADMIN_PASSWORD=' ~/.config/lgtm/lgtm.env | cut -d= -f2-`.
4. **[pc] Preflight** (compose resolves; ports free):
   ```bash
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml config --quiet && echo compose-ok
   ss -ltnH '( sport = :3100 or sport = :3200 or sport = :3300 or sport = :4317 or sport = :4318 or sport = :9090 )'   # expect no output
   ```
5. **[pc] Start:**
   ```bash
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml pull
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml up -d
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml ps
   for u in http://127.0.0.1:3100/ready http://127.0.0.1:9090/-/ready http://127.0.0.1:3200/ready http://127.0.0.1:3300/api/health; do
     printf '%s ' "$u"; curl -fsS -m 5 "$u" | head -c 80; echo; done
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml logs --tail 30 | grep -i -E 'permission denied|read-only file system' || echo "no permission errors"
   ```
   Loki and Tempo can take about a minute to report ready. A `permission denied` line means
   the images do not run cleanly as uid 1000 on these mounts: stop and report it, do not
   `chmod -R 777`.
6. **[pc] Serve doors.** **Gate: the tailnet ACL above must be applied first.** Phase 3 opens
   with a check that must fail, and finds out if it was not. (Asks for your sudo password.)
   ```bash
   ~/deploy/infra/configs/lgtm/serve.sh on
   ```
   The output must still list the existing `:443` route. Nothing here touches it.
7. **[!] Verify from the Mac** (Serve adds your Tailscale identity; no secret is printed):
   ```bash
   H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); curl -fsS "https://$H:8443/api/health"; echo; curl -fsS "https://$H:8443/api/user/orgs" | jq -r '.[0].role'; curl -fsS "https://$H:8443/api/datasources" | jq -r '.[].name'
   ```
   Expect `"database": "ok"`, then `Admin`, then `Prometheus`, `Loki`, `Tempo`. Then open
   `https://$H:8443/` in a browser: you are logged in without a password.
8. **[!] Retention in effect** (confirms what the containers actually loaded):
   ```bash
   ssh pc 'curl -fsS http://127.0.0.1:9090/api/v1/status/runtimeinfo | jq -r .data.storageRetention; curl -fsS http://127.0.0.1:3100/config | grep -E -m3 "^ *(retention_period|retention_enabled|deletion_mode):"; curl -fsS http://127.0.0.1:3200/status/config | grep -m1 block_retention'
   ```
   Expect `30d` from Prometheus. From Loki: `retention_enabled: true`, `deletion_mode: disabled` and a
   30 day `retention_period`. Loki prints durations in days (`30d`), as `-print-config-stderr`
   did when this was written, so `30d` and `720h` are the same value. From Tempo: `block_retention`
   at 30 days (`720h`, or a form of it). **`deletion_mode: disabled` matters**: without it, a
   reporter that can reach `:3100` could delete every host's logs. If an endpoint is missing in
   these versions, read the loaded config from the container logs instead.

**Rollback 1:** `docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml down` (data is
kept) and `~/deploy/infra/configs/lgtm/serve.sh off`. Erasing `/srv/lgtm` is a separate,
explicit decision.

## Phase 2: paging (needs PR #1 applied to sentinel)

This phase installs the last commit of this PR: sentinel's Gatus config with the stack
checks. PR #1 is merged, but check that it is **applied** on sentinel
(`ssh opc@sentinel 'grep -c ntfy /etc/gatus/config.yaml'` is non-zero) before you start.

| Check | Pages when |
|---|---|
| `taylor-pc-reachable` (ICMP) | taylor-pc off, asleep, off the tailnet, home uplink down, or a reboot over 5 min |
| `lgtm-grafana` (`:8443/api/health`) | Grafana or its Serve route down for 5 min |
| `lgtm-loki-ready` (`:3100/ready`) | Loki or its forwarder down for 5 min |
| `lgtm-prometheus-ready` (`:9090/-/ready`) | Prometheus or its forwarder down for 5 min |
| `lgtm-backup` (heartbeat, **disabled** until Phase 4) | a push with `success=false` pages at once; a missed nightly run pages **26 to 52 hours** after the last good backup |
| `lgtm-restic-check` (heartbeat, **disabled** until Phase 4; `192h`, Gatus has no day unit) | a failed weekly check pages at once; a weekly check that stops running pages **8 to 16 days** after the last good one, as long as Gatus is not restarted in between |

**The three service probes ship `enabled: false`.** Until Phase 1 opens the Serve doors they would
page for doors that do not exist, and the committed file is what a sentinel redeploy from `main`
copies. Step 2 below turns them on in the copy it installs; `taylor-pc-reachable` ships enabled.

The three service checks use `failure-threshold: 5` so the nightly backup pause never
pages. The two heartbeat alerts use `failure-threshold: 1` and `success-threshold: 1`: with one
push per run, PR #1's defaults (3 failures, 2 successes) would take three missed runs to
page and two good ones to resolve.

**Why 26 to 52 hours, not 26.** Gatus checks a heartbeat on a ticker of the heartbeat interval
that starts when Gatus starts; on each tick it asks whether anything arrived in the last
interval. A missed run is therefore noticed at the next tick after the interval has passed,
which is between one and two intervals after the last push, depending on when Gatus last
restarted (every `systemctl restart gatus` restarts the clock). **If Gatus restarts more often than
the interval, the ticker never fires:** every config install restarts it, so a weekly check that has
silently stopped is only noticed after Gatus has stayed up for 8 days. A `success=false` push is
immediate, so a check that runs and fails always pages. Confirmed by reading `watchdog/external_endpoint.go` at Gatus v5.24.3, the version the plan pins
for sentinel; the earlier review of this PR reached the same reading from Gatus `master`.
Sentinel's actual build was not checked and no Gatus was run, so Phase 4's fire test is what
measures it.

**Each job has its own endpoint.** The backup reports to `lgtm-backup` and the weekly integrity
check to `lgtm-restic-check`. With one shared endpoint, Monday's good backup cleared Sunday's
failed-check alert about 22 hours later, with a resolved notice, while the repository was still
damaged, and a check that stopped running was invisible.

1. **[pc] Backup file and token.** One shell line writes the same token to both sides and
   never echoes it, in the order PR #1's doc requires (**token before config**). Run it
   once; a second run would append a second token line.
   ```bash
   install -d -m 700 ~/.config/lgtm
   ( umask 077
     S=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="sentinel") | .DNSName | rtrimstr(".")')
     printf 'RESTIC_REPOSITORY=sftp:rsyncnet-lgtm:lgtm-restic\nGATUS_URL=http://%s:8080\n' "$S" > ~/.config/lgtm/backup.env
     T=$(openssl rand -hex 24)
     printf 'GATUS_LGTM_BACKUP_TOKEN=%s\n' "$T" >> ~/.config/lgtm/backup.env
     printf 'GATUS_LGTM_BACKUP_TOKEN=%s\n' "$T" | ssh opc@sentinel 'sudo tee -a /etc/gatus/gatus.env >/dev/null'
     unset T )
   ```
   Mirror the token into the Ansible vault (`vault_gatus_lgtm_backup_token`) when the
   sentinel role reaches Git.
2. **[pc] Render and install the config** (Phase 0's manual procedure). It replaces sentinel's file
   wholesale, so the checkout must contain PR #1's `alerting:` block or that is removed (this
   branch and `main` both do); the guard stops the copy otherwise. The render turns the three
   service probes on in a copy; the committed file is not edited.
   ```bash
   F=~/deploy/infra/configs/sentinel/gatus/config.yaml; LIVE=/tmp/gatus-live.yaml
   grep -q '^alerting:' "$F" || { echo "this checkout lacks PR #1: stop"; exit 1; }
   sed -E '/^  - name: lgtm-(grafana|loki-ready|prometheus-ready)$/,/^    url:/ s/enabled: false/enabled: true/' "$F" > "$LIVE"
   diff "$F" "$LIVE"      # expect exactly three changed lines, each enabled: false -> enabled: true
   scp "$LIVE" opc@sentinel:/tmp/config.yaml
   ssh opc@sentinel 'sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl restart gatus && systemctl is-active gatus'
   ```
   Gatus parses durations as Go durations, so a bad interval (the config once had `8d`) makes it
   **panic at load and the whole pager goes down**. `systemctl is-active` can still say `active` for a
   moment, so step 3's check is what proves it loaded.
3. **[!] Verify** (all four probe checks green; the two heartbeats are disabled, so absent):
   ```bash
   ssh opc@sentinel 'curl -fsS http://127.0.0.1:8080/api/v1/endpoints/statuses' | jq -r '.[] | select(.group=="lgtm") | "\(.name) \(.results[-1].success)"'
   ```
4. **[pc] Fire one test alert** and record both timestamps in the ISA: stop Loki for 6 minutes,
   confirm the phone buzzes, restart it, confirm the resolved notice:
   ```bash
   date -u +%FT%TZ; docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml stop loki
   # wait 6 minutes, watch the phone
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml start loki; date -u +%FT%TZ
   ```

**Rollback 2:** reinstall the previous `config.yaml` from Git on sentinel and restart Gatus.
The extra `gatus.env` line can stay.

## Phase 3: Alloy on every node

**3-0. Gate: prove the tailnet ACL is in effect. This check must FAIL on the denied path.** Do
not start any node until you have seen the three results below. From the Mac **[!]**:

```bash
H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")')
printf 'Mac to Grafana (allowed):        '; curl -sS -m 8 -o /dev/null -w '%{http_code}\n' "https://$H:8443/api/health"
printf 'edge-lab to Loki (allowed):      '; ssh opc@edge-lab "curl -sS -m 8 -o /dev/null -w '%{http_code}\n' http://$H:3100/ready"
printf 'edge-lab to Grafana (DENIED):    '; ssh opc@edge-lab "curl -sS -m 8 -o /dev/null -w '%{http_code}\n' https://$H:8443/api/health"
```

Expect `200`, `200`, then `000` (a timeout, with curl's `curl: (28)` message). The second line is the
control: it proves edge-lab can resolve the name and reach taylor-pc at all, so the third `000` means
the ACL refused it and not a DNS or routing problem. **If the third line prints `200`, the ACL is not
applied: stop, go back to `docs/lgtm-tailnet-acl.md`, and do not run Phase 3.** If the second line is
not `200`, fix reachability first. Also run the sentinel check from the ACL doc ("Tag sentinel").


Alloy reads the stack's host from a one-line file (`lgtm-host`) instead of a committed
address: the tailnet name on every other node, `127.0.0.1` on taylor-pc (a Linux host often
cannot reach its own Serve ports, and its containers publish on loopback). `loki.write` has no WAL, so logs from an outage longer than a few minutes drop;
metrics keep an 8 h WAL.

**3a. taylor-pc [pc]** (Arch package `grafana-alloy`; unit `grafana-alloy`, config
directory `/etc/grafana-alloy`, user `grafana-alloy`, already in `systemd-journal`):

```bash
sudo pacman -S --needed grafana-alloy
pacman -Q grafana-alloy
systemctl cat grafana-alloy | grep -E 'User=|EnvironmentFile=|ExecStart='   # confirm the unit
grep '^CONFIG_FILE' /etc/default/grafana-alloy                               # expect /etc/grafana-alloy (a directory)
sudo usermod -aG docker grafana-alloy       # container logs; the socket is root-equivalent, accepted on this host only
sudo install -m 0644 ~/deploy/infra/configs/alloy/taylor-pc.alloy /etc/grafana-alloy/config.alloy
echo 127.0.0.1 | sudo tee /etc/grafana-alloy/lgtm-host >/dev/null   # local stack: loopback, not its own Serve doors
sudo systemctl enable --now grafana-alloy
journalctl -u grafana-alloy -n 30 --no-pager
```

The directory is loaded as a whole, so `/etc/grafana-alloy/` must contain only this one
`*.alloy` file. If `CONFIG_FILE` or the unit differs from the above on CachyOS (its
packages are rebuilt), follow what `systemctl cat` shows.

**3b. OCI nodes: sentinel first as the canary, then edge-lab, then openclaw [!].** The
nodes are AlmaLinux; openclaw is arm64, sentinel and edge-lab are x86_64. The RPM's unit is
`alloy`, config `/etc/alloy/config.alloy`, user `alloy`. Per node (`<node>` is the SSH name,
`<arch>` is `amd64` or `arm64`):

```bash
ssh opc@<node> 'uname -m'    # x86_64 -> amd64, aarch64 -> arm64
V=1.22.0; ssh opc@<node> "cd /tmp && curl -fsSLO https://github.com/grafana/alloy/releases/download/v$V/alloy-$V-1.<arch>.rpm && curl -fsSLO https://github.com/grafana/alloy/releases/download/v$V/SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS && sudo dnf install -y ./alloy-$V-1.<arch>.rpm"
scp ~/deploy/infra/configs/alloy/linux.alloy opc@<node>:/tmp/
H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); printf '%s\n' "$H" | ssh opc@<node> 'sudo tee /etc/alloy/lgtm-host >/dev/null'
ssh opc@<node> 'sudo install -m 0644 /tmp/linux.alloy /etc/alloy/config.alloy; id alloy; sudo usermod -aG systemd-journal alloy; sudo systemctl enable --now alloy; sleep 5; journalctl -u alloy -n 20 --no-pager'
```

The `sha256sum -c` line must print `OK` for the RPM before `dnf` runs; if it does not, the
`&&` chain stops. Run the `H=` line from a machine with the tailscale CLI (the Mac, or taylor-pc).

**3c. The Macs [mac]**, one at a time (Apple Silicon prefix `/opt/homebrew`):

```bash
brew install grafana-alloy
H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); printf '%s\n' "$H" > /opt/homebrew/etc/grafana-alloy/lgtm-host
install -m 0644 <path-to-checkout>/configs/alloy/macos.alloy /opt/homebrew/etc/grafana-alloy/config.alloy
brew services start grafana-alloy
brew services info grafana-alloy
```

If `brew info grafana-alloy` shows a different config directory, use that one.

**Verify Phase 3 [!]** (give each node a minute; counts are per node):

```bash
H=$(tailscale status --json | jq -r '.Peer[] | select(.HostName=="taylor-pc") | .DNSName | rtrimstr(".")'); curl -fsS -G "http://$H:9090/api/v1/query" --data-urlencode 'query=count by (host) (up{job="integrations/unix"})' | jq -r '.data.result[] | "\(.metric.host) \(.value[1])"'; curl -fsS -G "http://$H:3100/loki/api/v1/query" --data-urlencode 'query=sum by (host) (count_over_time({job="journal"}[5m]))' | jq -r '.data.result[] | "\(.metric.host) \(.value[1])"'
```

Expect one metrics line per node and one journal line per Linux node. Then open the
Explore view in Grafana and run `{job="docker"}` for the container logs.

**Rollback 3:** taylor-pc `sudo systemctl disable --now grafana-alloy`; OCI nodes
`ssh opc@<node> 'sudo systemctl disable --now alloy'` (optionally `sudo dnf remove alloy`);
Macs `brew services stop grafana-alloy`.

## Phase 4: backup to rsync.net

Escrow comes first. If the restic password is lost, the backups are unreadable.

1. **[!] Give taylor-pc its own rsync.net key.** Additive: appends one key, removes nothing.
   Expect **one more fingerprint than before** and `alias rsyncnet-lgtm works`. The sshfs
   mount, GitSync and rclone keep using the old key (Decision 8, separate task).
   ```bash
   ssh pc 'bash ~/deploy/infra/configs/lgtm/backup/rsyncnet-own-key.sh'
   ```
   It saves a local copy of the keys file first (`~/.config/lgtm/rsyncnet-authorized_keys.*`)
   and prints the restore command if the count is not exactly one more.
2. **[pc] Install restic:** `sudo pacman -S --needed restic`
3. **[pc] Create the repository password** (never printed):
   ```bash
   install -d -m 700 ~/.config/lgtm
   ( umask 077; openssl rand -base64 32 > ~/.config/lgtm/restic.pass )
   ```
4. **[!] Escrow it in Bitwarden** (Decision 5; this bends the "Bitwarden holds human logins
   only" rule on purpose, because restoring after taylor-pc dies is a human act). The
   password goes pc → Mac clipboard with no echo; paste it into a new Bitwarden item,
   then clear the clipboard:
   ```bash
   ssh pc 'cat ~/.config/lgtm/restic.pass' | pbcopy
   ```
   Paste into Bitwarden (item: "LGTM restic repository password"), confirm it saved, then:
   ```bash
   pbcopy </dev/null
   ```
   **Do not continue until the Bitwarden item exists.**
5. **[pc] Create the repository:**
   ```bash
   ( set -a; . ~/.config/lgtm/backup.env; set +a
     export RESTIC_PASSWORD_FILE="$HOME/.config/lgtm/restic.pass"
     restic init && restic snapshots )
   ```
6. **[pc] Install the units** (do not enable the timers yet):
   ```bash
   install -d ~/.config/systemd/user
   install -m 0644 ~/deploy/infra/configs/lgtm/systemd/lgtm-*.service ~/deploy/infra/configs/lgtm/systemd/lgtm-*.timer ~/.config/systemd/user/
   systemctl --user daemon-reload
   loginctl show-user "$USER" -p Linger        # expect Linger=yes
   ```
7. **[pc] First backup by hand, timed.** In a second terminal, start this watcher first. It
   measures from the moment Loki and Prometheus stop answering until both answer again:
   ```bash
   down=""; while :; do
     if curl -fsS -m 2 http://127.0.0.1:3100/ready >/dev/null 2>&1 && curl -fsS -m 2 http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
       if [ -n "$down" ]; then echo "ready again after $(( $(date +%s) - down ))s"; break; fi
     else [ -n "$down" ] || down=$(date +%s); fi
     sleep 1; done
   ```
   Then in the first terminal (the first run uploads everything over Wi-Fi and can take a while):
   ```bash
   systemctl --user start lgtm-backup.service
   journalctl --user -u lgtm-backup -n 20 --no-pager     # note "writers down for Ns"
   ```
   While `lgtm-backup` is still `enabled: false` in Gatus, no dead-man is watching, but Gatus
   still accepts the push (seen on v5.24.3 by the re-review; the handler has no enabled check), so no
   warning is expected in this journal. A failed hand-run backup pushes `success=false`, which does
   page, even now.
   **Pass:** `writers down` under 90 s, and the watcher's gap under 180 s (inside the
   5 × 60 s Gatus threshold). If the gap is over about 3 minutes, **do not enable the
   timer**: raise the threshold or change the design first. Check the check that does not
   depend on the clock: `restic snapshots` shows one `lgtm` snapshot.
8. **[pc] Drill A: prove a restore works.** The queries ask what the restored stack held **one hour
   before the snapshot was taken**, so the drill can run right after step 7 as long as Alloy had
   been shipping for more than an hour before that backup. (An earlier version queried a fixed
   26 hours back, which fails on a good restore if the drill is not done within 26 hours of the
   backup.) The time comes from the snapshot, via GNU `date`; it has not been run on taylor-pc.
   ```bash
   sudo install -d -o "$USER" -g "$USER" /srv/lgtm-drill
   ( set -a; . ~/.config/lgtm/backup.env; set +a
     export RESTIC_PASSWORD_FILE="$HOME/.config/lgtm/restic.pass"
     restic restore latest --target /srv/lgtm-drill )
   cd ~/deploy/infra/configs/lgtm && docker compose -p lgtm-drill -f compose.yaml -f drill/compose.drill.yaml up -d
   SNAP=$( ( set -a; . ~/.config/lgtm/backup.env; set +a; export RESTIC_PASSWORD_FILE="$HOME/.config/lgtm/restic.pass"; restic snapshots --json --latest 1 --tag lgtm ) | jq -r '[.[].time] | sort | last')
   T=$(date -u -d "@$(( $(date -d "$SNAP" +%s) - 3600 ))" +%Y-%m-%dT%H:%M:%SZ)
   echo "snapshot at $SNAP; querying at $T"
   curl -fsS -G http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=count(up)' --data-urlencode "time=$T" | jq '.data.result'
   curl -fsS -G http://127.0.0.1:13100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({job="journal"}[1h]))' --data-urlencode "time=$T" | jq '.data.result'
   curl -fsS http://127.0.0.1:13300/api/health; ls /srv/lgtm-drill/srv/lgtm/staging/grafana
   ```
   **Pass:** Prometheus returns a value above 0, Loki returns a sum above 0, and Grafana
   answers health on `:13300` with its `grafana.db` restored. Check the drill Grafana's
   datasources in `docker compose -p lgtm-drill logs grafana` or its UI via an SSH tunnel.
   Clean up (the removal is a delete: confirm before you run it):
   ```bash
   docker compose -p lgtm-drill down
   rm -rf /srv/lgtm-drill
   ```
   Record the date and result in the ISA.
9. **[pc] One-time dead-man fire test, with the timers still off.** Until a missing push has
   been seen to page, the dead-man is an assumption. This also proves that sentinel's Gatus build
   supports `heartbeat` (it first appears in Gatus 5.21.0's README; sentinel runs a source build
   and its version has not been checked). It installs a throwaway config with a two-minute
   heartbeat on `lgtm-backup`, then restores the real one. The timers must be off, or a nightly
   push would reset it.
   ```bash
   systemctl --user is-enabled lgtm-backup.timer lgtm-restic-check.timer    # expect disabled, disabled
   F=~/deploy/infra/configs/sentinel/gatus/config.yaml; LIVE=/tmp/gatus-live.yaml
   sed -E '/^  - name: lgtm-(grafana|loki-ready|prometheus-ready)$/,/^    url:/ s/enabled: false/enabled: true/' "$F" > "$LIVE"       # re-render what Phase 2 step 2 installed
   sed -E '/^  - name: lgtm-backup$/,/failure-threshold: 1/{s/enabled: false/enabled: true/;s/interval: 26h/interval: 2m/;}' "$LIVE" > /tmp/gatus-firetest.yaml
   diff "$LIVE" /tmp/gatus-firetest.yaml        # expect exactly two changed lines: enabled and interval
   ssh opc@sentinel 'sudo cp /etc/gatus/config.yaml /etc/gatus/config.yaml.pre-firetest'
   scp /tmp/gatus-firetest.yaml opc@sentinel:/tmp/config.yaml
   date -u +%FT%TZ; ssh opc@sentinel 'sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl restart gatus && systemctl is-active gatus'
   ```
   Wait about five minutes. **Pass:** the phone gets a `lgtm-backup` alert (no push has arrived, so
   the ticker finds nothing). Then send the success the real job would, and expect the resolved
   notice (the token is read from the file by a shell builtin, never printed):
   ```bash
   ( set -a; . ~/.config/lgtm/backup.env; set +a
     printf 'header = "Authorization: Bearer %s"\n' "$GATUS_LGTM_BACKUP_TOKEN" | curl -sS -K - -X POST -o /dev/null -w '%{http_code}\n' "$GATUS_URL/api/v1/endpoints/lgtm_lgtm-backup/external?success=true" )
   ```
   Expect `200`. Then restore the real config and record both timestamps in the ISA:
   ```bash
   scp "$LIVE" opc@sentinel:/tmp/config.yaml
   ssh opc@sentinel 'sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl restart gatus && systemctl is-active gatus'
   rm /tmp/gatus-firetest.yaml
   ```
   **If no alert comes:** read `ssh opc@sentinel 'journalctl -u gatus -n 40 --no-pager'`.
   **No alert and no error means sentinel's build is too old to support `heartbeat`:** a build
   without it ignores the key silently (shown with Gatus v5.20.0 by the re-review), so neither
   dead-man exists. Rebuild Gatus (`configs/README.md`) before relying on either. **An error naming a
   duration** (such as `cannot unmarshal ... into time.Duration`) means the build does support it
   and an interval is not a Go duration; Gatus is down until a valid file is installed. Restore the
   real config either way.
   `lgtm-restic-check` uses the same mechanism, so one passing test covers both.
10. **[pc] Enable the timers:**
    ```bash
    systemctl --user enable --now lgtm-backup.timer lgtm-restic-check.timer
    systemctl --user list-timers 'lgtm-*'
    ```
11. **Flip both heartbeats to enabled.** Render the final copy from the live one and install it
    the same way as Phase 2 step 2:
    ```bash
    F=~/deploy/infra/configs/sentinel/gatus/config.yaml; LIVE=/tmp/gatus-live.yaml
    sed -E '/^  - name: lgtm-(grafana|loki-ready|prometheus-ready)$/,/^    url:/ s/enabled: false/enabled: true/' "$F" > "$LIVE"
    sed -E '/^  - name: lgtm-(backup|restic-check)$/,/^      interval:/ s/enabled: false/enabled: true/' "$LIVE" > /tmp/gatus-final.yaml
    diff "$LIVE" /tmp/gatus-final.yaml      # expect exactly two changed lines
    scp /tmp/gatus-final.yaml opc@sentinel:/tmp/config.yaml
    ssh opc@sentinel 'sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl restart gatus && systemctl is-active gatus'
    ```
    Once the stack is live, commit the same flips to `configs/sentinel/gatus/config.yaml` (and update
    the sentinel contract test's "ships disabled" expectations in the same commit), so a later
    redeploy from `main` keeps them. After the first scheduled push the check is green. A missed night then pages 26 to 52 hours after the last good backup; a
    weekly check that stops running pages 8 to 16 days after the last good one.

**Drill B: the backup is reachable without taylor-pc [mac], once.** The Mac's key is already
authorized on rsync.net, and the password is in Bitwarden. Put your rsync.net `user@host`
where shown:

```bash
pbpaste | restic -r sftp:<user>@<host>:lgtm-restic --password-file /dev/stdin snapshots
mkdir -p /tmp/lgtm-drill-b && pbpaste | restic -r sftp:<user>@<host>:lgtm-restic --password-file /dev/stdin restore latest --include '*/grafana/*' --target /tmp/lgtm-drill-b
pbpaste | restic -r sftp:<user>@<host>:lgtm-restic --password-file /dev/stdin check
find /tmp/lgtm-drill-b -name grafana.db
pbcopy </dev/null; rm -rf /tmp/lgtm-drill-b
```

Copy the Bitwarden password to the clipboard first. **Pass:** `grafana.db` is found and
`restic check` exits 0.

**Rollback 4:** `systemctl --user disable --now lgtm-backup.timer lgtm-restic-check.timer`.
The rsync.net repository stays; deleting it is a separate decision.

## Real restore: taylor-pc lost its data or the stack is damaged

The drills restore into scratch directories. A real restore into the live stack has one trap, so
follow these steps and not "restore to the original path".

**Why.** Snapshots hold `/srv/lgtm/staging`, not `/srv/lgtm/data`. Restoring onto the original path
puts the good copy in `staging`, but the stack starts from `data`. The next 03:30 run then mirrors
`data` over `staging` with `rsync --delete` and snapshots that, and the good snapshots age out under
`--keep-daily 7 --keep-weekly 4` in about five weeks. (This is a reading of the backup script, not
something that was run.)

1. **[pc] Stop the nightly job first,** so nothing mirrors `data` over the restore:
   ```bash
   systemctl --user disable --now lgtm-backup.timer lgtm-restic-check.timer
   systemctl --user stop lgtm-backup.service lgtm-restic-check.service
   systemctl --user is-active lgtm-backup.service lgtm-restic-check.service    # expect inactive, inactive
   ```
2. **[pc] Stop the stack** (its data is kept):
   ```bash
   docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml down
   ```
3. **[pc] Restore to a scratch directory, never onto `/srv/lgtm`.** Choose a snapshot from
   **before** the damage: `latest` may have been taken after it. The `restic snapshots` list shows
   the times; use its id in place of `latest`.
   ```bash
   sudo install -d -o "$USER" -g "$USER" /srv/lgtm-restore
   ( set -a; . ~/.config/lgtm/backup.env; set +a
     export RESTIC_PASSWORD_FILE="$HOME/.config/lgtm/restic.pass"
     restic snapshots --tag lgtm
     restic restore latest --target /srv/lgtm-restore )      # or an id from the list instead of "latest"
   ls /srv/lgtm-restore/srv/lgtm/staging                        # expect grafana loki prometheus tempo
   ```
4. **[pc] Move the damaged data aside (do not delete it yet), then copy the restored copy in:**
   ```bash
   if [ -e /srv/lgtm/data ]; then mv /srv/lgtm/data "/srv/lgtm/data.damaged-$(date +%F)"; fi
   rsync -a /srv/lgtm-restore/srv/lgtm/staging/ /srv/lgtm/data/
   ```
5. **[pc] Start and verify** as Phase 1 steps 5 and 7: `up -d`, the four readiness URLs, then the Mac check
   for `Admin` and the three datasources. Query a time range you know has data. **If it does not
   verify:** `docker compose ... down`, `mv /srv/lgtm/data /srv/lgtm/data.bad-restore`, move the
   `data.damaged-*` directory back to `/srv/lgtm/data`, and stop to work out why.
6. **[pc] Only now re-enable the timers:**
   ```bash
   systemctl --user enable --now lgtm-backup.timer lgtm-restic-check.timer
   ```
7. **Clean up later, after you are sure** (each is a delete: confirm first): `/srv/lgtm-restore` and
   `/srv/lgtm/data.damaged-*`.

Without taylor-pc, the same restore works from the Mac with Drill B's commands: restore to a
scratch directory, then copy `<target>/srv/lgtm/staging/` into `data/` on the new host.

## Secrets: where each one lives

| Secret | Created in | Lives in | Never in |
|---|---|---|---|
| Grafana break-glass password | Phase 1 step 3 | `~/.config/lgtm/lgtm.env` on taylor-pc, mode 0600 | Git, a transcript |
| Gatus backup token | Phase 2 step 1 | taylor-pc `backup.env` (0600) and sentinel `gatus.env` (0600); vault later | Git, a URL, a log |
| restic repository password | Phase 4 step 3 | taylor-pc `restic.pass` (0600) **and** the Bitwarden item | Git, a transcript |
| rsync.net key for the backup | Phase 4 step 1 | `~/.ssh/id_ed25519_rsyncnet` on taylor-pc | Git |
| ntfy topic | PR #1 | sentinel `gatus.env` (Phase 5 will add it to `lgtm.env`) | Git |

## ISA criteria

`ISA.md` is not in `origin/main`, so these rows are shipped here to paste into its Test
Strategy and Features. Numbering continues from PR #1's ISC-15. Rows marked live stay `[ ]`
until the check is recorded with a date.

| isc | type | check | threshold | tool | anchors_to |
|---|---|---|---|---|---|
| ISC-16 | static | Stack images are pinned by tag and digest, every port is loopback-only, retention is 30 days, no admin API | contract test passes | `bun scripts/test-lgtm-contract.ts` | Constraints |
| ISC-16.1 | static | Every config parses under the pinned component binaries | 0 failed, 0 skipped | `scripts/validate-lgtm.sh` | Constraints |
| ISC-16.2 | static | The new files commit no tailnet address, tailnet name, email, key fingerprint, home path, secret or ntfy topic. `configs/sentinel/gatus/config.yaml` is outside this scan: it already carried the tailnet name, and this PR adds URLs naming taylor-pc on it | contract test passes | contract test | Constraints |
| ISC-17 | live | The four containers run as uid 1000 and report ready | Loki, Prometheus, Tempo `/ready` 200; Grafana `/api/health` database ok; no permission errors | Phase 1 steps 5 and 7 | Vision |
| ISC-17.1 | live | Only the five Serve doors were added and the existing `:443` route is untouched | `tailscale serve status` lists them | `serve.sh status` | Constraints |
| ISC-17.2 | live | Retention is 30 days as loaded, and Loki's delete API is off | Prometheus `30d`; Loki `retention_enabled: true`, 30 day period, `deletion_mode: disabled`; Tempo 30 days | Phase 1 step 8 | Constraints |
| ISC-18 | live | Your Tailscale login is Org Admin and datasources are provisioned | role `Admin`; three datasources | Phase 1 step 7 | Vision |
| ISC-18.1 | live | Devices that need nothing from the stack cannot reach any door | console `tests` pass | `docs/lgtm-tailnet-acl.md` | Constraints |
| ISC-19 | live | Every reporting node's metrics and logs arrive | one `up{job="integrations/unix"}` series per node; one journal line count per Linux node | Phase 3 verify | Vision |
| ISC-20 | live | A stack outage pages and resolves | notification and resolved notice, timestamps recorded | Phase 2 step 4 | Vision |
| ISC-21 | live | The nightly backup completes with a short pause | `writers down` under 90 s; ready again under 180 s | Phase 4 step 7 | Vision |
| ISC-22 | live | A restore yields queryable data, and works without taylor-pc | Drill A passes; Drill B passes | Phase 4 | Vision |
| ISC-23 | static | Each job reports only to its own Gatus endpoint, so a good backup can never clear a failed integrity check and the check can never stand in for a backup | contract and behavior tests pass | `scripts/test-lgtm-backup.ts` | Constraints |
| ISC-24 | live | A missed backup pages | heartbeat red 26 to 52 h after the last success push | Phase 4 steps 9 and 11 | Vision |
| ISC-24.1 | live | The dead-man fires once, and sentinel's Gatus supports `heartbeat` | alert and resolved notice during the two-minute fire test, timestamps recorded | Phase 4 step 9 | Vision |
| ISC-25 | static | Loki's delete API is off | `deletion_mode: disabled` in `loki.yaml`, enforced by the contract test | contract test | Constraints |
| ISC-26 | live | The tailnet ACL is applied before Phase 3 | the Phase 3-0 check prints `200`, `200`, `000` | Phase 3-0 | Constraints |
| ISC-27 | live | A real restore works without losing the good snapshots | stack up on restored data; timers re-enabled only afterwards | Real restore | Vision |

## Not in this PR

- Phase 5: Grafana-managed alert rules and a ntfy contact point.
- An Ansible `alloy` role. The OCI nodes follow this repo's manual `scp` + `sudo install`
  convention; a role can wrap steps 3b later.
- The tailnet ACL itself (a template only), and retiring the copied rsync.net key from
  taylor-pc (Decision 8, a separate task).
- Optional traces from OpenClaw or Hermes.

## Known limits

- **Wi-Fi only, home uplink.** An ISP outage pages `taylor-pc-reachable`; that is correct.
- **Shared fate.** taylor-pc also holds this repo, the vault and the only key into the OCI
  hosts. Sentinel's ICMP check is the outside witness.
- **Serve routes can vanish** after a tailscaled restart (it happened to openclaw's `:443`).
  The Gatus checks go through the doors on purpose, so a lost route pages.
- **Ingest is unauthenticated.** The ACL is the control, not the stack. Every reporting node can
  read every host's logs and metrics through its door, and **can also restart Loki**: the re-review's
  one unauthenticated `POST /ingester/shutdown` stopped a bare Loki 3.7.10 (Docker's
  `restart: unless-stopped` should bring it back; not run in the container), and Gatus would page
  after five minutes. That is accepted here, pending the captain's confirmation, on a one-person
  tailnet. Loki's delete API is off, so a compromised reporter cannot erase logs.
- **Docker publishes past firewalld**, which is why nothing binds `0.0.0.0`.
