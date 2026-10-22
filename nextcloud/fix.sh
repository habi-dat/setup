#!/usr/bin/env bash
set -euo pipefail

# Re-pulls the nextcloud images and recreates the containers without
# re-rendering templates or touching store/nextcloud/version. Redoes what a
# recreated container loses or needs after an image change: jq, the habidat
# post-update configuration and the database maintenance.

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

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

echo "Running post-update configuration..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-afterupdate.sh

echo "DB updates..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-indices
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-columns
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-primary-keys
