#!/usr/bin/env bash
# configs/lgtm/backup/lgtm-restic-check.sh: weekly integrity check of the restic repo.
#
# Reads a random 5% of the pack data. It reports to its OWN Gatus endpoint,
# lgtm-restic-check (success after a clean check, failure otherwise), never to the
# backup's: sharing one endpoint let Monday's good backup clear Sunday's failed check,
# and a check that stopped running was invisible. The endpoint's 8 day heartbeat
# pages if the weekly check stops running.
#
# Environment: same as lgtm-backup.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

endpoint=lgtm_lgtm-restic-check # Gatus external endpoint, <group>_<name>

: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}" "${GATUS_URL:?}" "${GATUS_LGTM_BACKUP_TOKEN:?}"

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)); then gatus_fail "$endpoint" "restic check failed (exit $rc)"; fi
  exit "$rc"
}
trap on_exit EXIT

take_lock
restic check --read-data-subset=5%
gatus_ok "$endpoint"
