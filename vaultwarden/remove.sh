#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="../store/vaultwarden/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"

rm -f ../store/auth/user-import/appStore-vaultwarden.json
if [[ -f ../store/auth/docker-compose.yml ]] && docker inspect "${HABIDAT_DOCKER_PREFIX}-user-db" &>/dev/null; then
  echo "Removing habidat-auth OIDC app vaultwarden..."
  docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
    exec -T user-db psql -U postgres -d habidat_auth \
    -c "DELETE FROM \"App\" WHERE slug = 'vaultwarden';" \
    || echo "Could not delete auth app vaultwarden (auth database unavailable)."
fi

echo "Destroying Vaultwarden containers and volumes..."
if [[ -f "$COMPOSE_FILE" ]]; then
  docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" down -v --remove-orphans
fi
rm -rf ../store/vaultwarden
