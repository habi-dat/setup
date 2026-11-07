#!/usr/bin/env bash
set -euo pipefail

# Dumps the database in maintenance mode and names the data volume, which holds
# config/config.php, the installed apps and every user's files. See
# lib/export.sh for the contract. mariadb-dump exists in every MariaDB image
# nextcloud has used (10.6 and 11.8).

COMPOSE=(docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud")

# shellcheck disable=SC1091
source ../store/nextcloud/passwords.env

occ() {
  "${COMPOSE[@]}" exec -T --user www-data nextcloud php occ "$@"
}

echo "Enabling maintenance mode..."
occ maintenance:mode --on
maintenance=on
register_cleanup '[[ "$maintenance" != on ]] || occ maintenance:mode --off'

echo "Dumping the database..."
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" db \
  mariadb-dump --single-transaction --default-character-set=utf8mb4 -u root nextcloud \
  > "$HABIDAT_EXPORT_DIR/db.sql"

echo "Disabling maintenance mode..."
occ maintenance:mode --off
maintenance=off

export_volume "$HABIDAT_DOCKER_PREFIX-nextcloud_data"
