#!/usr/bin/env bash
set -euo pipefail

set -a
source ../store/nginx/networks.env
source ../store/auth/passwords.env
[[ -f ../store/auth/user.env ]] && source ../store/auth/user.env
set +a

export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
export HABIDAT_EXTERNAL_NETWORK_DISABLE=

if [[ "${HABIDAT_EXPOSE_LDAP:-false}" == "true" ]]; then
  export HABIDAT_LDAP_PORT_MAPPING='127.0.0.1:389:389'
else
  export HABIDAT_LDAP_PORT_MAPPING='389'
fi

AUTH_ENV="../store/auth/auth.env"
touch "$AUTH_ENV"

env_value() {
  grep "^${1}=" "$AUTH_ENV" 2>/dev/null | cut -d= -f2- || true
}

replace_key() {
  local key="$1"
  local value="$2"
  sed -i "/^${key}=/d" "$AUTH_ENV"
  echo "${key}=${value}" >> "$AUTH_ENV"
}

# habidat-auth requires BETTER_AUTH_SECRET >= 32 characters. 2.0.0 copied
# HABIDAT_USER_SESSION_SECRET from 1.x via ensure_key and would not replace a
# shorter existing value, so the web container exits with "Invalid environment
# variables".
better_auth_secret="$(env_value BETTER_AUTH_SECRET)"
if [[ ${#better_auth_secret} -lt 32 ]]; then
  session_secret="$(env_value SESSION_SECRET)"
  legacy_secret="${HABIDAT_USER_SESSION_SECRET:-}"
  if [[ ${#session_secret} -ge 32 ]]; then
    better_auth_secret="$session_secret"
    echo "BETTER_AUTH_SECRET was shorter than 32 characters; copying SESSION_SECRET."
  elif [[ ${#legacy_secret} -ge 32 ]]; then
    better_auth_secret="$legacy_secret"
    echo "BETTER_AUTH_SECRET was shorter than 32 characters; copying HABIDAT_USER_SESSION_SECRET."
  else
    better_auth_secret="$(openssl rand -base64 32 | tr -d '\n')"
    echo "BETTER_AUTH_SECRET was shorter than 32 characters; generated a new secret (existing sessions are invalidated)."
  fi
  replace_key "BETTER_AUTH_SECRET" "$better_auth_secret"
  if [[ ${#session_secret} -lt 32 ]]; then
    replace_key "SESSION_SECRET" "$better_auth_secret"
  fi
fi

# 2.0.0 always set CERT_NAME to the apex domain. nginx-proxy then looks for
# /etc/nginx/certs/$HABIDAT_DOMAIN.crt instead of the Let's Encrypt per-host
# cert, so HTTPS for user.$HABIDAT_DOMAIN fails with unrecognized_name.
# Recreate the user container so the proxy drops CERT_NAME and picks up the
# secret from auth.env.
render_versioned_template auth "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 ../store/auth/docker-compose.yml

echo "Recreating the user container so nginx-proxy picks up the TLS env..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
  up -d --remove-orphans user user-worker user-avatars
