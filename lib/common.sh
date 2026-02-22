#!/usr/bin/env bash
# Shared utilities: logging, colors, error handling, prerequisites.
# Sourced by habidat.sh -- do not execute directly.

set -euo pipefail
IFS=$'\n\t'

readonly BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

# ---------------------------------------------------------------------------
# Colors & formatting (graceful fallback when tput is unavailable)
# ---------------------------------------------------------------------------
if command -v tput >/dev/null 2>&1 && tput sgr0 >/dev/null 2>&1; then
  readonly _RED=$(tput setaf 1)
  readonly _GREEN=$(tput setaf 2)
  readonly _YELLOW=$(tput setaf 3)
  readonly _MAGENTA=$(tput setaf 5)
  readonly _BOLD=$(tput bold)
  readonly _RESET=$(tput sgr0)
  readonly _UNDERLINE=$(tput smul)
else
  readonly _RED="" _GREEN="" _YELLOW="" _MAGENTA="" _BOLD="" _RESET="" _UNDERLINE=""
fi

# ---------------------------------------------------------------------------
# Global flags (can be overridden before sourcing or via CLI args)
# ---------------------------------------------------------------------------
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log_prefix() {
  local label="${1:-HABIDAT}"
  local color="${2:-$_GREEN}"
  printf "%s" "${color}${_BOLD}$(printf '%-12s' "$label")${_RESET}| "
}

log_info() {
  local prefix
  prefix="$(_log_prefix "${HABIDAT_TITLE:-HABIDAT}" "$_GREEN")"
  echo "$1" | sed -u "s/^/$prefix/"
}

log_error() {
  local prefix
  prefix="$(_log_prefix "${HABIDAT_TITLE:-HABIDAT}" "$_RED")"
  echo "$1" | sed -u "s/^/$prefix/" >&2
}

log_warn() {
  local prefix
  prefix="$(_log_prefix "${HABIDAT_TITLE:-HABIDAT}" "$_YELLOW")"
  echo "$1" | sed -u "s/^/$prefix/"
}

log_module() {
  local mod="$1"; shift
  local label
  label="$(echo "$mod" | tr '[:lower:]' '[:upper:]')"
  local prefix
  prefix="$(_log_prefix "$label" "$_MAGENTA")"
  sed -u -l 1 "s/^/$prefix/"
}

log_verbose() {
  [[ "$VERBOSE" == "true" ]] && log_info "$1" || true
}

die() {
  log_error "${1:-Unknown error}"
  exit 1
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
_cleanup_hooks=()

register_cleanup() {
  _cleanup_hooks+=("$1")
}

_run_cleanup() {
  local exit_code=$?
  for hook in "${_cleanup_hooks[@]+"${_cleanup_hooks[@]}"}"; do
    eval "$hook" 2>/dev/null || true
  done
  exit "$exit_code"
}

trap _run_cleanup EXIT ERR INT TERM

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin is not installed"
  command -v j2 >/dev/null 2>&1 || die "j2cli is not installed (pip install j2cli)"
  [[ -f "$BASE_DIR/setup.env" ]] || die "setup.env not found in $BASE_DIR"
}

# ---------------------------------------------------------------------------
# Source setup.env safely
# ---------------------------------------------------------------------------
load_setup_env() {
  if [[ -f "$BASE_DIR/setup.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$BASE_DIR/setup.env"
    set +a
  fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
upper() {
  printf "%s" "$1" | tr '[:lower:]' '[:upper:]'
}
