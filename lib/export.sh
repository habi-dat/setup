#!/usr/bin/env bash
# Export contract shared by snapshots (lib/backup.sh) and export files.
# Sourced by habidat.sh and by module scripts -- do not execute directly.
#
# A module or module instance (a "unit") is backed up as three parts, laid out
# the same way in a snapshot and in an export file (ADR 0005):
#
#   manifest.json            module versions, instances, prefix, commit, status
#   setup.env                snapshots only
#   dumps/<unit>/            what the module's export script wrote
#   store/<unit>/            the unit's store folder, read in place
#   volumes/<volume>/        the named Docker volumes the export script listed
#
# where <unit> is <module> or <module>/<instance>.
#
# <module>/export/<version>.sh is sourced with the module directory as cwd and
# the instance id (if any) as $1. It writes uncompressed dumps into
# $HABIDAT_EXPORT_DIR while the module keeps running, and names its volumes with
# export_volume. It must fail (non-zero) when it could not export.
#
# <module>/restore/<version>.sh runs at the version recorded in the snapshot,
# after the unit's store folder has been put back. It finds the dumps in
# $HABIDAT_RESTORE_DIR, refills volumes with restore_volume, and starts the
# unit. Link steps and the update to the current version run afterwards.

# Image for the small jobs around volumes: GNU tar for export files, and
# Python's sqlite3 for online SQLite backups.
HABIDAT_TOOLS_IMAGE="${HABIDAT_TOOLS_IMAGE:-python:3.13-slim}"

# force_remove <path>
#   rm -rf that also works for a non-root user on files a container created as
#   root (dumps, extracted snapshot parts, mount points).
force_remove() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  rm -rf "$path" 2>/dev/null && return 0
  docker run --rm -v "$(dirname "$path"):/parent" "$HABIDAT_TOOLS_IMAGE" \
    rm -rf "/parent/$(basename "$path")"
}

# force_move <src> <dst>
#   mv for paths under store/ that a container may have created as root.
force_move() {
  mv "$1" "$2" 2>/dev/null && return 0
  local store="$BASE_DIR/store"
  [[ "$1" == "$store"/* && "$2" == "$store"/* ]] || { mv "$1" "$2"; return; }
  docker run --rm -v "$store:/store" "$HABIDAT_TOOLS_IMAGE" \
    mv "/store/${1#"$store"/}" "/store/${2#"$store"/}"
}

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

# unit_name <module> [instance]
unit_name() {
  if [[ -n "${2:-}" ]]; then
    printf '%s/%s' "$1" "$2"
  else
    printf '%s' "$1"
  fi
}

# module_instances <module>
#   Instance ids of an installed multi-instance module, one per line.
module_instances() {
  local dir
  for dir in "$BASE_DIR/store/$1"/*/; do
    [[ -f "${dir}docker-compose.yml" ]] || continue
    basename "${dir%/}"
  done
}

# module_units <module> [instance]
#   Prints one line per unit: the instance id, or an empty line for a module
#   without instances.
module_units() {
  local module="$1" instance="${2:-}"
  if ! is_multi_instance "$module"; then
    [[ -z "$instance" ]] || { log_error "Module $module has no instances."; return 1; }
    echo ""
  elif [[ -n "$instance" ]]; then
    [[ -f "$BASE_DIR/store/$module/$instance/docker-compose.yml" ]] \
      || { log_error "Module $module has no instance $instance."; return 1; }
    echo "$instance"
  else
    module_instances "$module"
  fi
}

# has_backup_support <module>
#   Modules that own an export script. mailtrain (being retired) and
#   direktkredit (data in an external platform) have none; their store folder
#   is still part of every snapshot.
has_backup_support() {
  [[ -d "$BASE_DIR/$1/export" ]]
}

# ---------------------------------------------------------------------------
# Helpers for export scripts
# ---------------------------------------------------------------------------

# export_volume <volume>
#   Names a Docker volume that belongs to the unit being exported. It is read in
#   place, so the script must not copy it.
export_volume() {
  if [[ -z "${HABIDAT_EXPORT_VOLUMES:-}" ]]; then
    echo "export_volume called outside of an export." >&2
    return 1
  fi
  if ! docker volume inspect "$1" >/dev/null 2>&1; then
    echo "Docker volume $1 does not exist." >&2
    return 1
  fi
  echo "$1" >> "$HABIDAT_EXPORT_VOLUMES"
}

# export_sqlite <volume> <path-in-volume> <dump-name>
#   Online backup of a SQLite database (consistent while the app writes to it).
export_sqlite() {
  local volume="$1" path="$2" name="$3"
  docker run --rm -v "$volume:/data" -v "$HABIDAT_EXPORT_DIR:/out" "$HABIDAT_TOOLS_IMAGE" \
    python3 -c 'import sqlite3, sys
# Not read-only: reading a database in WAL mode may need to create its -shm.
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()' "/data/$path" "/out/$name"
}

# ---------------------------------------------------------------------------
# Helpers for restore scripts
# ---------------------------------------------------------------------------

# restore_volume <volume> [<compose-project> <volume-key>]
#   Makes the volume hold exactly what the snapshot or export file holds for it,
#   creating it when missing. Containers using it must be stopped. Pass the
#   compose project and the volume's key in the compose file for volumes that
#   docker compose manages, so compose recognises a volume created here.
restore_volume() {
  local name="$1" project="${2:-}" key="${3:-}"

  if [[ ",${HABIDAT_RESTORE_VOLUMES:-}," != *",$name,"* ]]; then
    echo "Volume $name is not part of what is being restored." >&2
    return 1
  fi

  if ! docker volume inspect "$name" >/dev/null 2>&1; then
    local -a labels=()
    if [[ -n "$project" ]]; then
      labels=(--label "com.docker.compose.project=$project" --label "com.docker.compose.volume=$key")
    fi
    docker volume create "${labels[@]}" "$name" >/dev/null
  fi

  echo "Restoring volume $name..."
  case "${HABIDAT_RESTORE_SOURCE:-}" in
    file:*)
      docker run --rm -v "$name:/v" -v "${HABIDAT_RESTORE_SOURCE#file:}:/in.tar.gz:ro" \
        "$HABIDAT_TOOLS_IMAGE" sh -c \
        'find /v -mindepth 1 -delete && tar -xzf /in.tar.gz -C /v --numeric-owner --strip-components=2 "volumes/$1"' \
        sh "$name"
      ;;
    snapshot:*)
      backup_borg -v "$name:/restore/volumes/$name" -- sh -c \
        'find "/restore/volumes/$1" -mindepth 1 -delete && cd /restore && borg extract --numeric-ids "::$2" "volumes/$1"' \
        sh "$name" "${HABIDAT_RESTORE_SOURCE#snapshot:}"
      ;;
    *)
      echo "restore_volume called outside of a restore." >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Exporting units
