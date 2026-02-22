#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

echo "Copying assets to store..."
rm -rf ../store/nextcloud/assets
cp -r assets ../store/nextcloud/assets
chmod +x ../store/nextcloud/assets/habidat-bootstrap.sh
chmod +x ../store/nextcloud/assets/habidat-afterupdate.sh
chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh

render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 "$COMPOSE_FILE"

echo "Pulling official nextcloud image and recreating containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

echo "Waiting for containers to start (2 minutes)..."
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
