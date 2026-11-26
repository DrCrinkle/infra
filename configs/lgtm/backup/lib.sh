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

# gatus_push ENDPOINT true|false MESSAGE: report to one external endpoint on
# sentinel's Gatus; ENDPOINT is its key, <group>_<name> (lgtm_lgtm-backup,
# lgtm_lgtm-restic-check). The token goes in a header, never in a URL or a log line.
# A failed push must not fail the job, but it must be visible: the dead-man
# heartbeat only pages 26 to 52 hours later (the check's, 8 to 16 days), so say so
# on stderr (journald) right now.
gatus_push() {
  local endpoint=$1 success=$2 message=${3:-}
  curl -fsS -m 20 -X POST -G \
    -H "Authorization: Bearer ${GATUS_LGTM_BACKUP_TOKEN}" \
    --data-urlencode "success=${success}" \
    --data-urlencode "error=${message}" \
    "${GATUS_URL}/api/v1/endpoints/${endpoint}/external" >/dev/null ||
    echo "lgtm: WARNING: Gatus heartbeat push to ${endpoint} (success=${success}) failed; check GATUS_URL and the token" >&2
}

# Each job reports only to its own endpoint, so a green push always means that job
# completed: a good backup can never clear a failed integrity check, and a good check
# can never stand in for a backup.
gatus_ok() { gatus_push "$1" true ""; }
gatus_fail() { gatus_push "$1" false "$2"; }
