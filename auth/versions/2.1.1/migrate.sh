#!/usr/bin/env bash
set -euo pipefail

set -a
source ../store/nginx/networks.env
source ../store/auth/passwords.env
set +a

export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
export HABIDAT_EXTERNAL_NETWORK_DISABLE=

if [[ "${HABIDAT_EXPOSE_LDAP:-false}" == "true" ]]; then
  export HABIDAT_LDAP_PORT_MAPPING='127.0.0.1:389:389'
else
  export HABIDAT_LDAP_PORT_MAPPING='389'
fi

# 2.1.1 replaces the 2.1.0 app image. user-init applies any pending Prisma
# migrations before the app containers start on the new image.
render_versioned_template auth "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 ../store/auth/docker-compose.yml

echo "Pulling images and recreating containers..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d --remove-orphans user-db user-redis ldap

echo "Running auth-init (migrate + seed)..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init

if [[ "${HABIDAT_MAILHOG:-false}" == "true" ]]; then
  docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d mailhog
fi

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
  up -d --remove-orphans user user-worker user-avatars
