#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/vaultwarden/passwords.env

COMPOSE_FILE="../store/vaultwarden/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"

render_versioned_template vaultwarden "$HABIDAT_MIGRATE_VERSION" docker-compose.yml.j2 "$COMPOSE_FILE"
render_versioned_template vaultwarden "$HABIDAT_MIGRATE_VERSION" config/vaultwarden.env.j2 ../store/vaultwarden/vaultwarden.env
render_versioned_template vaultwarden "$HABIDAT_MIGRATE_VERSION" config/sync.env.j2 ../store/vaultwarden/sync.env
if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=${HABIDAT_DOMAIN}" >> ../store/vaultwarden/vaultwarden.env
fi

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull vaultwarden
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" build sync
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d
