#!/usr/bin/env bash
# configs/lgtm/backup/lgtm-backup.sh: nightly backup of the LGTM stack to rsync.net.
#
# Runs as the deploy user from a systemd --user timer (configs/lgtm/systemd/).
# The root filesystem is ext4 with no snapshots, so consistency comes from
# stopping the writers: stop, copy to a local staging dir on the same NVMe
# (seconds), start again, then upload the quiet copy with restic while ingest
# is already flowing. Target: writers down under 90s. Alloy buffers meanwhile
# (remote-write WAL, loki.write retries).
#
# Environment (from backup.env via the unit; see backup.env.example):
#   RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, GATUS_URL, GATUS_LGTM_BACKUP_TOKEN
# Optional overrides: LGTM_COMPOSE_DIR, LGTM_DATA_DIR, LGTM_STAGING_DIR,
#   LGTM_MAX_DOWN_SECONDS.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

compose_dir="${LGTM_COMPOSE_DIR:-$(cd "$here/.." && pwd)}"
data="${LGTM_DATA_DIR:-/srv/lgtm/data}"
staging="${LGTM_STAGING_DIR:-/srv/lgtm/staging}"
max_down="${LGTM_MAX_DOWN_SECONDS:-90}"
writers=(grafana loki tempo prometheus)
writers_stopped=0
endpoint=lgtm_lgtm-backup # Gatus external endpoint, <group>_<name>

: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}" "${GATUS_URL:?}" "${GATUS_LGTM_BACKUP_TOKEN:?}"

compose() { docker compose --project-directory "$compose_dir" "$@"; }

restart_writers() {
  ((writers_stopped)) || return 0
  compose start "${writers[@]}"
  writers_stopped=0
}

# Whatever happens below, never leave the stack stopped, and tell Gatus on failure.
on_exit() {
  local rc=$?
  trap - EXIT
  if ! restart_writers; then
    echo "lgtm: ERROR: could not restart the writers; the stack may be down" >&2
    ((rc != 0)) || rc=1
  fi
  if ((rc != 0)); then gatus_fail "$endpoint" "lgtm-backup failed (exit $rc)"; fi
  exit "$rc"
}
trap on_exit EXIT

take_lock

[[ -d "$data" && -n "$staging" && "$staging" != "$data" ]] || {
  echo "lgtm: refusing: bad data/staging paths ($data, $staging)" >&2
  exit 1
}
mkdir -p "$staging"

# Preflight BEFORE any downtime: a repository that is missing, unreachable or
# unlockable must not cost the stack a pause.
restic cat config >/dev/null

t0=$SECONDS
writers_stopped=1 # set first: a half-finished stop must still be restarted
compose stop "${writers[@]}"
rsync -a --delete -- "$data/" "$staging/"
restart_writers
down=$((SECONDS - t0))
echo "lgtm: writers down for ${down}s"
if ((down > max_down)); then
  echo "lgtm: WARNING: pause ${down}s exceeds the ${max_down}s target" >&2
fi

restic backup "$staging" --tag lgtm --host taylor-pc
restic forget --tag lgtm --host taylor-pc --keep-daily 7 --keep-weekly 4 --prune
gatus_ok "$endpoint"
