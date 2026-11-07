#!/usr/bin/env bash
set -euo pipefail

# Restores what export/32.0.5.sh wrote. store/nextcloud/ (compose file,
# passwords, assets) has already been put back.

PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"
COMPOSE_FILE=../store/nextcloud/docker-compose.yml
COMPOSE=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")

# shellcheck disable=SC1091
source ../store/nextcloud/passwords.env

echo "Stopping nextcloud..."
"${COMPOSE[@]}" rm --stop --force

restore_volume "${PROJECT}_data" "$PROJECT" data

"${COMPOSE[@]}" up -d db
../lib/wait-for.sh "Nextcloud database" 300 \
  "docker compose -f '$COMPOSE_FILE' -p '$PROJECT' exec -T \
     -e MYSQL_PWD='$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD' db mariadb -u root -e 'select 1'"

# Recreated rather than overwritten, so no table from after the snapshot stays.
echo "Loading the database..."
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" db mariadb -u root \
  -e 'DROP DATABASE IF EXISTS nextcloud; CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;'
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" db mariadb -u root nextcloud \
  < "$HABIDAT_RESTORE_DIR/db.sql"

"${COMPOSE[@]}" up -d
../lib/wait-for.sh "Nextcloud" 900 \
  "docker compose -f '$COMPOSE_FILE' -p '$PROJECT' exec -T --user www-data \
     nextcloud php occ status | grep -q 'installed: true'"

"${COMPOSE[@]}" exec -T --user www-data nextcloud php occ maintenance:mode --off
# Tells sync clients that the server went back in time, so they do not delete
# files the restore brought back or upload stale ones silently.
"${COMPOSE[@]}" exec -T --user www-data nextcloud php occ maintenance:data-fingerprint
