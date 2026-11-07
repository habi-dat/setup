#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): writes the login app of one listmonk instance ($1), or of
# every instance, to auth from store/listmonk/<id>/. Safe to repeat; an existing
# app only gets its OIDC client settings updated.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../lib/auth-app.sh
source ../lib/auth-app.sh

link_one() (
  local id="$1" file
  listmonk_load_instance "$id"
  export HABIDAT_LISTMONK_TITLE HABIDAT_LISTMONK_LDAP_GROUP \
    HABIDAT_LISTMONK_OIDC_CLIENT_ID HABIDAT_LISTMONK_OIDC_CLIENT_SECRET
  file="../store/auth/user-import/appStore-listmonk-${id}.json"
  mkdir -p ../store/auth/user-import
  ../lib/render.py config/auth-app.json.j2 "$file"
  auth_app_link "$file"
)

listmonk_each_instance link_one "${1:-}"
