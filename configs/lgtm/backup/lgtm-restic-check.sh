#!/usr/bin/env bash
# configs/lgtm/backup/lgtm-restic-check.sh: weekly integrity check of the restic repo.
#
# Reads a random 5% of the pack data. It reports FAILURE to the lgtm-backup
# Gatus heartbeat and nothing else: a green push would reset the 26h dead-man
# without a backup having run, so only lgtm-backup.sh may report success.
#
# Environment: same as lgtm-backup.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}" "${GATUS_URL:?}" "${GATUS_LGTM_BACKUP_TOKEN:?}"

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)); then gatus_fail "restic check failed (exit $rc)"; fi
  exit "$rc"
}
trap on_exit EXIT

take_lock
restic check --read-data-subset=5%
