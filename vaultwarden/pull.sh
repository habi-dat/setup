#!/usr/bin/env bash
set -euo pipefail

# The sync image is built locally, so a plain `compose pull` would fail on it.

COMPOSE_FILE="../store/vaultwarden/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull vaultwarden
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" build sync
