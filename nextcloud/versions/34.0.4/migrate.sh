#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"
DB_CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud-db"

echo "Copying assets to store..."
rm -rf ../store/nextcloud/assets
cp -r assets ../store/nextcloud/assets
chmod +x ../store/nextcloud/assets/habidat-bootstrap.sh
chmod +x ../store/nextcloud/assets/habidat-afterupdate.sh
chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh

render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 "$COMPOSE_FILE"

# Database tuning, mounted into the db container by the compose file above.
# Rendering it here means it is re-created on every update instead of being
# lost when the compose file is overwritten.
render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  config/mariadb.cnf.j2 ../store/nextcloud/mariadb.cnf

# ---------------------------------------------------------------------------
# MariaDB 10.6 -> 11.8
#
# 10.6 is end of life since 2026-07-06, 11.8 is the version recommended by
# nextcloud 34. The upgrade happens in place: MARIADB_AUTO_UPGRADE=1 in the
# compose file makes the entrypoint run mariadb-upgrade on the existing data
# directory. This requires a clean InnoDB shutdown of the old version first,
# so the stack is stopped explicitly with a long timeout instead of letting
# "up -d" recreate the container with the default 10s grace period.
#
# There is no supported downgrade after mariadb-upgrade. Snapshot the
# "<prefix>-nextcloud_db" docker volume before running this migration.
# ---------------------------------------------------------------------------
echo "Stopping containers for the database upgrade (graceful, up to 5 minutes)..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" stop -t 300 nextcloud cron db

echo "Pulling images and recreating containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

echo "Waiting for the database to finish mariadb-upgrade..."
for i in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "unknown")
  if [[ "$status" == "healthy" ]]; then
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "Database did not become healthy within 10 minutes (status: $status)."
    echo "Check 'docker logs $DB_CONTAINER' before retrying the update."
    exit 1
  fi
  sleep 10
done

echo "Database is up, version:"
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T db \
  mariadb -u root --password="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" -N -B -e "select version()" \
  || echo "(could not query the database version)"

# Older installations still have the database default of the image that created
# it (bare "CREATE DATABASE", so it inherited latin1 from the server default of
# the day). All nextcloud tables are utf8mb4/utf8mb4_bin because nextcloud sets
# that explicitly, but a table created without an explicit charset would inherit
# latin1. Metadata only, no table or row is touched.
echo "Setting the database default charset to utf8mb4..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T db \
  mariadb -u root --password="$HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD" \
  -e "alter database nextcloud character set utf8mb4 collate utf8mb4_general_ci"

echo "Waiting for nextcloud to finish its upgrade (2 minutes)..."
sleep 120

echo "Installing dependencies in container..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec nextcloud bash -c \
  "apt-get update && apt-get -y install jq && apt-get clean && rm -rf /var/lib/apt/lists/*"

echo "Running post-update configuration..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-afterupdate.sh

echo "DB updates..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-indices
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-columns
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-primary-keys

echo "Configuring auth module..."
touch ../store/auth/auth.env
sed -i '/NEXTCLOUD_DB_PASSWORD=/d' ../store/auth/auth.env
sed -i '/NEXTCLOUD_API_URL=/d' ../store/auth/auth.env

rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o
  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"
}

echo "NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD" >> ../store/auth/auth.env
echo "NEXTCLOUD_API_URL=http://admin:$(rawurlencode "$HABIDAT_ADMIN_PASSWORD")@$HABIDAT_DOCKER_PREFIX-nextcloud/ocs/v1.php" >> ../store/auth/auth.env
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d
