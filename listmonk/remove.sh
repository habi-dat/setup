#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

remove_auth_app() {
  local id="$1"
  local slug
  slug="$(listmonk_slug "$id")"
  local slug_sql
  slug_sql="$(listmonk_sql_escape "$slug")"
  rm -f "$LISTMONK_REPO_ROOT/store/auth/user-import/appStore-listmonk-${id}.json"
  if [[ -f "$LISTMONK_REPO_ROOT/store/auth/docker-compose.yml" ]] && docker inspect "${HABIDAT_DOCKER_PREFIX}-user-db" &>/dev/null; then
    echo "Removing habidat-auth OIDC app ${slug}..."
    docker compose -f "$LISTMONK_REPO_ROOT/store/auth/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-auth" \
      exec -T user-db psql -U postgres -d habidat_auth \
      -c "DELETE FROM \"App\" WHERE slug = '${slug_sql}';" \
      || echo "Could not delete auth app ${slug} (auth database unavailable)."
  fi
}

remove_one() {
  local id="$1"
  echo "Destroying containers and volumes for listmonk instance ${id}..."
  remove_auth_app "$id"
  if [[ -f "$(listmonk_compose "$id")" ]]; then
    docker compose -f "$(listmonk_compose "$id")" -p "$(listmonk_project "$id")" down -v --remove-orphans
  fi
  rm -rf "$(listmonk_instance_dir "$id")"
}

if [[ $# -eq 1 ]]; then
  if [[ ! -d "$(listmonk_instance_dir "$1")" ]]; then
    echo "Listmonk instance $1 not found."
    exit 1
  fi
  remove_one "$1"
else
  echo "Destroying containers and volumes for all listmonk instances..."
  listmonk_each_instance remove_one
  rm -rf "$LISTMONK_REPO_ROOT/store/listmonk"
fi
