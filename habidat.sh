#!/usr/bin/env bash
# habidat-setup CLI -- thin dispatcher.
# All logic lives in lib/*.sh; this file handles argument parsing and dispatch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/modules.sh
source "$SCRIPT_DIR/lib/modules.sh"

# ---------------------------------------------------------------------------
# Parse global flags (before the command)
# ---------------------------------------------------------------------------
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help)    shift; set -- help ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
load_setup_env
check_prerequisites
validate_store

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  log_info "Usage: habidat.sh [--verbose] [--dry-run] ${_UNDERLINE}COMMAND${_RESET}"
  log_info ""
  log_info "Commands:"
  log_info "  help                                           Show this help"
  log_info "  install <module>|all [force]                   Install module or all modules"
  log_info "  remove  <module> [force]                        Remove module (caution: all data is lost)"
  log_info "  start   <module>|all                           Start module or all modules"
  log_info "  restart <module>|all                           Restart module or all modules"
  log_info "  stop    <module>|all                           Stop module or all modules"
  log_info "  up      <module>|all                           Up module or all modules (create + start)"
  log_info "  down    <module>|all                           Down module or all modules (stop + remove containers)"
  log_info "  update  <module>|all [force]                   Update module or all modules"
  log_info "  pull    <module>|all                           Pull Docker images"
  log_info "  build   <module>|all                           Build Docker images"
  log_info "  export  <module>|all [options]                 Export module data"
  log_info "  import  <module> <filename>|list               Import module data"
  log_info "  modules                                        List module status"
  log_info ""
}

# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  install|remove|start|stop|restart|up|down|update|pull|build|export|import)
    dispatch "$1" "${@:2}"
    ;;
  modules)
    list_modules
    ;;
  help)
    usage
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    log_error "Unknown command: $1"
    usage
    exit 1
    ;;
esac
