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

1. **PR #1 first:** https://github.com/DrCrinkle/infra/pull/1 (second SSH key, Gatus ntfy
   alerting, gateway route). Phase 2 needs it merged **and applied**: sentinel has no
   alerting until then, and this PR's Gatus checks assume its `alerting.ntfy` block.
   Phases 1 and 3 do not depend on it. Phase 4 uses the `backup.env` that Phase 2 step 1
   writes, so in practice it follows Phase 2.
2. **Tailnet ACL before Phase 3:** `docs/lgtm-tailnet-acl.md`, in the admin console.
3. Phases run in order 1, 2, 3, 4. Phase 5 (Grafana alert rules) is not part of this PR.

## What was and was not validated

Run on the Mac with release binaries at the pinned versions, checksum-verified, nothing
installed and nothing started: `scripts/validate-lgtm.sh`.

| Check | Result |
|---|---|
| `docker compose config` (compose v5.7.1, no daemon), including the drill override merged | passes; merged drill config keeps no live mount, no live port |
| `promtool check config` 3.16.0, `loki -verify-config` 3.7.10, `tempo -config.verify` 3.1.1 | pass; each rejects a deliberately misspelled retention key |
| `alloy fmt --test` and `alloy validate`, 1.21.3 and 1.22.0, all three configs | pass |
| `shellcheck -S style`, contract test, stubbed backup behavior test | pass; both tests catch every mutation tried |
| `macos.alloy` run for 20 s against a loopback sink | read the host file, pushed to `:9090/api/v1/write` and `:3100/loki/api/v1/push`, no errors |

**Not proven, and measured in the phases below:** containers start, run as UID 1000 on
the bind mounts, and apply retention; `serve.sh` against a real tailscaled; Grafana
`auth.proxy` login and the Admin role; `loki.source.journal` and the Docker log source on
Linux; restic over SFTP to rsync.net; the real pause length; Gatus accepting the push.
`alloy validate` also does not evaluate component arguments, so the URL building was
checked by actually running Alloy, not by validate.

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
6. **[pc] Serve doors** (asks for your sudo password):
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
   ssh pc 'curl -fsS http://127.0.0.1:9090/api/v1/status/runtimeinfo | jq -r .data.storageRetention; curl -fsS http://127.0.0.1:3100/config | grep -m1 retention_period; curl -fsS http://127.0.0.1:3200/status/config | grep -m1 block_retention'
   ```
   Expect `30d`, `retention_period: 720h` and `block_retention: 720h`. If an endpoint is
   missing in these versions, read the loaded config from the container logs instead.

**Rollback 1:** `docker compose -f ~/deploy/infra/configs/lgtm/compose.yaml down` (data is
kept) and `~/deploy/infra/configs/lgtm/serve.sh off`. Erasing `/srv/lgtm` is a separate,
explicit decision.

## Phase 2: paging (needs PR #1 applied)

This phase installs the last commit of this PR: sentinel's Gatus config with the stack
checks. Check that PR #1 is merged and applied (`ssh opc@sentinel 'grep -c ntfy /etc/gatus/config.yaml'`
is non-zero) before you start.

| Check | Pages when |
|---|---|
| `taylor-pc-reachable` (ICMP) | taylor-pc off, asleep, off the tailnet, home uplink down, or a reboot over 5 min |
| `lgtm-grafana` (`:8443/api/health`) | Grafana or its Serve route down for 5 min |
| `lgtm-loki-ready` (`:3100/ready`) | Loki or its forwarder down for 5 min |
| `lgtm-prometheus-ready` (`:9090/-/ready`) | Prometheus or its forwarder down for 5 min |
| `lgtm-backup` (heartbeat, **disabled** until Phase 4) | no backup success for 26 h, or a push with `success=false` |

The three service checks use `failure-threshold: 5` so the nightly backup pause never
pages. The backup alert uses `failure-threshold: 1` and `success-threshold: 1`: with one
push a night, PR #1's defaults (3 failures, 2 successes) would take three missed days to
page and two good nights to resolve.

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
2. **[pc] Install the config** (Phase 0's manual procedure). It replaces sentinel's file
   wholesale, so the checkout must contain PR #1 or its alerting is removed: after both PRs are
   merged, `git -C ~/deploy/infra checkout main && git -C ~/deploy/infra pull --ff-only`. The
   guard stops the copy otherwise:
   ```bash
   grep -q '^alerting:' ~/deploy/infra/configs/sentinel/gatus/config.yaml || { echo "this checkout lacks PR #1: stop"; exit 1; }
   scp ~/deploy/infra/configs/sentinel/gatus/config.yaml opc@sentinel:/tmp/
   ssh opc@sentinel 'sudo install -m0644 /tmp/config.yaml /etc/gatus/config.yaml && sudo systemctl restart gatus && systemctl is-active gatus'
   ```
3. **[!] Verify** (all four probe checks green; the heartbeat is disabled, so absent):
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

## Before Phase 3: tighten the tailnet ACL

Do `docs/lgtm-tailnet-acl.md` in the admin console now. Until it is applied, every device
on your Tailscale login can push to, read from and be Org Admin on the stack.

## Phase 3: Alloy on every node

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
   While `lgtm-backup` is still `enabled: false` in Gatus, the final heartbeat push may be
   refused; a `WARNING: Gatus heartbeat push` line in this journal is expected until step 10 and
   does not fail the backup.
   **Pass:** `writers down` under 90 s, and the watcher's gap under 180 s (inside the
   5 × 60 s Gatus threshold). If the gap is over about 3 minutes, **do not enable the
   timer**: raise the threshold or change the design first. Check the check that does not
   depend on the clock: `restic snapshots` shows one `lgtm` snapshot.
8. **[pc] Drill A: prove a restore works.** Run it **the day after the first backup**: the
   queries look at data at least 24 hours older than the snapshot, so data must be that old.
   ```bash
   sudo install -d -o "$USER" -g "$USER" /srv/lgtm-drill
   ( set -a; . ~/.config/lgtm/backup.env; set +a
     export RESTIC_PASSWORD_FILE="$HOME/.config/lgtm/restic.pass"
     restic restore latest --target /srv/lgtm-drill )
   cd ~/deploy/infra/configs/lgtm && docker compose -p lgtm-drill -f compose.yaml -f drill/compose.drill.yaml up -d
   T=$(date -u -d '-26 hours' +%Y-%m-%dT%H:%M:%SZ)
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
9. **[pc] Enable the timers:**
   ```bash
   systemctl --user enable --now lgtm-backup.timer lgtm-restic-check.timer
   systemctl --user list-timers 'lgtm-*'
   ```
