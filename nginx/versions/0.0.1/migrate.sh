#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env

if [[ -z "${HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK:-}" ]]; then

  render_versioned_template nginx "$HABIDAT_MIGRATE_VERSION" \
    docker-compose.yml.j2 ../store/nginx/docker-compose.yml
  mkdir -p ../store/nginx/config
  render_versioned_template nginx "$HABIDAT_MIGRATE_VERSION" \
    config/nginx.conf.j2 ../store/nginx/config/nginx.conf
  render_versioned_template nginx "$HABIDAT_MIGRATE_VERSION" \
    config/user.conf.j2 ../store/nginx/config/user.conf
  render_versioned_template nginx "$HABIDAT_MIGRATE_VERSION" \
    config/cors_map.conf.j2 ../store/nginx/config/cors_map.conf
  render_versioned_template nginx "$HABIDAT_MIGRATE_VERSION" \
    config/cookies.conf.j2 ../store/nginx/config/cookies.conf

  echo "Pulling images and recreating containers..."
  docker compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" pull
  docker compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" up -d

else

  echo "Using existing nginx generator and proxy network, skipping module containers..."
  echo "export HABIDAT_PROXY_NETWORK=$HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK" > ../store/nginx/networks.env

fi
