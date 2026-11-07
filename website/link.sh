#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): writes the login app of one website instance ($1), or of
# every instance, to auth from store/website/<id>/. Safe to repeat; an existing
# app only gets its OIDC client settings updated.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=../lib/auth-app.sh
source ../lib/auth-app.sh

link_one() (
  local id="$1" file
  # shellcheck disable=SC1090
  source "$(website_instance_dir "$id")/passwords.env"
  export HABIDAT_WEBSITE_PROJECTID="$id" HABIDAT_WEBSITE_TITLE HABIDAT_WEBSITE_LDAP_GROUP \
    HABIDAT_WEBSITE_HOST HABIDAT_WEBSITE_OIDC_CLIENT_ID HABIDAT_WEBSITE_OIDC_CLIENT_SECRET
  file="../store/auth/user-import/appStore-website-${id}.json"
  mkdir -p ../store/auth/user-import
  ../lib/render.py config/auth-app.json.j2 "$file"
  auth_app_link "$file"
)

website_each_instance link_one "${1:-}"
