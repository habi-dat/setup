#!/usr/bin/env bash
set -euo pipefail

# Restores one listmonk instance ($1) from what export/6.2.0.sh wrote.
# store/listmonk/<id>/ (config, passwords, API token) has already been put back.

# shellcheck source=../lib/common.sh
source lib/common.sh

ID="${1:?listmonk restore needs an instance id}"
COMPOSE_FILE="$(listmonk_compose "$ID")"
PROJECT="$(listmonk_project "$ID")"
COMPOSE=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")

echo "Stopping listmonk instance $ID..."
"${COMPOSE[@]}" rm --stop --force

restore_volume "${PROJECT}_uploads" "$PROJECT" uploads

"${COMPOSE[@]}" up -d db
../lib/wait-for.sh "listmonk $ID database" 180 \
  "docker compose -f '$COMPOSE_FILE' -p '$PROJECT' exec -T db pg_isready -U listmonk"

echo "Loading the database..."
"${COMPOSE[@]}" exec -T db psql -U listmonk -d postgres -v ON_ERROR_STOP=1 -q \
  < "$HABIDAT_RESTORE_DIR/db.sql"

"${COMPOSE[@]}" up -d
