#!/usr/bin/env bash
# Module discovery, dependency resolution, lifecycle dispatch.
# Sourced by habidat.sh -- do not execute directly.

# ---------------------------------------------------------------------------
# is_valid_module <name>
# ---------------------------------------------------------------------------
is_valid_module() {
  [[ -d "$BASE_DIR/$1" && -f "$BASE_DIR/$1/version" ]]
}

# ---------------------------------------------------------------------------
# validate_store
#   Checks store/ directory integrity: version files exist, compose files
#   are present, etc. Warns about issues but does not abort.
# ---------------------------------------------------------------------------
validate_store() {
  local warnings=0
  for dir in "$BASE_DIR"/store/*/; do
    [[ -d "$dir" ]] || continue
    local mod
    mod=$(basename "$dir")

    if [[ ! -f "$dir/version" ]]; then
      log_warn "Store warning: $mod has no version file in store/"
      ((warnings++))
    fi

    if [[ ! -f "$dir/docker-compose.yml" ]] && [[ "$mod" != "discourse" ]] && [[ "$mod" != "direktkredit" ]] && [[ "$mod" != "mediawiki" ]]; then
      log_warn "Store warning: $mod has no docker-compose.yml in store/"
      ((warnings++))
    fi

    if ! is_valid_module "$mod"; then
      log_warn "Store warning: $mod is installed but not found as a module in the repo"
      ((warnings++))
    fi
  done

  if [[ $warnings -gt 0 ]]; then
    log_warn "Found $warnings store integrity warning(s). Some operations may fail."
  fi
}

# ---------------------------------------------------------------------------
# is_installed <module>
# ---------------------------------------------------------------------------
is_installed() {
  [[ -d "$BASE_DIR/store/$1" ]]
}

# ---------------------------------------------------------------------------
# get_available_modules
#   Prints all module names (directories with a version file).
# ---------------------------------------------------------------------------
get_available_modules() {
  for dir in "$BASE_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    # Skip non-module directories
    [[ "$name" == "lib" || "$name" == "store" || "$name" == "scripts" || "$name" == ".git" || "$name" == ".github" ]] && continue
    [[ -f "$dir/version" ]] && echo "$name"
  done
}

# ---------------------------------------------------------------------------
# get_module_dependencies <module>
#   Prints dependencies, one per line.
# ---------------------------------------------------------------------------
get_module_dependencies() {
  local depfile="$BASE_DIR/$1/dependencies"
  if [[ -f "$depfile" ]]; then
    cat "$depfile"
  fi
}

# ---------------------------------------------------------------------------
# get_ordered_modules
#   Topological sort of all available modules based on dependencies.
#   Modules with no dependencies come first.
# ---------------------------------------------------------------------------
get_ordered_modules() {
  local -A visited=()
  local order=()

  _topo_visit() {
    local mod="$1"
    [[ -n "${visited[$mod]:-}" ]] && return
    visited[$mod]=1

    local dep
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      dep=$(echo "$dep" | tr -d '[:space:]')
      if is_valid_module "$dep"; then
        _topo_visit "$dep"
      fi
    done < <(get_module_dependencies "$mod")

    order+=("$mod")
  }

  local mod
  for mod in $(get_available_modules | sort); do
    _topo_visit "$mod"
  done

  printf '%s\n' "${order[@]}"
}

# ---------------------------------------------------------------------------
# get_installed_modules
#   Prints installed module names (those with a store/ directory).
# ---------------------------------------------------------------------------
get_installed_modules() {
  for dir in "$BASE_DIR"/store/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    echo "$name"
  done
}

# ---------------------------------------------------------------------------
# list_modules
#   Display module status.
# ---------------------------------------------------------------------------
list_modules() {
  local mod
  for mod in $(get_ordered_modules); do
    if is_installed "$mod"; then
      local ver
      ver=$(get_installed_version "$mod")
      local target
      target=$(get_target_version "$mod")
      if [[ "$ver" == "$target" ]]; then
        log_info "$mod ${_GREEN}[INSTALLED v${ver}]${_RESET}"
      else
        log_info "$mod ${_YELLOW}[INSTALLED v${ver} -> v${target} available]${_RESET}"
      fi
    else
      log_info "$mod ${_YELLOW}[NOT INSTALLED]${_RESET}"
    fi
  done
}

# ---------------------------------------------------------------------------
# check_dependencies <module>
#   Verifies all dependencies are installed. Prompts to install missing ones.
# ---------------------------------------------------------------------------
check_dependencies() {
  local module="$1"
  local depfile="$BASE_DIR/$module/dependencies"

  [[ -f "$depfile" ]] || return 0

  log_info "Checking dependencies for module $module..."

  local missing=()
  while IFS= read -r dep; do
    dep=$(echo "$dep" | tr -d '[:space:]')
    [[ -z "$dep" ]] && continue
    if is_installed "$dep"; then
      log_info "  $dep ${_GREEN}[INSTALLED]${_RESET}"
    else
      log_info "  $dep ${_RED}[NOT INSTALLED]${_RESET}"
      missing+=("$dep")
    fi
  done < "$depfile"

  if [[ ${#missing[@]} -gt 0 ]]; then
    read -p "Missing dependencies: ${missing[*]}. Install them? [y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      die "Please install dependencies first."
    fi
    for dep in "${missing[@]}"; do
      check_dependencies "$dep"
      setup_module "$dep"
    done
  fi
}

# ---------------------------------------------------------------------------
# check_child_dependencies <module>
#   Prevents removal if other installed modules depend on this one.
# ---------------------------------------------------------------------------
check_child_dependencies() {
  local module="$1"
  local has_dependents=false

  log_info "Checking child dependencies for module $module..."

  for dir in "$BASE_DIR"/store/*/; do
    [[ -d "$dir" ]] || continue
    local installed_mod
    installed_mod=$(basename "$dir")
    local depfile="$dir/dependencies"
    [[ -f "$depfile" ]] || continue

    while IFS= read -r dep; do
      dep=$(echo "$dep" | tr -d '[:space:]')
      if [[ "$dep" == "$module" ]]; then
        log_error "  $installed_mod depends on $module ${_RED}[INSTALLED]${_RESET}"
        has_dependents=true
      fi
    done < "$depfile"
  done

  if [[ "$has_dependents" == "true" ]]; then
    die "Please remove dependent modules first."
  fi
}

