#!/usr/bin/env bash
set -euo pipefail

# Rebuilds the borg image and, once the repository is set up, re-renders the
# systemd units for this version.

# shellcheck source=../../lib/timers.sh
source lib/timers.sh

backup_build_image
if backup_is_configured; then
  backup_install_timers "$HABIDAT_MIGRATE_VERSION"
fi
