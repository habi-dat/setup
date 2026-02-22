#!/usr/bin/env bash
# Version comparison, migration runner, and export/import version resolver.
# Sourced by habidat.sh -- do not execute directly.

# ---------------------------------------------------------------------------
# version_cmp <v1> <v2>
#   Prints: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
# ---------------------------------------------------------------------------
version_cmp() {
  if [[ "$1" == "$2" ]]; then
    echo "0"
    return
  fi
  local lower
  lower=$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)
  if [[ "$lower" == "$1" ]]; then
    echo "-1"
  else
    echo "1"
  fi
}

# ---------------------------------------------------------------------------
# version_gt / version_lt / version_eq  <v1> <v2>
# ---------------------------------------------------------------------------
version_gt() { [[ "$(version_cmp "$1" "$2")" == "1" ]]; }
version_lt() { [[ "$(version_cmp "$1" "$2")" == "-1" ]]; }
version_eq() { [[ "$1" == "$2" ]]; }
version_ge() { ! version_lt "$1" "$2"; }
version_le() { ! version_gt "$1" "$2"; }

# ---------------------------------------------------------------------------
# get_installed_version <module>
#   Reads store/<module>/version. Returns empty string if not found.
# ---------------------------------------------------------------------------
get_installed_version() {
  local vfile="$BASE_DIR/store/$1/version"
  if [[ -f "$vfile" ]]; then
    cat "$vfile" | tr -d '[:space:]'
  fi
}

# ---------------------------------------------------------------------------
# get_target_version <module>
#   Reads <module>/version (the repo's current version).
# ---------------------------------------------------------------------------
get_target_version() {
  local vfile="$BASE_DIR/$1/version"
  if [[ -f "$vfile" ]]; then
    cat "$vfile" | tr -d '[:space:]'
  fi
}

# ---------------------------------------------------------------------------
# list_migration_versions <module>
#   Lists version directories under <module>/versions/ that have a migrate.sh,
#   sorted ascending by version.
# ---------------------------------------------------------------------------
list_migration_versions() {
  local module="$1"
  local versions_dir="$BASE_DIR/$module/versions"

  if [[ ! -d "$versions_dir" ]]; then
    return
  fi

  for d in "$versions_dir"/*/; do
    [[ -d "$d" ]] || continue
    local ver
    ver=$(basename "$d")
    if [[ -f "$d/migrate.sh" ]]; then
      echo "$ver"
    fi
  done | sort -V
}

# ---------------------------------------------------------------------------
# list_all_version_dirs <module>
#   Lists ALL version directories (with or without migrate.sh), sorted ascending.
# ---------------------------------------------------------------------------
list_all_version_dirs() {
  local module="$1"
  local versions_dir="$BASE_DIR/$module/versions"

  if [[ ! -d "$versions_dir" ]]; then
    return
  fi

  for d in "$versions_dir"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done | sort -V
}

# ---------------------------------------------------------------------------
# run_migrations <module> [force]
#
# Runs all applicable migration scripts from installed version to target.
# Updates store/<module>/version after each successful step.
# ---------------------------------------------------------------------------
run_migrations() {
  local module="$1"
  local force="${2:-}"

  local installed
  installed=$(get_installed_version "$module")
  local target
  target=$(get_target_version "$module")

  if [[ -z "$target" ]] && [[ "$force" != "force" ]]; then
    log_error "Module $module: target version not found, cannot update. Use force to override."
    return 1
  fi

  if [[ -z "$installed" ]] && [[ "$force" != "force" ]]; then
    log_error "Module $module: installed version not found, cannot update. Use force to override."
    return 1
  fi

  if [[ -z "$installed" ]] || [[ -z "$target" ]]; then
    installed="${installed:-0.0.0}"
    target="${target:-0.0.0}"
  fi

  if version_eq "$installed" "$target" && [[ "$force" != "force" ]]; then
    log_info "Module $module is up to date (version $installed). Use force to update anyway."
    return 0
  fi

  if version_gt "$installed" "$target" && [[ "$force" != "force" ]]; then
    log_error "Module $module: installed version $installed is newer than target $target. Downgrade not supported."
    return 1
  fi

  # Collect applicable migrations: versions > installed AND <= target
  local migrations=()
  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    if version_gt "$ver" "$installed" && version_le "$ver" "$target"; then
      migrations+=("$ver")
    fi
  done < <(list_migration_versions "$module")

  if [[ ${#migrations[@]} -eq 0 ]]; then
    log_info "Module $module: no migration scripts between $installed and $target. Updating version marker."
    if [[ "$DRY_RUN" != "true" ]]; then
      echo "$target" > "$BASE_DIR/store/$module/version"
    fi
    return 0
  fi

  log_info "Module $module: migrating $installed -> $target (${#migrations[@]} step(s): ${migrations[*]})"

  if [[ "$DRY_RUN" == "true" ]]; then
    for ver in "${migrations[@]}"; do
      log_info "  [dry-run] Would run $module/versions/$ver/migrate.sh"
    done
    return 0
  fi

  for ver in "${migrations[@]}"; do
    log_info "Running migration $module $installed -> $ver ..."

    # Export context variables for the migration script
    export HABIDAT_MIGRATE_MODULE="$module"
    export HABIDAT_MIGRATE_VERSION="$ver"
    export HABIDAT_MIGRATE_FROM="$installed"

    (
      cd "$BASE_DIR/$module" || exit 1
      # shellcheck disable=SC1090
      source "$BASE_DIR/$module/versions/$ver/migrate.sh"
    ) 2>&1 | log_module "$module"

    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
      log_error "Migration $module $installed -> $ver FAILED (exit code $rc). Fix the issue and retry."
      return 1
    fi

    echo "$ver" > "$BASE_DIR/store/$module/version"
    installed="$ver"
    log_info "Module $module migrated to $ver."
  done

  # If target is beyond the last migration script, update the version marker
  if version_lt "$installed" "$target"; then
    echo "$target" > "$BASE_DIR/store/$module/version"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# resolve_versioned_script <module> <kind> [version_override]
#
# Finds the correct export or import script for the installed version.
# <kind> is "export" or "import".
# Uses "latest applicable" strategy: highest version <= installed.
#
# Prints the path to the script, or empty string if none found.
# ---------------------------------------------------------------------------
resolve_versioned_script() {
  local module="$1"
  local kind="$2"
  local version="${3:-}"
  local scripts_dir="$BASE_DIR/$module/$kind"

  if [[ -z "$version" ]]; then
    version=$(get_installed_version "$module")
  fi

  if [[ -z "$version" ]]; then
    echo ""
    return 1
  fi

  if [[ ! -d "$scripts_dir" ]]; then
    echo ""
    return 1
  fi

  # List scripts sorted descending by version
  local best=""
  for f in "$scripts_dir"/*.sh; do
    [[ -f "$f" ]] || continue
    local script_ver
    script_ver=$(basename "$f" .sh)
    if version_le "$script_ver" "$version"; then
      if [[ -z "$best" ]] || version_gt "$script_ver" "$best"; then
        best="$script_ver"
      fi
    fi
  done

  if [[ -n "$best" ]]; then
    echo "$scripts_dir/$best.sh"
    return 0
  fi

  echo ""
  return 1
}
