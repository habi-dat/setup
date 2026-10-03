#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

remove_auth_app() {
  local id="$1"
  local slug slug_sql
  slug="$(website_stored_slug "$id")"
  slug_sql="$(website_sql_escape "$slug")"
  rm -f "$WEBSITE_REPO_ROOT/store/auth/user-import/appStore-website-${id}.json"
  if [[ -f "$WEBSITE_REPO_ROOT/store/auth/docker-compose.yml" ]] && docker inspect "${HABIDAT_DOCKER_PREFIX}-user-db" &>/dev/null; then
    echo "Removing habidat-auth OIDC app ${slug}..."
    docker compose -f "$WEBSITE_REPO_ROOT/store/auth/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-auth" \
      exec -T user-db psql -U postgres -d habidat_auth \
      -c "DELETE FROM \"AppGroupAccess\" WHERE \"appId\" IN (SELECT id FROM \"App\" WHERE slug = '${slug_sql}'); DELETE FROM \"App\" WHERE slug = '${slug_sql}';" \
      || echo "Could not delete auth app ${slug} (auth database unavailable)."
  fi
}

remove_one() {
  local id="$1"
  echo "Destroying containers for website instance ${id}..."
  remove_auth_app "$id"
  if [[ -f "$(website_compose "$id")" ]]; then
    docker compose -f "$(website_compose "$id")" -p "$(website_project "$id")" down --remove-orphans
  fi
  rm -rf "$(website_instance_dir "$id")"
}

if [[ $# -eq 1 ]]; then
  if [[ ! -d "$(website_instance_dir "$1")" ]]; then
    echo "Website instance $1 not found."
    exit 1
  fi
  remove_one "$1"
else
  echo "Destroying containers for all website instances..."
  website_each_instance remove_one
  rm -rf "$WEBSITE_REPO_ROOT/store/website"
fi
