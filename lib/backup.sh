#!/usr/bin/env bash
# Snapshots in the backup repository (ADR 0005-0008), and the backup,
# snapshots, export, restore and import commands.
# Sourced by habidat.sh and by module scripts -- do not execute directly.
#
# store/backup/ (never part of a snapshot, never restored):
#   backup.env        repository URL, protection mode, alert address
#   passphrase        repokey-blake2 passphrase (shown once at configure)
#   ssh/              this server's own key and the repository host's key
#   cache/            borg's cache and security folder
#   state/            last success, snapshot count, last alert
#   staging/          dumps of the current run, removed afterwards

BACKUP_STORE="$BASE_DIR/store/backup"

# join_words <word>...
#   "${arr[*]}" joins with the first character of IFS, which common.sh sets to
#   a newline.
join_words() {
  local IFS=' '
  printf '%s' "$*"
}
# Built by the backup module from backup/borg/Dockerfile.
HABIDAT_BORG_IMAGE="${HABIDAT_BORG_IMAGE:-habidat-borg:1.4}"

BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=6
# Alert when the newest successful snapshot is older than this.
BACKUP_STALE_HOURS=36
# Alert when the repository holds this many snapshots fewer than after the
# previous run. A nightly prune removes at most two.
BACKUP_COUNT_DROP=3
# Warn on takeover when the newest snapshot is younger than this.
# shellcheck disable=SC2034  # read by backup/configure.sh
BACKUP_TAKEOVER_HOURS=24

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

backup_is_installed() {
  [[ -f "$BACKUP_STORE/backup.env" ]]
}

backup_is_configured() {
  [[ -f "$BACKUP_STORE/state/configured" ]]
}

backup_load_config() {
  backup_is_installed \
    || die "The backup module is not installed. Run: ./habidat.sh install backup <repository> <provider-snapshots|append-only>"
  set -a
  # shellcheck disable=SC1091
  source "$BACKUP_STORE/backup.env"
  set +a
}

backup_require_configured() {
  backup_load_config
  backup_is_configured \
    || die "The backup repository is not set up yet. Run: ./habidat.sh configure backup"
}

# backup_repo_host <url>
#   Prints "<user> <host> <port> <path>" for ssh://user@host[:port]/path.
backup_repo_parts() {
  local re='^ssh://([^@/]+)@([^:/]+)(:([0-9]+))?(/.*)$'
  [[ "$1" =~ $re ]] || return 1
  printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-22}" "${BASH_REMATCH[5]}"
}

# ---------------------------------------------------------------------------
# borg
# ---------------------------------------------------------------------------

# backup_borg [docker run options...] -- <command...>
#   Runs a command in the pinned borg 1.4 container with the repository, key and
#   cache set up. Borg on the repository host is always borg-1.4 (Hetzner
#   offers 1.1, 1.2 and 1.4 with 1.2 as the default); BORG_REMOTE_PATH is the
#   environment form of --remote-path.
backup_borg() {
  local -a dargs=() extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    dargs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local -a env=(
    -e "BORG_REPO=${HABIDAT_BACKUP_REPOSITORY:?backup repository not configured}"
    -e "BORG_REMOTE_PATH=borg-1.4"
    -e "BORG_BASE_DIR=/cache"
    -e "BORG_RSH=ssh -i /config/ssh/id_ed25519 -o UserKnownHostsFile=/config/ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ServerAliveInterval=60"
    -e "BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no"
    -e "BORG_RELOCATED_REPO_ACCESS_IS_OK=no"
    -e "BORG_EXIT_CODES=legacy"
  )
  if [[ -f "$BACKUP_STORE/passphrase" ]]; then
    env+=(-e "BORG_PASSCOMMAND=cat /config/passphrase")
  fi
  # Snapshot times in the host's time zone, not the container's UTC.
  if [[ -f /etc/localtime ]]; then
    env+=(-v /etc/localtime:/etc/localtime:ro)
  fi
  # Extra docker options, e.g. to mount a local test repository.
  IFS=' ' read -r -a extra <<< "${HABIDAT_BORG_DOCKER_ARGS:-}"

  mkdir -p "$BACKUP_STORE/cache"
  docker run --rm "${env[@]}" \
    -v "$BACKUP_STORE:/config:ro" -v "$BACKUP_STORE/cache:/cache" \
    "${extra[@]+"${extra[@]}"}" "${dargs[@]+"${dargs[@]}"}" \
    "$HABIDAT_BORG_IMAGE" "$@"
}