# ---------------------------------------------------------------------------
# update_installed_modules_env
#   Rebuilds the HABIDAT_USER_INSTALLED_MODULES line in store/auth/auth.env.
# ---------------------------------------------------------------------------
update_installed_modules_env() {
  if [[ ! -d "$BASE_DIR/store/auth" ]]; then
    return 0
  fi

  local modules_csv="nginx,auth"
  for mod in $(get_installed_modules); do
    [[ "$mod" == "nginx" || "$mod" == "auth" ]] && continue
    modules_csv="$modules_csv,$mod"
  done

  local auth_env="$BASE_DIR/store/auth/auth.env"
  touch "$auth_env"
  sed -i '/HABIDAT_USER_INSTALLED_MODULES/d' "$auth_env"
  echo "HABIDAT_USER_INSTALLED_MODULES=$modules_csv" >> "$auth_env"
}

# ---------------------------------------------------------------------------
# Module lifecycle operations
# ---------------------------------------------------------------------------

setup_module() {
  local module="$1"; shift
  log_info "Setting up $module module..."

  check_dependencies "$module"

  (
    cd "$BASE_DIR/$module" || exit 1
    ./setup.sh "$@" 2>&1
  ) | log_module "$module"

  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    log_error "Setup of $module failed (exit code $rc)."
    return 1
  fi

  cp "$BASE_DIR/$module/version" "$BASE_DIR/store/$module/version"
  if [[ -f "$BASE_DIR/$module/dependencies" ]]; then
    cp "$BASE_DIR/$module/dependencies" "$BASE_DIR/store/$module/dependencies"
  fi

  update_installed_modules_env
  log_info "Module $module setup complete."
}

remove_module() {
  local module="$1"; shift

  if ! is_installed "$module"; then
    log_error "Module $module not installed, cannot remove."
    return 1
  fi

  check_child_dependencies "$module"

  read -p "Do you really want to remove module $module? All data will be lost. [y/n] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    return 1
  fi

  log_info "Removing $module module..."

  if [[ -f "$BASE_DIR/$module/remove.sh" ]]; then
    (
      cd "$BASE_DIR/$module" || exit 1
      ./remove.sh "$@" 2>&1
    ) | log_module "$module"
  else
    docker compose -f "$BASE_DIR/store/$module/docker-compose.yml" \
      -p "${HABIDAT_DOCKER_PREFIX}-$module" down -v --remove-orphans 2>&1 | log_module "$module"
    rm -rf "$BASE_DIR/store/$module"
  fi

  update_installed_modules_env
  log_info "Module $module removed."
}

