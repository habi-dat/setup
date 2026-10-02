#!/usr/bin/env bash
# Shared helpers for listmonk module scripts. Sourced, not executed.

_listmonk_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTMONK_MODULE_DIR="$(cd "$_listmonk_lib_dir/.." && pwd)"
LISTMONK_REPO_ROOT="$(cd "$LISTMONK_MODULE_DIR/.." && pwd)"

listmonk_subdomain() {
  printf '%s' "${HABIDAT_LISTMONK_SUBDOMAIN:-lists}"
}

listmonk_instance_dir() {
  printf '%s' "$LISTMONK_REPO_ROOT/store/listmonk/$1"
}

listmonk_compose() {
  printf '%s' "$LISTMONK_REPO_ROOT/store/listmonk/$1/docker-compose.yml"
}

listmonk_project() {
  printf '%s' "${HABIDAT_DOCKER_PREFIX}-listmonk-$1"
}

listmonk_container() {
  printf '%s' "${HABIDAT_DOCKER_PREFIX}-listmonk-$1"
}

listmonk_db_container() {
  printf '%s' "${HABIDAT_DOCKER_PREFIX}-listmonk-$1-db"
}

listmonk_public_url() {
  local id="$1"
  printf '%s://%s.%s.%s' \
    "${HABIDAT_PROTOCOL:-https}" \
    "$id" \
    "$(listmonk_subdomain)" \
    "${HABIDAT_DOMAIN}"
}

listmonk_slug() {
  printf '%s.%s' "$1" "$(listmonk_subdomain)"
}

listmonk_list_instances() {
  local dir
  [[ -d "$LISTMONK_REPO_ROOT/store/listmonk" ]] || return 0
  for dir in "$LISTMONK_REPO_ROOT"/store/listmonk/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}docker-compose.yml" ]] || continue
    basename "${dir%/}"
  done
}

listmonk_each_instance() {
  local action="$1"
  if [[ $# -ge 2 && -n "${2:-}" ]]; then
    "$action" "$2"
    return
  fi
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    "$action" "$id"
  done < <(listmonk_list_instances)
}

listmonk_load_instance() {
  local id="$1"
  local dir
  dir="$(listmonk_instance_dir "$id")"
  # shellcheck disable=SC1091
  source "${dir}/passwords.env"
  export HABIDAT_LISTMONK_PROJECTID="$id"
}

listmonk_sql_escape() {
  python3 -c 'import sys; print(sys.argv[1].replace(chr(39), chr(39) * 2))' "$1"
}
