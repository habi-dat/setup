#!/usr/bin/env bash
set -euo pipefail

# Re-pulls the auth images and recreates the containers without re-rendering
# templates or touching store/auth/version. user-init runs first because a new
# image can ship pending Prisma migrations.

COMPOSE="../store/auth/docker-compose.yml"
PROJECT="$HABIDAT_DOCKER_PREFIX-auth"

echo "Pulling images..."
docker compose -f "$COMPOSE" -p "$PROJECT" pull
docker compose -f "$COMPOSE" -p "$PROJECT" up -d --remove-orphans user-db user-redis ldap

echo "Running auth-init (migrate + seed)..."
docker compose -f "$COMPOSE" -p "$PROJECT" run --rm user-init

if [[ "${HABIDAT_MAILHOG:-false}" == "true" ]]; then
  docker compose -f "$COMPOSE" -p "$PROJECT" up -d mailhog
fi

docker compose -f "$COMPOSE" -p "$PROJECT" up -d --remove-orphans user user-worker user-avatars