_run_lifecycle() {
  local action="$1"
  local module="$2"
  shift 2

  if ! is_installed "$module"; then
    log_verbose "Module $module not installed, skipping $action."
    return 0
  fi

  log_info "$(upper "$action") $module module..."

  if [[ -f "$BASE_DIR/$module/${action}.sh" ]]; then
    (
      cd "$BASE_DIR/$module" || exit 1
      ./"${action}.sh" "$@" 2>&1
    ) | log_module "$module"
  else
    case "$action" in
      start|stop|restart)
        docker compose -f "$BASE_DIR/store/$module/docker-compose.yml" \
          -p "${HABIDAT_DOCKER_PREFIX}-$module" "$action" 2>&1 | log_module "$module"
        ;;
      up)
        docker compose -f "$BASE_DIR/store/$module/docker-compose.yml" \
          -p "${HABIDAT_DOCKER_PREFIX}-$module" up -d 2>&1 | log_module "$module"
        ;;
      down)
        docker compose -f "$BASE_DIR/store/$module/docker-compose.yml" \
          -p "${HABIDAT_DOCKER_PREFIX}-$module" down 2>&1 | log_module "$module"
        ;;
      pull)
        docker compose -f "$BASE_DIR/store/$module/docker-compose.yml" \
          -p "${HABIDAT_DOCKER_PREFIX}-$module" pull 2>&1 | log_module "$module"
        ;;
      build)
        docker compose -f "$BASE_DIR/store/$module/docker-compose.yml" \
          -p "${HABIDAT_DOCKER_PREFIX}-$module" build 2>&1 | log_module "$module"
        ;;
    esac
  fi
}

start_module()   { _run_lifecycle start "$@"; }
stop_module()    { _run_lifecycle stop "$@"; }
restart_module() { _run_lifecycle restart "$@"; }
up_module()      { _run_lifecycle up "$@"; }
down_module()    { _run_lifecycle down "$@"; }
pull_module()    { _run_lifecycle pull "$@"; }
build_module()   { _run_lifecycle build "$@"; }

update_module() {
  local module="$1"
  local force="${2:-}"

  if ! is_valid_module "$module"; then
    log_error "Module $module unknown. Available: $(get_available_modules | tr '\n' ' ')"
    return 1
  fi

  if ! is_installed "$module"; then
    log_error "Module $module not installed, cannot update."
    return 0
  fi

  run_migrations "$module" "$force"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    update_installed_modules_env
  fi
  return $rc
}

export_module() {
  local module="$1"; shift

  if ! is_valid_module "$module"; then
    log_error "Module $module unknown."
    return 1
  fi

  if ! is_installed "$module"; then
    log_error "Module $module not installed, cannot export."
    return 0
  fi

  local script
  script=$(resolve_versioned_script "$module" "export") || true

  if [[ -z "$script" ]]; then
    log_error "Module $module has no export script for installed version."
    return 0
  fi

  log_info "Exporting $module (using $(basename "$script"))..."
  (
    cd "$BASE_DIR/$module" || exit 1
    # shellcheck disable=SC1090
    bash "$script" "$@" 2>&1
  ) | log_module "$module"

  log_info "Export of $module complete."
}

import_module() {
  local module="$1"
  local filename="${2:-}"

  if ! is_valid_module "$module"; then
    log_error "Module $module unknown."
    return 1
  fi

  if ! is_installed "$module"; then
    log_error "Module $module not installed, cannot import."
    return 0
  fi

  local script
  script=$(resolve_versioned_script "$module" "import") || true

  if [[ -z "$script" ]]; then
    log_error "Module $module has no import script for installed version."
    return 0
  fi

  if [[ "$filename" == "list" ]]; then
    echo "Available import files for $module:"
    ls -ltr "${HABIDAT_BACKUP_DIR:-./backup}/${HABIDAT_DOCKER_PREFIX:-habidat}/$module" 2>/dev/null || echo "  (none)"
    return 0
  fi

  if [[ -z "$filename" ]]; then
    die "Usage: habidat.sh import <module> <filename>|list"
  fi

  local backup_dir="${HABIDAT_BACKUP_DIR:-./backup}/${HABIDAT_DOCKER_PREFIX:-habidat}/$module"
  if [[ ! -f "$backup_dir/$filename" ]]; then
    log_error "Import file $filename not found."
    echo "Available files:"
    ls -ltr "$backup_dir" 2>/dev/null || echo "  (none)"
    return 1
  fi

  log_info "Importing $module from $filename (using $(basename "$script"))..."
  (
    cd "$BASE_DIR/$module" || exit 1
    # shellcheck disable=SC1090
    bash "$script" "$filename" 2>&1
  ) | log_module "$module"

  log_info "Import of $module complete."
}

