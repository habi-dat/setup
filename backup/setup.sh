#!/usr/bin/env bash
set -euo pipefail

# Writes store/backup/ (repository, protection mode, alert address), builds the
# borg image and creates this server's own SSH key. Works without setup.env, so
# a fresh server can set up backup before restoring (ADR 0006).
#
# The key has to be allowed on the repository host by an admin, by hand, before
# `./habidat.sh configure backup` can initialise or take over the repository
# (ADR 0008): a habidat server never holds an admin login to the backup storage.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh

usage() {
  cat >&2 <<'EOF'
./habidat.sh install backup <repository> <protection> [alert-email]

  repository   ssh://<user>@<host>[:<port>]/<path>, one per installation, e.g.
               ssh://u123456-sub1@u123456.your-storagebox.de:23/./habidat
  protection   provider-snapshots  Hetzner Storage Box sub-account; the box's
                                   automatic snapshots undo an attack
               append-only         own SSH server; the key is locked to
                                   `borg serve --append-only`
  alert-email  where failures are mailed (default: HABIDAT_ADMIN_EMAIL)
EOF
  exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage
REPOSITORY="$1"
PROTECTION="$2"
ALERT_EMAIL="${3:-${HABIDAT_ADMIN_EMAIL:-}}"

parts="$(backup_repo_parts "$REPOSITORY")" || {
  echo "The repository must look like ssh://user@host[:port]/path, not '$REPOSITORY'." >&2
  usage
}
case "$PROTECTION" in
  provider-snapshots | append-only) ;;
  *) echo "Unknown protection '$PROTECTION'." >&2; usage ;;
esac
if [[ -n "$ALERT_EMAIL" && "$ALERT_EMAIL" != *@* ]]; then
  echo "'$ALERT_EMAIL' is not an email address." >&2
  usage
fi
IFS=" " read -r repo_user repo_host repo_port repo_path <<< "$parts"

mkdir -p "$BASE_DIR/store"
umask 077
mkdir -p "$BACKUP_STORE/ssh" "$BACKUP_STORE/state" "$BACKUP_STORE/cache"
chmod 700 "$BACKUP_STORE"
{
  printf 'HABIDAT_BACKUP_REPOSITORY=%q\n' "$REPOSITORY"
  printf 'HABIDAT_BACKUP_PROTECTION=%q\n' "$PROTECTION"
  printf 'HABIDAT_BACKUP_ALERT_EMAIL=%q\n' "$ALERT_EMAIL"
} > "$BACKUP_STORE/backup.env"

backup_build_image

if [[ ! -f "$BACKUP_STORE/ssh/id_ed25519" ]]; then
  echo "Creating this server's SSH key..."
  docker run --rm -v "$BACKUP_STORE/ssh:/ssh" "$HABIDAT_BORG_IMAGE" \
    ssh-keygen -q -t ed25519 -N '' -C "habidat-backup@$(hostname)" -f /ssh/id_ed25519
fi
pubkey="$(cat "$BACKUP_STORE/ssh/id_ed25519.pub")"

echo
echo "Backup repository: $REPOSITORY ($PROTECTION)"
echo "Alerts go to:      ${ALERT_EMAIL:-nobody (set an alert email to get them)}"
echo
if [[ "$PROTECTION" == provider-snapshots ]]; then
  cat <<EOF
Allow this server on the Storage Box, from your own machine (not from this server):

  1. In the Hetzner Console, create a sub-account with SSH access for this
     installation only (${repo_user}), and turn on the box's automatic
     snapshots, keeping as many as the plan allows.
  2. Install this server's key for the sub-account:

     echo '$pubkey' | ssh -p ${repo_port} ${repo_user}@${repo_host} install-ssh-key

  3. Run: ./habidat.sh configure backup
EOF
else
  restrict_path="${repo_path#/./}"
  cat <<EOF
Allow this server on ${repo_host}: add this line to ~${repo_user}/.ssh/authorized_keys
(borg there must be 1.4):

  command="borg serve --append-only --restrict-to-repository ${restrict_path}",restrict $pubkey

Then run: ./habidat.sh configure backup

Snapshots this server prunes are only marked as deleted. Free the space now and
then from a trusted machine with \`borg compact\`, after checking the repository.
EOF
fi