# ---------------------------------------------------------------------------

# export_unit <module> <instance> <root>
#   Runs the unit's export script, writing dumps to <root>/dumps/<unit>/, and
#   records the result as a line in <root>/units.tsv:
#     module  instance  version  status  volumes(comma-separated)
#   status is ok, failed or none (the module has no export script). Returns
#   non-zero only for failed.
export_unit() {
  local module="$1" instance="$2" root="$3"
  local unit version script status=ok dump_dir volumes_file volumes=""

  unit="$(unit_name "$module" "$instance")"
  version="$(get_installed_version "$module")"
  dump_dir="$root/dumps/$unit"
  volumes_file="$root/.volumes-${unit//\//_}"

  force_remove "$dump_dir"
  mkdir -p "$dump_dir"
  : > "$volumes_file"

  script="$(resolve_versioned_script "$module" export)" || script=""
  if [[ -z "$script" ]] && has_backup_support "$module"; then
    # A module that can be exported but not at this version: update it.
    status=failed
    log_error "Module $module has no export script for installed version ${version:-unknown}."
  elif [[ -z "$script" ]]; then
    status=none
  else
    log_info "Exporting $unit (using $module/export/$(basename "$script"))..."
    if ! (
      export HABIDAT_EXPORT_DIR="$dump_dir" HABIDAT_EXPORT_VOLUMES="$volumes_file"
      run_logged "$module" run_module_script "$module" "$script" ${instance:+"$instance"}
    ); then
      status=failed
      log_error "Export of $unit failed."
    fi
  fi

  volumes="$(sort -u "$volumes_file" | paste -sd, -)"
  rm -f "$volumes_file"
  printf '%s\t%s\t%s\t%s\t%s\n' "$module" "$instance" "$version" "$status" "$volumes" >> "$root/units.tsv"

  [[ "$status" != failed ]]
}

