#!/usr/bin/env bash
set -euo pipefail

# Restores what export/1.37.4.sh wrote. store/vaultwarden/ (secrets, the
# confirmation bot's credentials) has already been put back.

PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"
COMPOSE_FILE=../store/vaultwarden/docker-compose.yml
COMPOSE=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")

echo "Stopping Vaultwarden..."
"${COMPOSE[@]}" rm --stop --force

restore_volume "${PROJECT}_data" "$PROJECT" data
restore_volume "${PROJECT}_sync-state" "$PROJECT" sync-state

# The volume was read while Vaultwarden wrote to it; the online copy is the
# consistent one.
echo "Putting back the consistent database copy..."
docker run --rm -v "${PROJECT}_data:/data" -v "$HABIDAT_RESTORE_DIR:/in:ro" "$HABIDAT_TOOLS_IMAGE" \
  sh -c 'rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm && cp /in/db.sqlite3 /data/db.sqlite3'

echo "Starting Vaultwarden..."
"${COMPOSE[@]}" build sync
"${COMPOSE[@]}" up -d
../lib/wait-for.sh "Vaultwarden" 180 \
  "docker compose -f '$COMPOSE_FILE' -p '$PROJECT' exec -T vaultwarden /healthcheck.sh"
