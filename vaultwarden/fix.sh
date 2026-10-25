#!/usr/bin/env bash
set -euo pipefail

# Pulls the Vaultwarden image, rebuilds the sync image and recreates the
# containers, without re-rendering templates or touching store/vaultwarden/version.

COMPOSE_FILE="../store/vaultwarden/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull vaultwarden
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" build sync
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d