# write_manifest <root> <kind>
#   Turns <root>/units.tsv into <root>/manifest.json.
write_manifest() {
  local root="$1" kind="$2" commit
  commit="$(git -C "$BASE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  python3 - "$root" "$kind" "$commit" "${HABIDAT_DOCKER_PREFIX:-}" "${HABIDAT_DOMAIN:-}" <<'PY'
import datetime, json, os, socket, sys

root, kind, commit, prefix, domain = sys.argv[1:6]
units = []
tsv = os.path.join(root, "units.tsv")
if os.path.exists(tsv):
    for line in open(tsv):
        line = line.rstrip("\n")
        if not line:
            continue
        module, instance, version, status, volumes = (line.split("\t") + [""] * 5)[:5]
        units.append({
            "module": module,
            "instance": instance or None,
            "version": version,
            "status": status,
            "volumes": [v for v in volumes.split(",") if v],
        })
manifest = {
    "format": 1,
    "kind": kind,
    "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname(),
    "repo_commit": commit,
    "docker_prefix": prefix,
    "domain": domain,
    "units": units,
}
with open(os.path.join(root, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}

# manifest_get <manifest.json> <key>
manifest_get() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1" "$2"
}

# manifest_units <manifest.json> [module] [instance]
#   Units in the manifest, one per line: module|instance|version|status|volumes
#   ("|", not a tab: bash's `read` merges adjacent tabs, which would swallow an
#   empty instance field).
manifest_units() {
  python3 - "$@" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
module = sys.argv[2] if len(sys.argv) > 2 else ""
instance = sys.argv[3] if len(sys.argv) > 3 else ""
for u in manifest.get("units", []):
    if module and u["module"] != module:
        continue
    if instance and (u.get("instance") or "") != instance:
        continue
    print("|".join([u["module"], u.get("instance") or "", u.get("version") or "",
                     u.get("status") or "", ",".join(u.get("volumes") or [])]))
PY
}

# ---------------------------------------------------------------------------
# Export files (./habidat.sh export)
# ---------------------------------------------------------------------------

export_dir_for() {
  printf '%s' "${HABIDAT_BACKUP_DIR:-$BASE_DIR/exports}/${HABIDAT_DOCKER_PREFIX:-habidat}/$1"
}

# export_unit_to_file <module> <instance>
#   Writes one unit to <export dir>/<module>/<module>[-<instance>]-<date>.tar.gz
#   with the same layout as a snapshot.
export_unit_to_file() {
  local module="$1" instance="$2"
  local unit work out_dir file volumes

  unit="$(unit_name "$module" "$instance")"
  work="$BASE_DIR/store/.export/${unit//\//_}"
  force_remove "$work"
  mkdir -p "$work"

  if ! export_unit "$module" "$instance" "$work"; then
    force_remove "$work"
    return 1
  fi
  if grep -q $'\tnone\t' "$work/units.tsv"; then
    log_error "Module $module has no export script for installed version."
    force_remove "$work"
    return 1
  fi
  write_manifest "$work" export
  rm -f "$work/units.tsv"

  out_dir="$(export_dir_for "$module")"
  mkdir -p "$out_dir"
  file="$module${instance:+-$instance}-$(date +%Y%m%d%H%M).tar.gz"

  local -a mounts=(-v "$work:/x" -v "$out_dir:/out" -v "$BASE_DIR/store/$unit:/x/store/$unit:ro")
  local vol
  local -a vols=()
  volumes="$(manifest_units "$work/manifest.json" | cut -d'|' -f5)"
  IFS=',' read -r -a vols <<< "$volumes"
  for vol in "${vols[@]+"${vols[@]}"}"; do
    [[ -n "$vol" ]] && mounts+=(-v "$vol:/x/volumes/$vol:ro")
  done

  log_info "Packing $unit into $out_dir/$file..."
  if ! docker run --rm "${mounts[@]}" "$HABIDAT_TOOLS_IMAGE" \
      sh -c 'mkdir -p /x/volumes && cd /x && tar --numeric-owner -czf "/out/$1" manifest.json dumps store volumes' \
      sh "$file"; then
    log_error "Could not write $out_dir/$file."
    force_remove "$work"
    return 1
  fi
  force_remove "$work"
  log_info "Export of $unit written to $out_dir/$file"
}

# ---------------------------------------------------------------------------
# Restoring units
# ---------------------------------------------------------------------------

# restore_extract <dest> <archive-path>...
#   Extracts paths of the current restore source into <dest>.
restore_extract() {
  local dest="$1"; shift
  mkdir -p "$dest"
  case "${HABIDAT_RESTORE_SOURCE:-}" in
    file:*)
      tar -xzf "${HABIDAT_RESTORE_SOURCE#file:}" -C "$dest" --numeric-owner "$@"
      ;;
    snapshot:*)
      local rc=0
      # borg creates the parents of a partial extract as root with mode 0700;
      # open them so a non-root operator can reach what was extracted.
      backup_borg -v "$dest:/restore" -- sh -c '
        cd /restore || exit 2
        archive="$1"; shift
        borg extract --numeric-ids "::$archive" "$@"; rc=$?
        for p in "$@"; do
          d="$(dirname "$p")"
          while [ "$d" != . ]; do
            [ -d "$d" ] && chmod a+rx "$d"
            d="$(dirname "$d")"
          done
        done
        exit "$rc"' sh "${HABIDAT_RESTORE_SOURCE#snapshot:}" "$@" || rc=$?
      # 1 is borg's "warning", e.g. a path that is not in the archive. The
      # caller checks for what it needs.
      [[ $rc -le 1 ]]
      ;;
    *)
      log_error "restore_extract called outside of a restore."
      return 1
      ;;
  esac
}

