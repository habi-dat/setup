#!/usr/bin/env bash
# Shared utilities: logging, colors, error handling, prerequisites.
# Sourced by habidat.sh -- do not execute directly.

set -euo pipefail
IFS=$'\n\t'

# Repository root. Defaults to the directory of the script that sourced us
# (habidat.sh), but an already-set BASE_DIR wins so tests can point the
# libraries at a fixture tree.
if [[ -z "${BASE_DIR:-}" ]]; then
  BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
fi
readonly BASE_DIR

# ---------------------------------------------------------------------------
# Colors & formatting (graceful fallback when tput is unavailable)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2155  # tput failure is already gated by the condition
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
  # Suppress docker pull/extract progress spam (each update becomes a line when stdout is not a TTY)
  while IFS= read -r line; do
    [[ "$line" =~ Downloading\ \[|Extracting\ [0-9]+\ s ]] && continue
    printf '%s%s\n' "$prefix" "$line"
  done
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
  # Templates are rendered by lib/render.py, which needs Python and Jinja2.
  # Checked by running it rather than by testing for the interpreter, so a
  # missing Jinja2 is reported here instead of partway through an install.
  local renderer="${BASH_SOURCE[0]%/*}/render.py"
  [[ -x "$renderer" ]] || die "lib/render.py is missing or not executable"
  "$renderer" --help >/dev/null 2>&1 || die "$("$renderer" --help 2>&1 | tail -n3)"
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

# ---------------------------------------------------------------------------
# run_module_script <module> <script> [args...]
#
# Runs a script that needs the lib/ helpers (a migration, export or import
# script) in its own bash process, with the module directory as cwd.
#
# It must be a separate process, not a subshell. Callers that test our return
# value -- `update_module ... || { ... }` in dispatch() -- put us in a context
# where bash ignores errexit, and the manual is explicit that a compound command
# running in such a context cannot restore it:
#
#   "If a compound command or shell function executes in a context where -e is
#    being ignored, none of the commands executed within [it] will be affected by
#    the -e setting [...] If a compound command or shell function sets -e while
#    executing in a context where -e is ignored, that setting will not have any
#    effect until the compound command [...] completes."
#
# So a `( source migrate.sh )` subshell would run straight past a failed command
# despite migrate.sh's own `set -euo pipefail`, and then exit with the status of
# its *last* command -- reporting success for a half-applied migration. A fresh
# process starts with its own shell options and cannot inherit that suppression.
# ---------------------------------------------------------------------------
run_module_script() {
  local module="$1"
  local script="$2"
  shift 2

  # `env` rather than a prefix assignment: BASE_DIR is readonly in this shell,
  # and bash rejects an assignment prefix naming a readonly variable.
  env BASE_DIR="$BASE_DIR" DRY_RUN="$DRY_RUN" VERBOSE="$VERBOSE" \
    bash -c '
      set -euo pipefail
      # shellcheck source=/dev/null
      source "$BASE_DIR/lib/common.sh"
      source "$BASE_DIR/lib/template.sh"
      source "$BASE_DIR/lib/version.sh"
      source "$BASE_DIR/lib/modules.sh"

      module="$1"
      script="$2"
      shift 2

      cd "$BASE_DIR/$module" || exit 1
      # shellcheck source=/dev/null
      source "$script" "$@"
    ' habidat-module-script "$module" "$script" "$@"
}

# ---------------------------------------------------------------------------
# run_logged <module> <command...>
#
# Runs a command with its output prefixed by the module label, and returns the
# command's own exit status.
#
# The `|| true` is what keeps the caller alive long enough to report the failure:
# without it the failing pipeline trips this script's `set -e` and the shell
# exits before the diagnostic is printed. Correctness does not depend on errexit
# here, because the status comes from PIPESTATUS.
# ---------------------------------------------------------------------------
run_logged() {
  local module="$1"; shift
  local rc=0

  { "$@" 2>&1 | log_module "$module"; rc=${PIPESTATUS[0]}; } || true

  return "$rc"
}

# ---------------------------------------------------------------------------
# run_module_executable <module> <script-name> [args...]
#
# Runs ./<script-name> from the module directory with its output labelled, and
# returns the script's exit status.
#
# Unlike run_module_script this uses a subshell: these scripts are executed, not
# sourced, so the subshell's exit status is the script's own and does not depend
# on errexit being active. Uses `cd` in a subshell rather than `env -C` to stay
# portable to older coreutils.
# ---------------------------------------------------------------------------
run_module_executable() {
  local module="$1"
  local script="$2"
  shift 2
  local rc=0

  {
    (
      cd "$BASE_DIR/$module" || exit 1
      "./$script" "$@" 2>&1
    ) | log_module "$module"
    rc=${PIPESTATUS[0]}
  } || true

  return "$rc"
}
