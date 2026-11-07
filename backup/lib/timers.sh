#!/usr/bin/env bash
# The backup module's image and systemd timers. Sourced, not executed; needs
# the habidat libraries (see bootstrap.sh).

BACKUP_UNITS=(habidat-backup.service habidat-backup.timer habidat-backup-watch.service habidat-backup-watch.timer)
BACKUP_TIMERS=(habidat-backup.timer habidat-backup-watch.timer)
BACKUP_SYSTEMD_DIR="${HABIDAT_SYSTEMD_DIR:-/etc/systemd/system}"

backup_build_image() {
  echo "Building $HABIDAT_BORG_IMAGE..."
  docker build -q -t "$HABIDAT_BORG_IMAGE" "$BASE_DIR/backup/borg" >/dev/null
  docker run --rm "$HABIDAT_BORG_IMAGE" borg --version
}

backup_can_manage_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -w "$BACKUP_SYSTEMD_DIR" ]]
}

# backup_render_units <version> <dir>
backup_render_units() {
  local version="$1" dir="$2" unit
  mkdir -p "$dir"
  export HABIDAT_BACKUP_BASE_DIR="$BASE_DIR"
  for unit in "${BACKUP_UNITS[@]}"; do
    render_versioned_template backup "$version" "config/$unit.j2" "$dir/$unit"
  done
}

# backup_install_timers <version>
#   Installs and starts the nightly snapshot and the watch timer. Without root
#   (or systemd), renders the units into store/backup/systemd/ and says how to
#   install them.
backup_install_timers() {
  local version="$1" unit
  if ! backup_can_manage_systemd; then
    backup_render_units "$version" "$BACKUP_STORE/systemd"
    echo "Cannot write to $BACKUP_SYSTEMD_DIR. As root, run:"
    echo "  cp $BACKUP_STORE/systemd/habidat-backup* $BACKUP_SYSTEMD_DIR/"
    echo "  systemctl daemon-reload && systemctl enable --now $(join_words "${BACKUP_TIMERS[@]}")"
    return 0
  fi
  for unit in "${BACKUP_UNITS[@]}"; do
    if [[ -f "$BACKUP_SYSTEMD_DIR/$unit" ]] && ! grep -qF "$BASE_DIR/habidat.sh" "$BACKUP_SYSTEMD_DIR/$unit" \
        && [[ "$unit" == *.service ]]; then
      echo "$BACKUP_SYSTEMD_DIR/$unit belongs to another habidat installation; not replaced." >&2
      return 1
    fi
  done
  backup_render_units "$version" "$BACKUP_SYSTEMD_DIR"
  systemctl daemon-reload
  systemctl enable --now "${BACKUP_TIMERS[@]}"
  echo "Snapshots run every night at 03:00 (systemctl list-timers 'habidat-backup*')."
}

backup_enable_timers() {
  backup_is_configured || { echo "Backup is not configured yet (./habidat.sh configure backup)."; return 0; }
  if backup_can_manage_systemd && [[ -f "$BACKUP_SYSTEMD_DIR/habidat-backup.timer" ]]; then
    systemctl enable --now "${BACKUP_TIMERS[@]}"
  else
    echo "The backup timers are not installed here, or need root; see ./habidat.sh configure backup."
  fi
}

backup_disable_timers() {
  if backup_can_manage_systemd && [[ -f "$BACKUP_SYSTEMD_DIR/habidat-backup.timer" ]]; then
    systemctl disable --now "${BACKUP_TIMERS[@]}"
    echo "Nightly snapshots are off until ./habidat.sh start backup."
  fi
}

backup_remove_timers() {
  backup_can_manage_systemd || return 0
  local unit
  systemctl disable --now "${BACKUP_TIMERS[@]}" 2>/dev/null || true
  for unit in "${BACKUP_UNITS[@]}"; do
    rm -f "$BACKUP_SYSTEMD_DIR/$unit"
  done
  systemctl daemon-reload
}
