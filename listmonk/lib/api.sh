#!/usr/bin/env bash
# HTTP helpers for the Listmonk admin API. Sourced by setup / import scripts.
# Listmonk's image has no curl, so requests go through a sidecar that shares
# the app container's network namespace.

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LISTMONK_CURL_IMAGE="${LISTMONK_CURL_IMAGE:-curlimages/curl:8.13.0}"

# Listmonk v4+ HTTP Basic is the API username plus its token, not the web
# Super Admin password. --install prints the token once; setup.sh stores it.
listmonk_api_user() {
  printf '%s' "${HABIDAT_LISTMONK_API_USER:?HABIDAT_LISTMONK_API_USER is unset}"
}

listmonk_api_password() {
  printf '%s' "${HABIDAT_LISTMONK_API_TOKEN:?HABIDAT_LISTMONK_API_TOKEN is unset}"
}

listmonk_curl() {
  local id="$1"
  shift
  docker run --rm -i --network "container:$(listmonk_container "$id")" \
    "$LISTMONK_CURL_IMAGE" "$@"
}

# listmonk_curl_file <id> <host-file> <container-path> [curl-args...]
listmonk_curl_file() {
  local id="$1"
  local host_file="$2"
  local container_path="$3"
  shift 3
  docker run --rm --network "container:$(listmonk_container "$id")" \
    -v "${host_file}:${container_path}:ro" \
    "$LISTMONK_CURL_IMAGE" "$@"
}

# listmonk_api <id> <method> <path> [curl-args...]
# Prints the response body. Exits non-zero on HTTP >= 400.
listmonk_api() {
  local id="$1"
  local method="$2"
  local path="$3"
  shift 3
  listmonk_curl "$id" \
    -sS -f \
    -u "$(listmonk_api_user):$(listmonk_api_password)" \
    -X "$method" \
    -H "Content-Type: application/json" \
    "$@" \
    "http://127.0.0.1:9000${path}"
}

listmonk_wait_http() {
  local id="$1"
  local timeout="${2:-180}"
  ../lib/wait-for.sh "listmonk $id HTTP" "$timeout" \
    "docker run --rm --network 'container:$(listmonk_container "$id")' \
       '$LISTMONK_CURL_IMAGE' -fsS http://127.0.0.1:9000/health"
}