# ---------------------------------------------------------------------------
# dispatch <action> <module|all> [args...]
#
# Generic dispatcher for module operations.
# ---------------------------------------------------------------------------
dispatch() {
  local action="$1"
  local target="${2:-}"
  shift 2 || true

  if [[ -z "$target" ]]; then
    die "Usage: habidat.sh $action <module>|all [options]"
  fi

  case "$action" in
    install)
      if [[ "$target" == "all" ]]; then
        local mod
        for mod in $(get_ordered_modules); do
          if is_installed "$mod" && [[ "${1:-}" != "force" ]]; then
            log_info "Module $mod already installed, skipping."
            continue
          fi
          setup_module "$mod" "$@"
        done
        print_admin_credentials
      else
        is_valid_module "$target" || die "Unknown module: $target"
        if is_installed "$target" && [[ "${1:-}" != "force" ]]; then
          die "Module $target already installed. Use force to reinstall, or remove first."
        fi
        if [[ "${1:-}" == "force" ]]; then
          log_info "Force reinstall $target, removing old installation..."
          docker compose -f "$BASE_DIR/store/$target/docker-compose.yml" \
            -p "${HABIDAT_DOCKER_PREFIX}-$target" down -v --remove-orphans 2>&1 | log_module "$target" || true
          rm -rf "$BASE_DIR/store/$target"
          shift
        fi
        setup_module "$target" "$@"
        print_admin_credentials
      fi
      ;;

    remove)
      is_valid_module "$target" || die "Unknown module: $target"
      remove_module "$target" "$@"
      ;;

    update)
      if [[ "$target" == "all" ]]; then
        local mod
        local had_error=false
        for mod in $(get_ordered_modules); do
          if ! is_installed "$mod"; then
            continue
          fi
          update_module "$mod" "$@" || {
            log_error "Update of $mod failed. Continuing with remaining modules..."
            had_error=true
          }
        done
        if [[ "$had_error" == "true" ]]; then
          log_error "Some modules failed to update. Check the output above."
          return 1
        fi
      else
        is_valid_module "$target" || die "Unknown module: $target"
        update_module "$target" "$@"
      fi
      ;;

    export)
      if [[ "$target" == "all" ]]; then
        local mod
        for mod in $(get_ordered_modules); do
          is_installed "$mod" && export_module "$mod" "$@" || true
        done
      else
        is_valid_module "$target" || die "Unknown module: $target"
        export_module "$target" "$@"
      fi
      ;;

    import)
      [[ "$target" == "all" ]] && die "Import can only be done per module."
      is_valid_module "$target" || die "Unknown module: $target"
      import_module "$target" "$@"
      ;;

    start|stop|restart|up|down|pull|build)
      if [[ "$target" == "all" ]]; then
        local mod
        for mod in $(get_ordered_modules); do
          "${action}_module" "$mod" "$@"
        done
      else
        is_valid_module "$target" || die "Unknown module: $target"
        "${action}_module" "$target" "$@"
      fi
      ;;

    *)
      die "Unknown action: $action"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# print_admin_credentials
# ---------------------------------------------------------------------------
print_admin_credentials() {
  if [[ -f "$BASE_DIR/store/auth/passwords.env" ]]; then
    # shellcheck disable=SC1091
    source "$BASE_DIR/store/auth/passwords.env"
    log_info "Admin credentials: username ${_BOLD}${HABIDAT_ADMIN_EMAIL:-not set}${_RESET}, password ${_BOLD}${HABIDAT_ADMIN_PASSWORD:-unknown}${_RESET}"
  fi
}
