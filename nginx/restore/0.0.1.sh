#!/usr/bin/env bash
set -euo pipefail

# Restores what export/0.0.1.sh wrote. store/nginx/ (configuration,
# certificates, networks.env) has already been put back.
#
# The containers are only stopped, never taken down: `down` would try to remove
# the proxy network every other module is attached to.

[[ -f ../store/nginx/docker-compose.yml ]] || exit 0

PROJECT="$HABIDAT_DOCKER_PREFIX-nginx"
COMPOSE=(docker compose -f ../store/nginx/docker-compose.yml -p "$PROJECT")

echo "Stopping nginx..."
"${COMPOSE[@]}" rm --stop --force

restore_volume "${PROJECT}_vhost" "$PROJECT" vhost
restore_volume "${PROJECT}_dhparam" "$PROJECT" dhparam

"${COMPOSE[@]}" up -d
