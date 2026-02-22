#!/usr/bin/env bash
set -euo pipefail

echo "Stopping nextcloud..."
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" stop nextcloud cron

datapath=$(docker volume inspect -f "{{.Mountpoint}}" "$HABIDAT_DOCKER_PREFIX-nextcloud_data")

echo "Deleting existing data..."
appdata_dir=$(basename "$(ls -d "$datapath"/data/appdata_*)")
rm -rf "$datapath/data"

echo "Extracting data..."
tar -xzf "$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/nextcloud/$1" -C "$datapath"

appdata_dir_import=$(basename "$(ls -d "$datapath"/data/appdata_*)")
if [[ "$appdata_dir_import" != "$appdata_dir" ]]; then
  mv "$datapath/data/$appdata_dir_import" "$datapath/data/$appdata_dir"
fi

chown -R www-data:www-data "$datapath/data"

echo "Restoring database dump..."
source ../store/nextcloud/passwords.env
cat "$datapath/db.sql" | docker exec -i "$HABIDAT_DOCKER_PREFIX-nextcloud-db" mysql nextcloud -u root --password="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD"
rm "$datapath/db.sql"

echo "Running post-import update..."
# Run the migration for the currently installed version to bring containers up
source ../store/nginx/networks.env
source ../store/auth/passwords.env

render_versioned_template nextcloud "$(cat ../store/nextcloud/version)" \
  docker-compose.yml.j2 ../store/nextcloud/docker-compose.yml

docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" pull
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d

echo "Waiting for containers to start (2 minutes)..."
sleep 120

docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat-afterupdate.sh

echo "Finished, imported: $1"
