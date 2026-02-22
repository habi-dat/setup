#!/usr/bin/env bash
set -euo pipefail

# Mediawiki is multi-instance: iterate all instances in store/mediawiki/*/
if [[ $# -eq 1 ]]; then
  echo "Updating mediawiki $1 instance..."
  docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" pull
  docker compose -f "../store/mediawiki/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" up -d
else
  echo "Updating all mediawiki instances..."
  for dir in ../store/mediawiki/*/; do
    [[ -d "$dir" ]] || continue
    dir=${dir%*/}
    id=${dir##*/}
    echo "Updating mediawiki $id instance..."
    docker compose -f "../store/mediawiki/$id/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" pull
    docker compose -f "../store/mediawiki/$id/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" up -d
  done
fi
