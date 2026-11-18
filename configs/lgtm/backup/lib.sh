# shellcheck shell=bash
# configs/lgtm/backup/lib.sh: helpers shared by the backup and restic-check jobs.
# Sourced, never executed.

# take_lock: one restic job at a time. `restic forget --prune` and `restic check`
# both want the repository exclusively, and a Persistent= timer can fire both
# after a night off. Waits up to an hour for the other job to finish.
take_lock() {
  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/lgtm-restic.lock"
  flock -w 3600 9 || {
    echo "lgtm: another restic job still holds the lock after 1h" >&2
    return 75
  }
}

# gatus_push true|false MESSAGE: report to the lgtm-backup external endpoint on
# sentinel's Gatus. The token goes in a header, never in a URL or a log line.
# A failed push must not fail the backup, but it must be visible: the dead-man
# heartbeat only pages 26h later, so say so on stderr (journald) right now.
gatus_push() {
  local success=$1 message=${2:-}
  curl -fsS -m 20 -X POST -G \
    -H "Authorization: Bearer ${GATUS_LGTM_BACKUP_TOKEN}" \
    --data-urlencode "success=${success}" \
    --data-urlencode "error=${message}" \
    "${GATUS_URL}/api/v1/endpoints/lgtm_lgtm-backup/external" >/dev/null ||
    echo "lgtm: WARNING: Gatus heartbeat push (success=${success}) failed; check GATUS_URL and the token" >&2
}

# Only the backup job may report success: a green push resets the 26h dead-man,
# so it has to mean "a backup completed". Any job may report failure.
gatus_ok() { gatus_push true ""; }
gatus_fail() { gatus_push false "$1"; }