# backup_list_snapshots
#   One snapshot per line: name <TAB> start time <TAB> comment, oldest first.
backup_list_snapshots() {
  backup_borg -- borg list --format '{archive}{TAB}{start:%Y-%m-%d %H:%M}{TAB}{comment}{NL}'
}

backup_snapshot_count() {
  local out
  out="$(backup_borg -- borg list --short)" || return 1
  grep -c . <<< "$out" || true
}

# backup_resolve_snapshot <name|latest>
backup_resolve_snapshot() {
  local name="$1" list
  list="$(backup_borg -- borg list --short)" || return 1
  if [[ "$name" == latest ]]; then
    name="$(tail -n1 <<< "$list")"
    [[ -n "$name" ]] || { log_error "The backup repository holds no snapshots."; return 1; }
  elif ! grep -qxF -- "$name" <<< "$list"; then
    log_error "Snapshot $name not found. See ./habidat.sh snapshots"
    return 1
  fi
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# State and alerts
# ---------------------------------------------------------------------------

backup_state_get() {
  cat "$BACKUP_STORE/state/$1" 2>/dev/null || true
}

backup_state_set() {
  mkdir -p "$BACKUP_STORE/state"
  printf '%s\n' "$2" > "$BACKUP_STORE/state/$1"
}

# backup_alert <subject> <body>
#   Logs the alert and mails it to HABIDAT_BACKUP_ALERT_EMAIL through the SMTP
#   server from setup.env. A failed mail is logged, never fatal.
backup_alert() {
  local subject="[habidat backup] ${HABIDAT_DOMAIN:-$(hostname)}: $1" body="$2"
  log_error "$subject"
  log_error "$body"

  local to="${HABIDAT_BACKUP_ALERT_EMAIL:-${HABIDAT_ADMIN_EMAIL:-}}"
  if [[ -z "$to" || -z "${HABIDAT_SMTP_HOST:-}" ]]; then
    log_warn "No alert address or SMTP server configured; alert not mailed."
    return 0
  fi

  python3 - "$to" "$subject" "$body" <<'PY' 2>&1 | log_module backup || log_warn "Could not mail the alert."
import os, smtplib, ssl, sys
from email.message import EmailMessage

to, subject, body = sys.argv[1:4]
env = os.environ.get
host = env("HABIDAT_SMTP_HOST")
port = int(env("HABIDAT_SMTP_PORT") or 25)
tls = env("HABIDAT_SMTP_TLS", "false") == "true"
msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = env("HABIDAT_SMTP_EMAILFROM") or env("HABIDAT_ADMIN_EMAIL") or to
msg["To"] = to
msg.set_content(body + "\n")
if tls and port == 465:
    smtp = smtplib.SMTP_SSL(host, port, context=ssl.create_default_context(), timeout=30)
else:
    smtp = smtplib.SMTP(host, port, timeout=30)
    if tls:
        smtp.starttls(context=ssl.create_default_context())
if env("HABIDAT_SMTP_USER"):
    smtp.login(env("HABIDAT_SMTP_USER"), env("HABIDAT_SMTP_PASSWORD") or "")
smtp.send_message(msg)
smtp.quit()
PY
}

# backup_check_count <count>
#   Alerts when the repository lost snapshots since the previous run, which is
#   what deleting them from a compromised server looks like (ADR 0008).
backup_check_count() {
  local count="$1" previous
  previous="$(backup_state_get count)"
  [[ -n "$previous" && -n "$count" ]] || return 0
  if (( count + BACKUP_COUNT_DROP <= previous )); then
    backup_alert "number of snapshots dropped from $previous to $count" \
      "The backup repository ${HABIDAT_BACKUP_REPOSITORY} held $previous snapshots after the last run and holds $count now.
If nobody deleted them on purpose, treat the server as compromised and $(backup_recovery_hint)"
  fi
}

backup_recovery_hint() {
  if [[ "${HABIDAT_BACKUP_PROTECTION:-}" == append-only ]]; then
    echo "do not run borg compact or any write without the append-only restriction until the repository has been checked (see borg's append-only notes)."
  else
    echo "recover the installation's directory from the Storage Box's .zfs/snapshot/ before its snapshot slots run out."
  fi
}

# ---------------------------------------------------------------------------
# backup run
# ---------------------------------------------------------------------------

backup_cmd_run() {
  backup_require_configured
  [[ -f "$BASE_DIR/setup.env" ]] || die "setup.env not found in $BASE_DIR"

  mkdir -p "$BACKUP_STORE/state"
  exec 9> "$BACKUP_STORE/state/run.lock"
  flock -n 9 || die "Another backup run is in progress."

  local staging="$BACKUP_STORE/staging" archive count
  archive="$(date +%Y-%m-%d-%H%M%S)"
  force_remove "$staging"
  mkdir -p "$staging"
  : > "$staging/units.tsv"
  chmod 700 "$BACKUP_STORE"
  register_cleanup "force_remove '$staging'"

  if count="$(backup_snapshot_count)"; then
    backup_check_count "$count"
  else
    backup_alert "backup repository not reachable" \
      "Could not list ${HABIDAT_BACKUP_REPOSITORY}. No snapshot was taken."
    return 1
  fi

  log_info "Exporting modules..."
  local mod inst failed=()
  for mod in $(get_ordered_modules); do
    [[ "$mod" == backup ]] && continue
    is_installed "$mod" || continue
    while IFS= read -r inst; do
      export_unit "$mod" "$inst" "$staging" || failed+=("$(unit_name "$mod" "$inst")")
    done < <(module_units "$mod")
  done

  cp "$BASE_DIR/setup.env" "$staging/setup.env"
  write_manifest "$staging" snapshot

  local comment="" volumes=""
  comment="$(awk -F'\t' '{u=$1; if ($2 != "") u=u "/" $2; printf "%s%s=%s", (NR>1?" ":""), u, $4}' "$staging/units.tsv")"
  volumes="$(cut -f5 "$staging/units.tsv" | tr ',' '\n' | grep -v '^$' | sort -u || true)"
  rm -f "$staging/units.tsv"
  mkdir -p "$staging/dumps" "$staging/volumes"

  local -a mounts=(-v "$staging:/snap" -v "$BASE_DIR/store:/snap/store:ro")
  local vol
  while IFS= read -r vol; do
    [[ -n "$vol" ]] && mounts+=(-v "$vol:/snap/volumes/$vol:ro")
  done <<< "$volumes"

  log_info "Creating snapshot $archive..."
  local rc=0
  run_logged backup backup_borg "${mounts[@]}" -w /snap -- \
    borg create --stats --compression zstd,3 --comment "$comment" \
      --exclude store/backup --exclude 'sh:store/.*' \
      "::$archive" manifest.json setup.env dumps store volumes || rc=$?

  if [[ $rc -ge 2 ]]; then
    backup_alert "snapshot failed" \
      "borg create exited with $rc. No snapshot was stored. See: journalctl -u habidat-backup"
    return 1
  fi
  backup_state_set last-success "$(date +%s)"
  backup_state_set last-snapshot "$archive"

  log_info "Pruning (keep $BACKUP_KEEP_DAILY daily, $BACKUP_KEEP_WEEKLY weekly, $BACKUP_KEEP_MONTHLY monthly)..."
  run_logged backup backup_borg -- borg prune --list \
    --keep-daily "$BACKUP_KEEP_DAILY" --keep-weekly "$BACKUP_KEEP_WEEKLY" \
    --keep-monthly "$BACKUP_KEEP_MONTHLY" || rc=$?
  # With append-only, prune only marks snapshots as deleted; space is freed by
  # hand from a trusted machine (ADR 0008).
  if [[ "${HABIDAT_BACKUP_PROTECTION:-}" == provider-snapshots ]]; then
    run_logged backup backup_borg -- borg compact || rc=$?
  fi
  if count="$(backup_snapshot_count)"; then
    backup_state_set count "$count"
  fi

  if [[ ${#failed[@]} -gt 0 ]]; then
    local missing
    missing="$(join_words "${failed[@]}")"
    backup_alert "snapshot $archive is missing $missing" \
      "The export of $missing failed, so snapshot $archive does not contain it. Every other module was backed up.
See: journalctl -u habidat-backup"
    return 1
  fi
  if [[ $rc -ge 2 ]]; then
    backup_alert "pruning failed" "Snapshot $archive was stored, but prune/compact exited with $rc."
    return 1
  fi
  log_info "Snapshot $archive stored."
}

# backup_cmd_watch
#   Run by the watch timer: alerts when no snapshot succeeded for
#   BACKUP_STALE_HOURS, at most once a day.
backup_cmd_watch() {
  backup_require_configured
  local now last since_alert
  now="$(date +%s)"
  last="$(backup_state_get last-success)"
  [[ -n "$last" ]] || last="$(stat -c %Y "$BACKUP_STORE/state/configured")"
  if (( now - last < BACKUP_STALE_HOURS * 3600 )); then
    log_info "Last successful snapshot: $(date -d "@$last" '+%Y-%m-%d %H:%M')."
    return 0
  fi
  since_alert="$(backup_state_get last-watch-alert)"
  if [[ -n "$since_alert" ]] && (( now - since_alert < 86400 )); then
    log_warn "No successful snapshot in ${BACKUP_STALE_HOURS} hours (already alerted today)."
    return 1
  fi
  backup_state_set last-watch-alert "$now"
  backup_alert "no successful snapshot in ${BACKUP_STALE_HOURS} hours" \
    "The last successful snapshot was taken $(date -d "@$last" '+%Y-%m-%d %H:%M').
Check: systemctl status habidat-backup.timer; journalctl -u habidat-backup"
  return 1
}

backup_cmd_check() {
  backup_require_configured
  local -a args=()
  case "${1:-}" in
    "") ;;
    --full) args=(--verify-data) ;;
    *) die "Usage: habidat.sh backup check [--full]" ;;
  esac
  log_info "Checking the backup repository${args[*]:+ and every chunk of data (this reads the whole repository)}..."
  run_logged backup backup_borg -- borg check --show-rc "${args[@]+"${args[@]}"}"
}

backup_cmd_status() {
  backup_require_configured
  local last
  last="$(backup_state_get last-success)"
  log_info "Repository:  ${HABIDAT_BACKUP_REPOSITORY}"
  log_info "Protection:  ${HABIDAT_BACKUP_PROTECTION}"
  if [[ -n "$last" ]]; then
    log_info "Last success: $(date -d "@$last" '+%Y-%m-%d %H:%M') ($(backup_state_get last-snapshot))"
  else
    log_info "Last success: never"
  fi
  log_info "Snapshots:   $(backup_state_get count)"
}

backup_cmd() {
  case "${1:-run}" in
    run) backup_cmd_run ;;
    check) shift; backup_cmd_check "$@" ;;
    watch) backup_cmd_watch ;;
    status) backup_cmd_status ;;
    *) die "Usage: habidat.sh backup [run|check [--full]|watch|status]" ;;
  esac
}

