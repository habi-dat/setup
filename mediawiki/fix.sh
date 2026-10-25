#!/usr/bin/env bash
set -euo pipefail

# Pulls and recreates the containers of one mediawiki instance ($1) or of all
# instances, without re-rendering anything.

fix_one() {
  local id="$1"
  echo "Fixing mediawiki instance $id..."
  docker compose -f "../store/mediawiki/$id/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" pull
  docker compose -f "../store/mediawiki/$id/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" up -d
}

if [[ $# -ge 1 ]]; then
  [[ -f "../store/mediawiki/$1/docker-compose.yml" ]] || { echo "Mediawiki instance $1 not found." >&2; exit 1; }
  fix_one "$1"
else
  for dir in ../store/mediawiki/*/; do
    [[ -f "${dir}docker-compose.yml" ]] || continue
    dir=${dir%/}
    fix_one "${dir##*/}"
  done
fi
