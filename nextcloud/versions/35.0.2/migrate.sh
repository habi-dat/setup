#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

echo "Copying assets to store..."
# Keep the bind-mounted directory inode (see 34.0.4.1). "up -d" below only
# recreates nextcloud and cron when their image changes, so a re-run after a
# failed attempt would otherwise leave /habidat on the deleted directory.
mkdir -p ../store/nextcloud/assets
find ../store/nextcloud/assets -mindepth 1 -delete
cp -a assets/. ../store/nextcloud/assets/
chmod +x ../store/nextcloud/assets/habidat-bootstrap.sh
chmod +x ../store/nextcloud/assets/habidat-afterupdate.sh
chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh

render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 "$COMPOSE_FILE"

render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  config/mariadb.cnf.j2 ../store/nextcloud/mariadb.cnf

# ---------------------------------------------------------------------------
# Nextcloud 34 -> 35
#
# The database stays on MariaDB 11.8: nextcloud 35 supports 10.11 / 11.4 /
# 11.8 / 12.3 and only dropped 10.6, which 34.0.4 already left behind. PHP is
# whatever the official image ships (8.3+ is required by 35).
#
# A major upgrade cannot be skipped. The image entrypoint refuses to start when
# the data volume is more than one major behind, so this has to run on top of
# 34.0.4(.1).
# ---------------------------------------------------------------------------

# `occ upgrade` disables every app whose installed release does not declare
# support for 35 (external, for one, pins a single major). Remember what was
# enabled on 34 so it can be re-enabled once compatible releases are fetched.
# Kept in the store so a re-run after a failed attempt - when the instance is
# already on 35 and the apps are already disabled - still has the 34 list.
ENABLED_APPS_FILE="../store/nextcloud/apps-enabled-before-35.txt"
if [[ ! -s "$ENABLED_APPS_FILE" ]]; then
  echo "Recording enabled apps..."
  docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T --user www-data \
    nextcloud php occ app:list --enabled --no-warnings \
    | sed -n 's/^  - \([^:]*\):.*/\1/p' > "$ENABLED_APPS_FILE" \
    || echo "WARNING: could not list enabled apps, disabled apps will not be re-enabled."
fi

echo "Pulling images and recreating containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

# The entrypoint runs `occ upgrade` when the image version changes and holds the
# instance in maintenance mode while it does.
../lib/wait-for.sh "Nextcloud upgrade" 900 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T --user www-data \
     nextcloud php occ status | grep -q 'installed: true' &&
   docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T --user www-data \
     nextcloud php occ status | grep -q 'maintenance: false'"

echo "Installing dependencies in container..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec nextcloud bash -c \
  "apt-get update && apt-get -y install jq && apt-get clean && rm -rf /var/lib/apt/lists/*"

# Fetch the 35 compatible releases, then re-enable what the upgrade disabled.
# Not fatal: a single app failing must not abort the core upgrade. An app that
# was enabled for some groups only comes back enabled for everyone.
echo "Updating apps..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ app:update --all \
  || echo "WARNING: some apps could not be updated, check 'occ app:list' after the update."

if [[ -s "$ENABLED_APPS_FILE" ]]; then
  disabled_apps=$(docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T --user www-data \
    nextcloud php occ app:list --disabled --no-warnings | sed -n 's/^  - \([^:]*\):.*/\1/p')
  while IFS= read -r app; do
    grep -qxF "$app" <<< "$disabled_apps" || continue
    echo "Re-enabling $app..."
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T --user www-data nextcloud php occ app:enable -n "$app" \
      || echo "WARNING: could not re-enable $app, it has no release for nextcloud 35 yet."
  done < "$ENABLED_APPS_FILE"
  rm -f "$ENABLED_APPS_FILE"
fi

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
