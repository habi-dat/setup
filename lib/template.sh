#!/usr/bin/env bash
# Template rendering with version-aware resolution.
# Sourced by habidat.sh -- do not execute directly.

# ---------------------------------------------------------------------------
# resolve_template <module> <version> <relative-path>
#
# Finds the correct template file for a given module version.
# 1. Check <module>/versions/<version>/<relative-path>
# 2. Walk backwards through earlier version dirs
# 3. Never falls back to <module>/<relative-path> (that is for setup.sh only)
#
# Prints the absolute path to the resolved template.
# Returns 1 if not found.
# ---------------------------------------------------------------------------
resolve_template() {
  local module="$1"
  local target_version="$2"
  local rel_path="$3"
  local module_dir="$BASE_DIR/$module"
  local versions_dir="$module_dir/versions"

  if [[ ! -d "$versions_dir" ]]; then
    echo ""
    return 1
  fi

  # Collect version dirs sorted descending, filter to <= target_version
  local candidates
  candidates=$(
    for d in "$versions_dir"/*/; do
      [[ -d "$d" ]] || continue
      basename "$d"
    done | sort -rV
  )

  for ver in $candidates; do
    # Skip versions newer than target
    if [[ "$(printf '%s\n%s' "$ver" "$target_version" | sort -V | tail -n1)" != "$target_version" ]]; then
      continue
    fi
    # version must be <= target_version
    local candidate="$versions_dir/$ver/$rel_path"
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo ""
  return 1
}

# ---------------------------------------------------------------------------
# render_template <template_path> <output_path>
#
# Renders a template to an output file.
# If the template has a .j2 extension, uses j2cli.
# Otherwise falls back to envsubst (for backward compat with old versions/).
# ---------------------------------------------------------------------------
render_template() {
  local template="$1"
  local output="$2"

  if [[ ! -f "$template" ]]; then
    die "Template not found: $template"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would render $template -> $output"
    return 0
  fi

  mkdir -p "$(dirname "$output")"

  if [[ "$template" == *.j2 ]]; then
    j2 "$template" -o "$output"
  else
    envsubst < "$template" > "$output"
  fi
}

# ---------------------------------------------------------------------------
# render_versioned_template <module> <version> <rel_path> <output_path>
#
# Convenience: resolves then renders.
# Used inside migrate.sh scripts.
# ---------------------------------------------------------------------------
render_versioned_template() {
  local module="$1"
  local version="$2"
  local rel_path="$3"
  local output="$4"

  local resolved
  resolved=$(resolve_template "$module" "$version" "$rel_path") || \
    die "Template '$rel_path' not found for $module version $version"

  render_template "$resolved" "$output"
}

# ---------------------------------------------------------------------------
# copy_versioned_file <module> <version> <rel_path> <output_path>
#
# Like render_versioned_template but copies without rendering.
# ---------------------------------------------------------------------------
copy_versioned_file() {
  local module="$1"
  local version="$2"
  local rel_path="$3"
  local output="$4"

  local resolved
  resolved=$(resolve_template "$module" "$version" "$rel_path") || \
    die "File '$rel_path' not found for $module version $version"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would copy $resolved -> $output"
    return 0
  fi

  mkdir -p "$(dirname "$output")"
  cp "$resolved" "$output"
}

# ---------------------------------------------------------------------------
# remove_store_file <path>
#
# Safely remove a file from the store.
# ---------------------------------------------------------------------------
remove_store_file() {
  local path="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would remove $path"
    return 0
  fi
  rm -f "$path"
}
