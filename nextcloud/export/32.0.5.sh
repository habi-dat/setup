#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud"
COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"
NC_CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud"
DB_CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud-db"
DATA_ROOT="/var/www/html/data"

if [[ -z "${1:-}" ]]; then
  echo "Exporting nextcloud with user data (use option 'nodata' for excluding user data)..."
elif [[ "$1" == "nodata" ]]; then
  echo "Exporting nextcloud without user data"
else
  echo "Invalid option, available options: nodata"
  exit 0
fi

mkdir -p "$BACKUP_DIR"

source ../store/nextcloud/passwords.env

echo "Exporting database..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec db bash -c \
  "mysqldump nextcloud -u root --password=$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD > /backup.sql"
DATE=$(date +"%Y%m%d%H%M")
docker cp "$DB_CONTAINER":/backup.sql "$BACKUP_DIR/db.sql"

STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT

cp "$BACKUP_DIR/db.sql" "$STAGING_DIR/db.sql"
rm "$BACKUP_DIR/db.sql"

echo "Copying data from container..."
if [[ -z "${1:-}" ]]; then
  docker cp "$NC_CONTAINER":"$DATA_ROOT" "$STAGING_DIR/data"
else
  appdata_dir=$(docker exec "$NC_CONTAINER" bash -c "basename \$(ls -d $DATA_ROOT/appdata_*)")
  mkdir -p "$STAGING_DIR/data/$appdata_dir"
  docker cp "$NC_CONTAINER":"$DATA_ROOT/$appdata_dir/theming" "$STAGING_DIR/data/$appdata_dir/theming"
  docker cp "$NC_CONTAINER":"$DATA_ROOT/$appdata_dir/external" "$STAGING_DIR/data/$appdata_dir/external"
fi

echo "Compressing data..."
tar -czf "$BACKUP_DIR/nextcloud-$DATE.tar.gz" -C "$STAGING_DIR" db.sql data

echo "Finished, filename: $BACKUP_DIR/nextcloud-$DATE.tar.gz"