# ---------------------------------------------------------------------------
# snapshots
# ---------------------------------------------------------------------------

snapshots_cmd() {
  local module="${1:-}" instance="${2:-}"
  backup_require_configured
  if [[ -n "$module" ]] && ! is_valid_module "$module"; then
    die "Unknown module: $module"
  fi

  local list
  list="$(backup_list_snapshots)" || die "Could not list the backup repository."
  if [[ -z "$list" ]]; then
    log_info "The backup repository holds no snapshots."
    return 0
  fi

  local name time comment unit status shown=0
  while IFS=$'\t' read -r name time comment; do
    [[ -n "$name" ]] || continue
    if [[ -z "$module" ]]; then
      log_info "$name  $time  $comment"
      shown=1
      continue
    fi
    local entry match=""
    for entry in $(tr ' ' '\n' <<< "$comment"); do
      unit="${entry%=*}"
      status="${entry##*=}"
      if [[ -n "$instance" ]]; then
        [[ "$unit" == "$module/$instance" ]] || continue
      else
        [[ "$unit" == "$module" || "$unit" == "$module/"* ]] || continue
      fi
      match+="${match:+ }$unit=$status"
    done
    if [[ -n "$match" ]]; then
      log_info "$name  $time  $match"
      shown=1
    fi
  done <<< "$list"
  [[ $shown -eq 1 ]] || log_info "No snapshot contains $(unit_name "$module" "$instance")."
}