# restore_unit <module> <instance> <version> <volumes-csv>
#   Puts back the unit's store folder and runs the module's restore script for
#   <version>, with HABIDAT_RESTORE_SOURCE already set by the caller.
restore_unit() {
  local module="$1" instance="$2" version="$3" volumes="$4"
  local unit script work target

  unit="$(unit_name "$module" "$instance")"
  script="$(resolve_versioned_script "$module" restore "$version")" || script=""
  if [[ -z "$script" ]]; then
    log_error "Module $module has no restore script for version $version."
    return 1
  fi

  if [[ -n "$instance" ]]; then
    local local_version
    local_version="$(get_installed_version "$module")"
    if [[ -n "$local_version" && "$local_version" != "$version" ]] && [[ -n "$(module_instances "$module" | grep -vxF "$instance" || true)" ]]; then
      log_error "$module is at version $local_version here but $version in the snapshot, and other instances exist."
      log_error "Restore all $module instances together, or update first so both versions match."
      return 1
    fi
  fi

  work="$BASE_DIR/store/.restore/$(date +%Y%m%d%H%M%S)-${unit//\//_}"
  force_remove "$work"
  log_info "Restoring $unit at version $version (using $module/restore/$(basename "$script"))..."
  if ! restore_extract "$work" "dumps/$unit" "store/$unit" || [[ ! -d "$work/store/$unit" ]]; then
    log_error "The source has no store/$unit."
    force_remove "$work"
    return 1
  fi
  mkdir -p "$work/dumps/$unit"

  target="$BASE_DIR/store/$unit"
  if [[ -e "$target" ]]; then
    mkdir -p "$work/previous"
    force_move "$target" "$work/previous/"
  fi
  mkdir -p "$(dirname "$target")"
  force_move "$work/store/$unit" "$target"

  if [[ -n "$instance" ]]; then
    echo "$version" > "$BASE_DIR/store/$module/version"
    if [[ -f "$BASE_DIR/$module/dependencies" ]]; then
      cp "$BASE_DIR/$module/dependencies" "$BASE_DIR/store/$module/dependencies"
    fi
  fi

  local rc=0
  (
    export HABIDAT_RESTORE_DIR="$work/dumps/$unit" HABIDAT_RESTORE_VOLUMES="$volumes"
    run_logged "$module" run_module_script "$module" "$script" ${instance:+"$instance"}
  ) || rc=$?

  if [[ $rc -ne 0 ]]; then
    log_error "Restore of $unit failed (exit code $rc)."
    if [[ -d "$work/previous" ]]; then
      log_error "The store folder from before the restore is kept in ${work#"$BASE_DIR"/}/previous."
    fi
    return "$rc"
  fi
  force_remove "$work"
  log_info "Restored $unit."
}

# ---------------------------------------------------------------------------
# Link steps (ADR 0007)
# ---------------------------------------------------------------------------

# link_module <module> [instance]
#   Runs <module>/link.sh, which rewrites what the module contributes to other
#   modules from its own store folder. Without an instance, a multi-instance
#   module links every instance.
link_module() {
  local module="$1" instance="${2:-}"
  [[ -x "$BASE_DIR/$module/link.sh" ]] || return 0
  is_installed "$module" || return 0
  log_info "LINK $(unit_name "$module" "$instance")..."
  run_module_executable "$module" link.sh ${instance:+"$instance"}
}

# link_dependents <module>
#   After restoring a module that others write into (auth, nextcloud, nginx),
#   every installed module that depends on it runs its link step again.
link_dependents() {
  local module="$1" mod rc=0
  for mod in $(get_ordered_modules); do
    [[ "$mod" == "$module" ]] && continue
    is_installed "$mod" || continue
    get_module_dependencies "$mod" | tr -d '[:blank:]' | grep -qxF "$module" || continue
    link_module "$mod" || rc=1
  done
  return "$rc"
}

# modules_others_write_into
#   Modules whose store or database other modules add to.
modules_others_write_into() {
  printf '%s\n' nginx auth nextcloud
}
