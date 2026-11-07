#!/usr/bin/env bash
set -euo pipefail

# Takes an online copy of the SQLite database while Vaultwarden keeps running,
# and names the data volume (RSA keys, attachments, sends, config.json) and the
# sync state volume. See lib/export.sh for the contract.

PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"

echo "Copying the Vaultwarden database..."
export_sqlite "${PROJECT}_data" db.sqlite3 db.sqlite3

export_volume "${PROJECT}_data"
export_volume "${PROJECT}_sync-state"
