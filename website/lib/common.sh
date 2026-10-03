#!/usr/bin/env bash
# Shared helpers for the website module. Sourced, not executed.

_website_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSITE_MODULE_DIR="$(cd "$_website_lib_dir/.." && pwd)"
WEBSITE_REPO_ROOT="$(cd "$WEBSITE_MODULE_DIR/.." && pwd)"

website_instance_dir() {
  printf '%s' "$WEBSITE_REPO_ROOT/store/website/$1"
}

website_compose() {
  printf '%s' "$WEBSITE_REPO_ROOT/store/website/$1/docker-compose.yml"
}

website_project() {
  printf '%s' "${HABIDAT_DOCKER_PREFIX}-website-$1"
}

website_container() {
  printf '%s' "${HABIDAT_DOCKER_PREFIX}-website-$1"
}

website_hostname() {
  local host="${1,,}"
  if [[ -z "$host" || "$host" == *"://"* || "$host" == */* || "$host" == *:* ]]; then
    echo "Hostname must be a DNS name, without a scheme, path, or port." >&2
    return 1
  fi
  if [[ ! "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "Hostname must be a DNS name, such as schlor.org." >&2
    return 1
  fi
  printf '%s' "$host"
}

website_public_url() {
  local host="${HABIDAT_WEBSITE_HOST:?Set the website hostname.}"
  printf '%s://%s' "${HABIDAT_PROTOCOL:-https}" "$host"
}

website_slug() {
  printf '%s' "$1"
}

website_stored_slug() {
  local id="$1"
  local file line
  file="$(website_instance_dir "$id")/passwords.env"
  if [[ -f "$file" ]]; then
    line="$(grep -E '^export HABIDAT_WEBSITE_OIDC_CLIENT_ID=' "$file" || true)"
    line="${line#export HABIDAT_WEBSITE_OIDC_CLIENT_ID=}"
    line="${line//\'/}"
    if [[ -n "$line" ]]; then
      printf '%s' "$line"
      return
    fi
  fi
  website_slug "$id"
}

website_list_instances() {
  local dir
  [[ -d "$WEBSITE_REPO_ROOT/store/website" ]] || return 0
  for dir in "$WEBSITE_REPO_ROOT"/store/website/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}docker-compose.yml" ]] || continue
    basename "${dir%/}"
  done
}

website_each_instance() {
  local action="$1"
  if [[ $# -ge 2 && -n "${2:-}" ]]; then
    "$action" "$2"
    return
  fi
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    "$action" "$id"
  done < <(website_list_instances)
}

website_sql_escape() {
  python3 -c 'import sys; print(sys.argv[1].replace(chr(39), chr(39) * 2))' "$1"
}
