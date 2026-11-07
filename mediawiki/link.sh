#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): writes the SAML login app of one mediawiki instance ($1),
# or of every instance, to auth. Title and group come from the instance's
# web.env. Safe to repeat; an existing app only gets its SAML endpoints updated.

# shellcheck source=../lib/auth-app.sh
source ../lib/auth-app.sh

env_value() {
  local line
  line="$(grep -E "^$1=" "$2" | tail -n1)"
  printf '%s' "${line#*=}"
}

link_one() (
  local id="$1" file web_env="../store/mediawiki/$1/web.env"
  export HABIDAT_MEDIAWIKI_PROJECTID="$id"
  HABIDAT_MEDIAWIKI_TITLE="$(env_value MEDIAWIKI_NAME "$web_env")"
  HABIDAT_MEDIAWIKI_LDAP_GROUP="$(env_value HABIDAT_MEDIAWIKI_LDAP_GROUP "$web_env")"
  export HABIDAT_MEDIAWIKI_TITLE HABIDAT_MEDIAWIKI_LDAP_GROUP
  file="../store/auth/user-import/appStore-mediawiki-${id}.json"
  mkdir -p ../store/auth/user-import
  ../lib/render.py config/auth-app.json.j2 "$file"
  auth_app_link "$file"
)

if [[ $# -ge 1 ]]; then
  [[ -f "../store/mediawiki/$1/web.env" ]] || { echo "Mediawiki instance $1 not found." >&2; exit 1; }
  link_one "$1"
else
  for dir in ../store/mediawiki/*/; do
    [[ -f "${dir}web.env" ]] || continue
    dir="${dir%/}"
    link_one "${dir##*/}"
  done
fi
