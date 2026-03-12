#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud"
COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"
NC_CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud"
DB_CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud-db"
DATA_ROOT="/var/www/html/data"

STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "Extracting archive..."
tar -xzf "$BACKUP_DIR/$1" -C "$STAGING_DIR"

# Detect nodata export: data/ contains only appdata_* (no user directories)
nodata=false
non_appdata=$(find "$STAGING_DIR/data" -maxdepth 1 -mindepth 1 -not -name 'appdata_*' -not -name '.ocdata' -not -name '.htaccess' | head -1)
if [[ -z "$non_appdata" ]]; then
  nodata=true
  echo "Detected nodata export (appdata only), preserving existing user data..."
else
  echo "Detected full export with user data..."
fi

echo "Enabling maintenance mode..."
docker exec --user www-data "$NC_CONTAINER" php occ maintenance:mode --on

appdata_dir=$(docker exec "$NC_CONTAINER" bash -c "basename \$(ls -d $DATA_ROOT/appdata_*)" 2>/dev/null || true)

if [[ "$nodata" == "true" ]]; then
  # Only replace appdata (theming/external), keep user data intact
  appdata_dir_import=$(basename "$(ls -d "$STAGING_DIR"/data/appdata_*)")

  if [[ -n "$appdata_dir" ]]; then
    if [[ -d "$STAGING_DIR/data/$appdata_dir_import/theming" ]]; then
      docker exec "$NC_CONTAINER" rm -rf "$DATA_ROOT/$appdata_dir/theming"
      docker cp "$STAGING_DIR/data/$appdata_dir_import/theming" "$NC_CONTAINER":"$DATA_ROOT/$appdata_dir/theming"
    fi
    if [[ -d "$STAGING_DIR/data/$appdata_dir_import/external" ]]; then
      docker exec "$NC_CONTAINER" rm -rf "$DATA_ROOT/$appdata_dir/external"
      docker cp "$STAGING_DIR/data/$appdata_dir_import/external" "$NC_CONTAINER":"$DATA_ROOT/$appdata_dir/external"
    fi
    docker exec "$NC_CONTAINER" chown -R www-data:www-data "$DATA_ROOT/$appdata_dir"
  fi
else
  echo "Deleting existing data..."
  docker exec "$NC_CONTAINER" rm -rf "$DATA_ROOT"

  echo "Copying data into container..."
  docker cp "$STAGING_DIR/data" "$NC_CONTAINER":"$DATA_ROOT"

  if [[ -n "$appdata_dir" ]]; then
    appdata_dir_import=$(docker exec "$NC_CONTAINER" bash -c "basename \$(ls -d $DATA_ROOT/appdata_*)" 2>/dev/null || true)
    if [[ -n "$appdata_dir_import" && "$appdata_dir_import" != "$appdata_dir" ]]; then
      docker exec "$NC_CONTAINER" mv "$DATA_ROOT/$appdata_dir_import" "$DATA_ROOT/$appdata_dir"
    fi
  fi

  docker exec "$NC_CONTAINER" chown -R www-data:www-data "$DATA_ROOT"
fi

echo "Restoring database dump..."
source ../store/nextcloud/passwords.env
docker exec -i "$DB_CONTAINER" mysql nextcloud -u root --password="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" < "$STAGING_DIR/db.sql"

echo "Running post-import update..."
source ../store/nginx/networks.env
source ../store/auth/passwords.env

render_versioned_template nextcloud "$(cat ../store/nextcloud/version)" \
  docker-compose.yml.j2 ../store/nextcloud/docker-compose.yml

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

echo "Waiting for containers to start (2 minutes)..."
sleep 120

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ maintenance:mode --off
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat-afterupdate.sh

echo "Finished, imported: $1"
