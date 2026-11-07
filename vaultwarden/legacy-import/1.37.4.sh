#!/usr/bin/env bash
set -euo pipefail

# Replaces the /data volume with an archive written by export/1.37.4.sh.

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/vaultwarden"
COMPOSE=(docker compose -f ../store/vaultwarden/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-vaultwarden")

echo "Stopping Vaultwarden..."
"${COMPOSE[@]}" stop sync vaultwarden

echo "Replacing data volume..."
"${COMPOSE[@]}" run --rm --no-deps -T -v "$BACKUP_DIR:/backup:ro" --entrypoint sh \
  vaultwarden -c "find /data -mindepth 1 -delete && tar xzf '/backup/$1' -C /data"

echo "Starting Vaultwarden..."
"${COMPOSE[@]}" up -d
../lib/wait-for.sh "Vaultwarden" 180 \
  "docker compose -f ../store/vaultwarden/docker-compose.yml -p '$HABIDAT_DOCKER_PREFIX-vaultwarden' exec -T vaultwarden /healthcheck.sh"