# ---------------------------------------------------------------------------
# export / import
# ---------------------------------------------------------------------------

export_cmd() {
  local target="${1:-}" instance="${2:-}"
  [[ -n "$target" ]] || die "Usage: habidat.sh export <module>|all [instance]"
  if [[ "$instance" == nodata ]]; then
    die "'nodata' is no longer supported: an export always contains the whole module, like a snapshot."
  fi

  local -a modules=()
  if [[ "$target" == all ]]; then
    [[ -z "$instance" ]] || die "An instance can only be given for a single module."
    local mod
    for mod in $(get_ordered_modules); do
      is_installed "$mod" && has_backup_support "$mod" && modules+=("$mod")
    done
  else
    is_valid_module "$target" || die "Unknown module: $target"
    if ! is_installed "$target"; then
      log_error "Module $target not installed, cannot export."
      return 0
    fi
    if ! has_backup_support "$target" || [[ -z "$(resolve_versioned_script "$target" export || true)" ]]; then
      log_error "Module $target has no export script for installed version."
      return 0
    fi
    modules=("$target")
  fi

  local mod inst had_error=false
  for mod in "${modules[@]+"${modules[@]}"}"; do
    while IFS= read -r inst; do
      export_unit_to_file "$mod" "$inst" || had_error=true
    done < <(module_units "$mod" "$([[ "$target" == all ]] || printf '%s' "$instance")")
  done
  [[ "$had_error" == false ]] || { log_error "Some exports failed. Check the output above."; return 1; }
}

