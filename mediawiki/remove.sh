#!/usr/bin/env bash
set -euo pipefail

remove_auth_app() {
  local id="$1"
  local slug="${id}.${HABIDAT_MEDIAWIKI_SUBDOMAIN:-mediawiki}"
  local slug_sql="${slug//\'/\'\'}"
  rm -f "../store/auth/user-import/appStore-mediawiki-${id}.json"
  if [[ -f ../store/auth/docker-compose.yml ]] && docker inspect "${HABIDAT_DOCKER_PREFIX}-user-db" &>/dev/null; then
    echo "Removing habidat-auth SAML app ${slug}..."
    docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
      exec -T user-db psql -U postgres -d habidat_auth \
      -c "DELETE FROM \"App\" WHERE slug = '${slug_sql}';" \
      || echo "Could not delete auth app ${slug} (auth database unavailable)."
  fi
}

if [[ $# -eq 1 ]]; then
  echo "Destroying containers and volumes for $1 instance..."
  remove_auth_app "$1"
  docker compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" down -v --remove-orphans
  rm -r ../store/mediawiki/$1
else
  echo "Destroying containers and volumes for all instances..."

  for dir in ../store/mediawiki/*/  # list directories
  do
    [[ -d "$dir" ]] || continue
    dir=${dir%*/}      # remove the trailing "/"
    id=${dir##*/}

    remove_auth_app "$id"
    docker compose -f ../store/mediawiki/$id/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" down -v --remove-orphans
    rm -r ../store/mediawiki/$id
  done

  rm -r ../store/mediawiki
fi
