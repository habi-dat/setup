#!/usr/bin/env bash
set -euo pipefail

# Connects to the backup repository once this server's key is allowed there,
# then either
#   - initialises a new repository (repokey-blake2) and shows the passphrase and
#     key once, for offline storage, or
#   - takes over an existing one (a new server for a restore), asking for its
#     passphrase and warning when the old server may still be writing to it,
# and finally installs the nightly snapshot and watch timers.
#
# Unattended: HABIDAT_BACKUP_PASSPHRASE supplies the passphrase of an existing
# repository, and --yes confirms the host key, the takeover and that the new
# passphrase was stored.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh

YES=false
[[ "${1:-}" == "--yes" ]] && YES=true

backup_load_config
IFS=" " read -r _ repo_host repo_port _ <<< "$(backup_repo_parts "$HABIDAT_BACKUP_REPOSITORY")"

has_tty() {
  [[ -r /dev/tty ]] && { true > /dev/tty; } 2>/dev/null
}

confirm() {
  [[ "$YES" == true ]] && return 0
  has_tty || die "$1 Run again with --yes to confirm without a terminal."
  local reply
  read -r -p "$1 [y/N] " reply < /dev/tty
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- the repository host's key -------------------------------------------------
known_hosts="$BACKUP_STORE/ssh/known_hosts"
if [[ ! -s "$known_hosts" ]]; then
  log_info "Fetching the host key of $repo_host:$repo_port..."
  scanned="$(docker run --rm "$HABIDAT_BORG_IMAGE" ssh-keyscan -p "$repo_port" "$repo_host" 2>/dev/null)" \
    || die "Could not reach $repo_host:$repo_port."
  [[ -n "$scanned" ]] || die "$repo_host:$repo_port did not offer a host key."
  printf '%s\n' "$scanned" | docker run --rm -i "$HABIDAT_BORG_IMAGE" ssh-keygen -lf - | log_module backup
  confirm "Do these fingerprints belong to $repo_host?" || die "Host key not accepted."
  (umask 077 && printf '%s\n' "$scanned" > "$known_hosts")
fi

# --- what is there -------------------------------------------------------------
log_info "Connecting to $HABIDAT_BACKUP_REPOSITORY..."
probe_args=()
[[ -f "$BACKUP_STORE/passphrase" ]] || probe_args=(-e "BORG_PASSPHRASE=habidat-probe")
probe_rc=0
probe="$(backup_borg "${probe_args[@]+"${probe_args[@]}"}" -- borg info 2>&1)" || probe_rc=$?

if [[ $probe_rc -eq 0 ]]; then
  log_info "The repository is already set up for this server."

elif grep -q 'does not exist' <<< "$probe"; then
  log_info "Creating a new repository (repokey-blake2)..."
  (umask 077 && openssl rand -base64 36 | tr -d '\n' > "$BACKUP_STORE/passphrase")
  if ! backup_borg -- borg init --encryption=repokey-blake2; then
    rm -f "$BACKUP_STORE/passphrase"
    die "Could not create the repository."
  fi
  key="$(backup_borg -- borg key export)"
  cat <<EOF

============================================================================
Store the passphrase AND the key below offline now (e.g. in a password
manager that is not on this server). A restore on a new server needs both;
they are not shown again. Whoever has both can read every snapshot,
including every password in store/.

Passphrase: $(cat "$BACKUP_STORE/passphrase")

$key
============================================================================

EOF
  confirm "Have you stored the passphrase and the key?" \
    || log_warn "Copy them from store/backup/passphrase and 'borg key export' before this server is lost."

elif grep -q 'passphrase supplied' <<< "$probe" || grep -q 'is incorrect' <<< "$probe"; then
  log_warn "The repository exists already: this server takes it over."
  passphrase="${HABIDAT_BACKUP_PASSPHRASE:-}"
  if [[ -z "$passphrase" ]]; then
    has_tty || die "Set HABIDAT_BACKUP_PASSPHRASE to the repository's passphrase."
    read -r -s -p "Passphrase of the repository: " passphrase < /dev/tty
    echo > /dev/tty
  fi
  (umask 077 && printf '%s' "$passphrase" > "$BACKUP_STORE/passphrase")
  if ! newest="$(backup_borg -- borg list --last 1 --format '{archive}{TAB}{start:%Y-%m-%d %H:%M:%S}{NL}')"; then
    rm -f "$BACKUP_STORE/passphrase"
    die "The passphrase does not open the repository."
  fi
  if [[ -n "$newest" ]]; then
    IFS=$'\t' read -r newest_name newest_time <<< "$newest"
    log_info "Newest snapshot: $newest_name ($newest_time)."
    age=$(( $(date +%s) - $(date -d "$newest_time" +%s) ))
    if (( age < BACKUP_TAKEOVER_HOURS * 3600 )); then
      log_warn "That is less than ${BACKUP_TAKEOVER_HOURS} hours ago: the old server may still be writing to this repository."
      log_warn "Shut it down, or run './habidat.sh stop backup' there, before going on."
    fi
  fi
  if ! confirm "Take over this repository? From now on this server writes its snapshots there."; then
    rm -f "$BACKUP_STORE/passphrase"
    die "Takeover cancelled."
  fi

else
  printf '%s\n' "$probe" | log_module backup
  if grep -q 'Permission denied' <<< "$probe"; then
    die "The repository host refused this server's key. Add it as shown by ./habidat.sh install backup, then retry."
  fi
  die "Could not connect to the repository (see above)."
fi

# --- timers --------------------------------------------------------------------
backup_install_timers "$(get_installed_version backup)"
backup_state_set configured "$(date +%s)"
log_info "Backup is configured. Take a first snapshot now with: ./habidat.sh backup"