# import_cmd <module> <filename>|list [--yes]
#   Kept one release, then removed together with <module>/legacy-import/:
#   - a file in the snapshot layout (it has a manifest.json) is restored like
#     `restore <module> --file`;
#   - a file written before snapshots goes to <module>/legacy-import/<v>.sh, the
#     unchanged import scripts of the previous release, picked by the installed
#     version as before. Those are what reads the exports the UPDATE notes ask
#     for before an update, and auth 1.x data on its way into auth 2.
import_cmd() {
  local module="${1:-}" filename="${2:-}"
  [[ -n "$module" ]] || die "Usage: habidat.sh import <module> <filename>|list"
  [[ "$module" == all ]] && die "Import can only be done per module."
  is_valid_module "$module" || die "Unknown module: $module"

  local dir
  dir="$(export_dir_for "$module")"
  if [[ "$filename" == list ]]; then
    echo "Available import files for $module:"
    ls -ltr "$dir" 2>/dev/null || echo "  (none)"
    return 0
  fi
  [[ -n "$filename" ]] || die "Usage: habidat.sh import <module> <filename>|list"
  if [[ ! -f "$dir/$filename" ]]; then
    log_error "Import file $filename not found."
    echo "Available files:"
    ls -ltr "$dir" 2>/dev/null || echo "  (none)"
    return 1
  fi

  if tar -tzf "$dir/$filename" manifest.json >/dev/null 2>&1; then
    log_warn "'import' is deprecated and will be removed; use: ./habidat.sh restore $module --file $dir/$filename"
    restore_cmd "$module" --file "$dir/$filename" "${@:3}"
  else
    legacy_import "$module" "$filename"
  fi
}

