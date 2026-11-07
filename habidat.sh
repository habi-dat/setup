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
# shellcheck source=lib/export.sh
source "$SCRIPT_DIR/lib/export.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/security.sh
source "$SCRIPT_DIR/lib/security.sh"

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
# On a fresh server these run before a restore has put setup.env back (ADR 0006).
# `restore` checks for setup.env itself once it knows where it comes from.
case "${1:-} ${2:-}" in
  "install backup" | "configure backup" | "snapshots "* | "restore "* | "backup check" | "backup status")
    check_prerequisites --no-setup-env
    ;;
  *)
    check_prerequisites
    ;;
esac
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
  log_info "  update  <module>|all [version] [force]         Update module or all modules"
  log_info "  fix     <module>|all                           Pull images and recreate containers (no migration)"
  log_info "  pull    <module>|all                           Pull Docker images"
  log_info "  build   <module>|all                           Build Docker images"
  log_info "  link    <module>|all [instance]                Rewrite what a module contributes to other modules"
  log_info "  configure <module> [args]                      Run a module's post-install configuration"
  log_info "  modules                                        List module status"
  log_info "  security-check [all|<module> [<instance>]] [options]"
  log_info "                                                 Read-only security check (see security-check --help)"
  log_info ""
  log_info "Backup and restore:"
  log_info "  backup [run]                                   Take a snapshot now"
  log_info "  backup check [--full]                          Check the backup repository (--full reads all data)"
  log_info "  backup status                                  Show the last snapshot and the repository"
  log_info "  snapshots [module [instance]]                  List snapshots (with a module: those that contain it)"
  log_info "  restore <module>|all [instance] <snapshot>     Restore from a snapshot ('latest' for the newest)"
  log_info "  restore <module> [instance] --file <file>      Restore from an export file"
  log_info "  export  <module>|all [instance]                Write module data to an export file"
  log_info "  import  <module> <filename>|list               Deprecated: restore <module> --file <file>"
  log_info ""
}

# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  install|remove|start|stop|restart|up|down|update|fix|pull|build|export|import|configure|link)
    dispatch "$1" "${@:2}"
    ;;
  backup)
    backup_cmd "${@:2}"
    ;;
  snapshots)
    snapshots_cmd "${@:2}"
    ;;
  restore)
    restore_cmd "${@:2}"
    ;;
  modules)
    list_modules
    ;;
  security-check)
    security_check "${@:2}"
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
