#!/usr/bin/env bash
set -euo pipefail

# Restores what export/3.3.2.sh wrote. store/discourse/ (launcher and container
# definitions) has already been put back. On a server without the discourse
# containers they are bootstrapped with `launcher rebuild`, which takes a while.

LAUNCHER=../store/discourse/launcher
DATA="$HABIDAT_DOCKER_PREFIX-discourse-data"
WEB="$HABIDAT_DOCKER_PREFIX-discourse"

# shellcheck disable=SC1091
source ../store/nginx/networks.env

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

echo "Stopping discourse..."
if container_exists "$WEB"; then
  docker stop "$WEB" >/dev/null
fi

restore_volume "$WEB"

if container_exists "$DATA"; then
  "$LAUNCHER" start "$DATA"
else
  "$LAUNCHER" rebuild "$DATA"
fi
../lib/wait-for.sh "discourse database" 300 \
  "docker exec -u postgres '$DATA' psql -d postgres -c 'select 1'"

echo "Loading the forum database..."
docker exec -i -u postgres "$DATA" psql -d postgres -v ON_ERROR_STOP=1 -q -o /dev/null \
  < "$HABIDAT_RESTORE_DIR/db.sql"

if container_exists "$WEB"; then
  "$LAUNCHER" start "$WEB"
else
  "$LAUNCHER" rebuild "$WEB"
  docker network connect "$HABIDAT_PROXY_NETWORK" "$WEB"
fi