# legacy_import <module> <filename>
#   Runs the previous release's import script for a file in the old format.
legacy_import() {
  local module="$1" filename="$2" script rc=0

  if ! is_installed "$module"; then
    log_error "Module $module not installed, cannot import."
    return 1
  fi
  script="$(resolve_versioned_script "$module" legacy-import)" || script=""
  if [[ -z "$script" ]]; then
    log_error "$filename is in the export format before snapshots, and $module has no import script for it at the installed version."
    return 1
  fi

  log_warn "$filename is in the export format before snapshots. Importing it the old way; this goes away in the next release."
  log_info "Importing $module from $filename (using $module/legacy-import/$(basename "$script"))..."
  (
    # The old scripts read the file from here, as the old import did.
    export HABIDAT_BACKUP_DIR="${HABIDAT_BACKUP_DIR:-$BASE_DIR/exports}"
    run_logged "$module" run_module_script "$module" "$script" "$filename"
  ) || rc=$?
  if [[ $rc -ne 0 ]]; then
    log_error "Import of $module failed (exit code $rc)."
    return "$rc"
  fi
  log_info "Import of $module complete."
}

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------

restore_usage() {
  die "Usage: habidat.sh restore <module>|all [instance] <snapshot>|latest [--yes]
       habidat.sh restore <module> [instance] --file <export-file> [--yes]"
}

# restore_confirm <question>
restore_confirm() {
  [[ "${RESTORE_YES:-false}" == true ]] && return 0
  if [[ ! -r /dev/tty ]] || ! { true > /dev/tty; } 2>/dev/null; then
    die "$1 Pass --yes to confirm without a terminal."
  fi
  local reply
  read -r -p "$1 [y/N] " reply < /dev/tty
  [[ "$reply" =~ ^[Yy]$ ]] || die "Restore cancelled."
}

