#!/usr/bin/env bash
# configs/lgtm/backup/rsyncnet-own-key.sh: give taylor-pc its own rsync.net key
# for the LGTM backup, and the ssh alias restic uses.
#
# Additive only. It appends ONE public key to rsync.net's authorized_keys with
# the dd/oflag=append form rsync.net documents (their scp example OVERWRITES the
# file), removes nothing, and refuses to run twice. The existing key is used only
# to authorize the new one; the sshfs mount, GitSync and rclone keep using it.
#
# Run as the deploy user on taylor-pc, no sudo. The rsync.net account is read
# from /etc/fstab (the sshfs line), so no account id or hostname lives in this
# public repo. Prints fingerprints only, never key material.
set -euo pipefail

key="${HOME}/.ssh/id_ed25519_rsyncnet"
old="${HOME}/.ssh/id_ed25519" # the key the sshfs mount already authenticates with
alias_name="rsyncnet-lgtm"
ssh_config="${HOME}/.ssh/config"
backup_dir="${HOME}/.config/lgtm"

if [[ -e "$key" || -e "$key.pub" ]]; then
  echo "refusing: $key already exists; not overwriting" >&2
  exit 1
fi
if [[ ! -r "$old" ]]; then
  echo "refusing: no readable existing key at $old" >&2
  exit 1
fi

acct="$(awk '$3 == "fuse.sshfs" && $1 ~ /rsync\.net:/ { split($1, a, ":"); print a[1]; exit }' /etc/fstab)"
if [[ -z "$acct" || "$acct" != *@* ]]; then
  echo "refusing: no user@host rsync.net sshfs line in /etc/fstab" >&2
  exit 1
fi

rs_ssh() { ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -i "$1" "$acct" "${@:2}"; }
fingerprints() { ssh-keygen -lf - | awk '{ print "  " $2 " " $NF }'; }

install -d -m 700 "$backup_dir"
snapshot="$backup_dir/rsyncnet-authorized_keys.$(date +%Y%m%d-%H%M%S)"
(
  umask 077
  rs_ssh "$old" cat .ssh/authorized_keys >"$snapshot"
)
before="$(ssh-keygen -lf "$snapshot" | wc -l | tr -d ' ')"
echo "rsync.net authorized_keys: $before keys before; local copy: $snapshot"

# A last line without a trailing newline would swallow the appended key.
needs_newline=0
if [[ "$(tail -c1 "$snapshot" | od -An -c | tr -d ' ')" != '\n' ]]; then needs_newline=1; fi

ssh-keygen -q -t ed25519 -N "" -C "lgtm-backup-taylor-pc" -f "$key"

{
  if ((needs_newline)); then printf '\n'; fi
  cat "$key.pub"
} | ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$old" "$acct" \
  'dd of=.ssh/authorized_keys oflag=append conv=notrunc'

# Prove the NEW key logs in on its own, and that the file grew by exactly one.
after_list="$(rs_ssh "$key" cat .ssh/authorized_keys | fingerprints)"
after="$(printf '%s\n' "$after_list" | wc -l | tr -d ' ')"
echo "$after_list"
if ((after != before + 1)); then
  echo "UNEXPECTED: authorized_keys went from $before to $after keys." >&2
  echo "Restore: ssh -i $old $acct 'dd of=.ssh/authorized_keys' < $snapshot" >&2
  exit 1
fi

# The restic repository address uses this alias, so no account id is committed.
if [[ ! -e "$ssh_config" ]]; then
  install -m 600 /dev/null "$ssh_config"
fi
if ! grep -q "^Host ${alias_name}\$" "$ssh_config"; then
  lead=""
  if [[ -s "$ssh_config" && -n "$(tail -c1 "$ssh_config")" ]]; then lead=$'\n'; fi
  printf '%s\nHost %s\n  HostName %s\n  User %s\n  IdentityFile ~/.ssh/id_ed25519_rsyncnet\n  IdentitiesOnly yes\n' \
    "$lead" "$alias_name" "${acct#*@}" "${acct%@*}" >>"$ssh_config"
fi
ssh -n -o BatchMode=yes "$alias_name" ls >/dev/null

echo "ok: new key $(ssh-keygen -lf "$key.pub" | awk '{print $2}') authorized; $after keys total; alias $alias_name works"
