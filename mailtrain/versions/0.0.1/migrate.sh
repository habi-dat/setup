#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/mailtrain/passwords.env

render_versioned_template mailtrain "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 ../store/mailtrain/docker-compose.yml

echo "Pulling images and recreating containers..."
docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" pull
docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" up -d
