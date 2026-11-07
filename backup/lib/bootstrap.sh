#!/usr/bin/env bash
# Loads the habidat libraries for the backup module's executable scripts
# (setup.sh, configure.sh, the lifecycle scripts). Sourced, not executed.
# Scripts that are themselves sourced by habidat.sh (migrate.sh) have the
# libraries already and source lib/timers.sh only.

_backup_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$_backup_lib_dir/../.." && pwd)"
export BASE_DIR

# shellcheck source=../../lib/common.sh
source "$BASE_DIR/lib/common.sh"
# shellcheck source=../../lib/template.sh
source "$BASE_DIR/lib/template.sh"
# shellcheck source=../../lib/version.sh
source "$BASE_DIR/lib/version.sh"
# shellcheck source=../../lib/modules.sh
source "$BASE_DIR/lib/modules.sh"
# shellcheck source=../../lib/export.sh
source "$BASE_DIR/lib/export.sh"
# shellcheck source=../../lib/backup.sh
source "$BASE_DIR/lib/backup.sh"
# shellcheck source=timers.sh
source "$_backup_lib_dir/timers.sh"
