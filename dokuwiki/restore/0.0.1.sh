#!/usr/bin/env bash
set -euo pipefail

# Restores what export/0.0.1.sh wrote. store/dokuwiki/ has already been put back.

PROJECT="$HABIDAT_DOCKER_PREFIX-dokuwiki"
COMPOSE=(docker compose -f ../store/dokuwiki/docker-compose.yml -p "$PROJECT")

echo "Stopping dokuwiki..."
"${COMPOSE[@]}" rm --stop --force

for volume in data config plugins templates; do
  restore_volume "${PROJECT}_$volume" "$PROJECT" "$volume"
done

"${COMPOSE[@]}" up -d