restore_cmd() {
  local -a positional=()
  local file="" RESTORE_YES=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) [[ $# -ge 2 ]] || restore_usage; file="$2"; shift 2 ;;
      --file=*) file="${1#--file=}"; shift ;;
      --yes|-y) RESTORE_YES=true; shift ;;
      -*) restore_usage ;;
      *) positional+=("$1"); shift ;;
    esac
  done

  local target="${positional[0]:-}" instance="" snapshot=""
  [[ -n "$target" ]] || restore_usage
  if [[ -n "$file" ]]; then
    [[ ${#positional[@]} -le 2 ]] || restore_usage
    instance="${positional[1]:-}"
  else
    case ${#positional[@]} in
      2) snapshot="${positional[1]}" ;;
      3) instance="${positional[1]}"; snapshot="${positional[2]}" ;;
      *) restore_usage ;;
    esac
  fi
  if [[ "$target" == all ]]; then
    [[ -z "$file" ]] || die "A whole installation can only be restored from a snapshot."
    [[ -z "$instance" ]] || restore_usage
  else
    is_valid_module "$target" || die "Unknown module: $target"
    [[ "$target" != backup ]] || die "store/backup is never restored; this server keeps its own key."
    if [[ -n "$instance" ]] && ! is_multi_instance "$target"; then
      die "Module $target has no instances."
    fi
  fi

  local work
  work="$BASE_DIR/store/.restore/source-$$"
  force_remove "$work"
  mkdir -p "$work"
  register_cleanup "force_remove '$work'"

  # --- the source and its manifest ---
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || die "Export file $file not found."
    file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    if ! tar -tzf "$file" manifest.json >/dev/null 2>&1; then
      die "$file was written by the export format before snapshots (no manifest.json). Until the next release, put it into $(export_dir_for "$target")/ and run: ./habidat.sh import $target $(basename "$file")"
    fi
    export HABIDAT_RESTORE_SOURCE="file:$file"
    restore_extract "$work" manifest.json || die "Could not read $file."
  else
    backup_require_configured
    snapshot="$(backup_resolve_snapshot "$snapshot")" || exit 1
    export HABIDAT_RESTORE_SOURCE="snapshot:$snapshot"
    restore_extract "$work" manifest.json setup.env || true
    [[ -f "$work/manifest.json" ]] || die "Snapshot $snapshot has no manifest.json."
  fi
  local manifest="$work/manifest.json" source_label="${file:-snapshot $snapshot}"

  # --- setup.env: from the snapshot for `all`, or when this server has none ---
  if [[ -z "$file" ]] && { [[ "$target" == all ]] || [[ ! -f "$BASE_DIR/setup.env" ]]; }; then
    [[ -f "$work/setup.env" ]] || die "Snapshot $snapshot has no setup.env."
    if [[ -f "$BASE_DIR/setup.env" ]] && ! cmp -s "$work/setup.env" "$BASE_DIR/setup.env"; then
      restore_confirm "This replaces setup.env with the one from snapshot $snapshot (the current one is kept as setup.env.before-restore)."
      cp "$BASE_DIR/setup.env" "$BASE_DIR/setup.env.before-restore"
    fi
    cp "$work/setup.env" "$BASE_DIR/setup.env"
    log_info "Restored setup.env from snapshot $snapshot."
  fi
  load_setup_env
  check_prerequisites

  local snap_prefix
  snap_prefix="$(manifest_get "$manifest" docker_prefix)"
  if [[ -n "$snap_prefix" && "$snap_prefix" != "${HABIDAT_DOCKER_PREFIX:-}" ]]; then
    die "The source was taken with Docker prefix '$snap_prefix', this installation uses '${HABIDAT_DOCKER_PREFIX:-}'. Every volume name contains the prefix, so they must match."
  fi

  # --- units ---
  local -a units=()
  local mod inst version status volumes skipped=false
  local order mod_order
  order="$(get_ordered_modules)"
  for mod_order in $order; do
    [[ "$target" == all || "$target" == "$mod_order" ]] || continue
    [[ "$mod_order" == backup ]] && continue
    while IFS='|' read -r mod inst version status volumes; do
      [[ -n "$mod" ]] || continue
      case "$status" in
        ok) units+=("$mod|$inst|$version|$volumes") ;;
        none) log_warn "$(unit_name "$mod" "$inst") has no export support; not restored." ;;
        *) log_error "$(unit_name "$mod" "$inst") failed to export in this snapshot; not restored."; skipped=true ;;
      esac
    done < <(manifest_units "$manifest" "$mod_order" "$( [[ "$target" == all ]] || printf '%s' "$instance")")
  done
  [[ ${#units[@]} -gt 0 ]] || die "Nothing to restore from $source_label."

  if [[ "$target" != all ]]; then
    local dep
    while IFS= read -r dep; do
      dep="$(tr -d '[:space:]' <<< "$dep")"
      [[ -z "$dep" ]] || is_installed "$dep" \
        || die "$target needs $dep, which is not installed here. Restore $dep first, or use: ./habidat.sh restore all $snapshot"
    done < <(get_module_dependencies "$target")
  fi

  local names=() u
  for u in "${units[@]}"; do
    IFS='|' read -r mod inst _ _ <<< "$u"
    names+=("$(unit_name "$mod" "$inst")")
  done
  local names_list
  names_list="$(join_words "${names[@]}")"
  restore_confirm "Replace $names_list with the state from $source_label? Their current data is lost."

  # --- restore, link, update ---
  local had_error=false restored=()
  for u in "${units[@]}"; do
    IFS='|' read -r mod inst version volumes <<< "$u"
    if restore_unit "$mod" "$inst" "$version" "$volumes"; then
      restored+=("$mod|$inst")
    else
      had_error=true
      [[ "$target" == all ]] || return 1
    fi
  done

  log_info "Running link steps..."
  if [[ "$target" == all ]]; then
    for mod in $order; do
      link_module "$mod" || had_error=true
    done
  else
    for u in "${restored[@]}"; do
      IFS='|' read -r mod inst <<< "$u"
      link_module "$mod" "$inst" || had_error=true
    done
    if grep -qxF "$target" < <(modules_others_write_into); then
      link_dependents "$target" || had_error=true
    fi
  fi
  update_installed_modules_env

  log_info "Updating restored modules to the repository's version..."
  local done_mods=" "
  for u in "${restored[@]}"; do
    IFS='|' read -r mod inst <<< "$u"
    [[ "$done_mods" == *" $mod "* ]] && continue
    done_mods+="$mod "
    update_module "$mod" || had_error=true
  done

  if [[ "$had_error" == true || "$skipped" == true ]]; then
    log_error "The restore finished with errors. Check the output above."
    return 1
  fi
  log_info "Restore of $names_list from $source_label complete."
}