10. **Flip the Gatus heartbeat to enabled.** In `configs/sentinel/gatus/config.yaml` change
    `enabled: false` to `enabled: true` on `lgtm-backup` (a one-line follow-up change),
    then reinstall the config as in Phase 2 step 2. Within 26 h of the first scheduled
    success push the check is green; a missed night pages.

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
| ISC-16.2 | static | No tailnet address, tailnet name, email, key fingerprint, home path, secret or ntfy topic is committed | contract test passes | contract test | Constraints |
| ISC-17 | live | The four containers run as uid 1000 and report ready | Loki, Prometheus, Tempo `/ready` 200; Grafana `/api/health` database ok; no permission errors | Phase 1 steps 5 and 7 | Vision |
| ISC-17.1 | live | Only the five Serve doors were added and the existing `:443` route is untouched | `tailscale serve status` lists them | `serve.sh status` | Constraints |
| ISC-17.2 | live | Retention is 30 days as loaded | `30d`, `720h`, `720h` | Phase 1 step 8 | Constraints |
| ISC-18 | live | Your Tailscale login is Org Admin and datasources are provisioned | role `Admin`; three datasources | Phase 1 step 7 | Vision |
| ISC-18.1 | live | Devices that need nothing from the stack cannot reach any door | console `tests` pass | `docs/lgtm-tailnet-acl.md` | Constraints |
| ISC-19 | live | Every reporting node's metrics and logs arrive | one `up{job="integrations/unix"}` series per node; one journal line count per Linux node | Phase 3 verify | Vision |
| ISC-20 | live | A stack outage pages and resolves | notification and resolved notice, timestamps recorded | Phase 2 step 4 | Vision |
| ISC-21 | live | The nightly backup completes with a short pause | `writers down` under 90 s; ready again under 180 s | Phase 4 step 7 | Vision |
| ISC-22 | live | A restore yields queryable data, and works without taylor-pc | Drill A passes; Drill B passes | Phase 4 | Vision |
| ISC-23 | static | The integrity check can never report a backup as successful | contract and behavior tests pass | `scripts/test-lgtm-backup.ts` | Constraints |
| ISC-24 | live | A missed backup pages | heartbeat red after 26 h without a success push | Phase 4 step 10 | Vision |

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
- **Ingest is unauthenticated.** The ACL is the control, not the stack.
- **Docker publishes past firewalld**, which is why nothing binds `0.0.0.0`.
