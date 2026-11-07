#!/usr/bin/env bash
set -euo pipefail

# Removes the timers and store/backup/. The backup repository and its snapshots
# stay where they are; reading them needs the passphrase shown at configure.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh

backup_remove_timers
rm -rf "$BACKUP_STORE"
echo "Removed the backup module. The snapshots in the backup repository were not touched."
