#!/usr/bin/env bash
set -euo pipefail

# Exports one listmonk instance ($1): dumps its database as the listmonk role
# (the instance has no postgres role) and names the uploads volume. See
# lib/export.sh for the contract.

# shellcheck source=../lib/common.sh
source lib/common.sh

ID="${1:?listmonk export needs an instance id}"
COMPOSE=(docker compose -f "$(listmonk_compose "$ID")" -p "$(listmonk_project "$ID")")

echo "Dumping the database of listmonk instance $ID..."
"${COMPOSE[@]}" exec -T db \
  pg_dump -U listmonk --clean --if-exists --create listmonk > "$HABIDAT_EXPORT_DIR/db.sql"

export_volume "$(listmonk_project "$ID")_uploads"
