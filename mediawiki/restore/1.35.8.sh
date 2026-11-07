#!/usr/bin/env bash
set -euo pipefail

# Restores one mediawiki instance ($1) from what export/1.35.8.sh wrote.
# store/mediawiki/<id>/ has already been put back.

ID="${1:?mediawiki restore needs an instance id}"
PROJECT="$HABIDAT_DOCKER_PREFIX-mediawiki-$ID"
COMPOSE_FILE="../store/mediawiki/$ID/docker-compose.yml"
COMPOSE=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")
CLIENT='exec "$(command -v mariadb || command -v mysql)" -u root "$@"'

# shellcheck disable=SC1090
source "../store/mediawiki/$ID/passwords.env"

echo "Stopping mediawiki instance $ID..."
"${COMPOSE[@]}" rm --stop --force

restore_volume "${PROJECT}_images" "$PROJECT" images
restore_volume "${PROJECT}_config" "$PROJECT" config

"${COMPOSE[@]}" up -d db
../lib/wait-for.sh "mediawiki $ID database" 300 \
  "docker compose -f '$COMPOSE_FILE' -p '$PROJECT' exec -T \
     -e MYSQL_PWD='$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD' db sh -c '$CLIENT' sh -e 'select 1'"

# The dump was taken with --databases, so it drops and recreates the database.
echo "Loading the database..."
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD" db sh -c "$CLIENT" sh \
  -e 'DROP DATABASE IF EXISTS mediawiki;'
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD" db sh -c "$CLIENT" sh \
  < "$HABIDAT_RESTORE_DIR/db.sql"

"${COMPOSE[@]}" up -d
