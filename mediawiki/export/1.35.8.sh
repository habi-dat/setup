#!/usr/bin/env bash
set -euo pipefail

# Exports one mediawiki instance ($1): dumps its database and names the images
# and config volumes. See lib/export.sh for the contract.

ID="${1:?mediawiki export needs an instance id}"
PROJECT="$HABIDAT_DOCKER_PREFIX-mediawiki-$ID"
COMPOSE=(docker compose -f "../store/mediawiki/$ID/docker-compose.yml" -p "$PROJECT")

# shellcheck disable=SC1090
source "../store/mediawiki/$ID/passwords.env"

# The image is an unpinned `mariadb`: newer ones only ship mariadb-dump, older
# ones only mysqldump.
echo "Dumping the database of mediawiki instance $ID..."
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD" db sh -c \
  'exec "$(command -v mariadb-dump || command -v mysqldump)" --single-transaction -u root --databases mediawiki' \
  > "$HABIDAT_EXPORT_DIR/db.sql"

export_volume "${PROJECT}_images"
export_volume "${PROJECT}_config"
