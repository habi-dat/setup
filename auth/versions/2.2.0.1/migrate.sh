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

# ---------------------------------------------------------------------------
# 2.2.0 -> 2.2.0.1: osixia/openldap 1.3.0 -> 1.5.0
#
# Same image family and layout, OpenLDAP 2.4.50 -> 2.4.57: the existing
# cn=config and database volumes are used as they are, and the custom
# bootstrap is skipped because the directory is already initialised. Tested on
# a directory bootstrapped by 1.3.0: entries, passwords, the read-only user and
# the memberOf overlay all carry over. 1.5.0 is still Debian 10, but it drops
# about a third of the known-exploited and likely-exploited vulnerabilities.
# ---------------------------------------------------------------------------
render_versioned_template auth "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 ../store/auth/docker-compose.yml

echo "Pulling images and recreating containers..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d --remove-orphans user-db user-redis ldap

../lib/wait-for.sh "LDAP" 120 \
  "docker inspect -f '{{.State.Health.Status}}' '$HABIDAT_DOCKER_PREFIX-ldap' | grep -qx healthy"

echo "Running auth-init (migrate + seed)..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init

if [[ "${HABIDAT_MAILHOG:-false}" == "true" ]]; then
  docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d mailhog
fi

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
  up -d --remove-orphans user user-worker user-avatars

echo "Removing the old LDAP image..."
docker image rm osixia/openldap:1.3.0 2>/dev/null || true
