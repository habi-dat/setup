#!/bin/bash
set -e

# Load setup and store env (for mapping and envsubst)
[ -f ../setup.env ] && source ../setup.env
source ../store/nginx/networks.env
source ../store/auth/passwords.env
[ -f ../store/auth/user.env ] && source ../store/auth/user.env

export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
export HABIDAT_EXTERNAL_NETWORK_DISABLE=

if [ "${HABIDAT_EXPOSE_LDAP:-false}" = "true" ]; then
  export HABIDAT_LDAP_PORT_MAPPING='127.0.0.1:389:389'
else
  export HABIDAT_LDAP_PORT_MAPPING='389'
fi

mkdir -p ../store/auth/user-import

# Ensure store/auth/auth.env exists and has all required keys (add only missing)
AUTH_ENV="../store/auth/auth.env"
touch "$AUTH_ENV"

ensure_key() {
  local key="$1"
  local value="$2"
  if ! grep -q "^${key}=" "$AUTH_ENV" 2>/dev/null; then
    echo "${key}=${value}" >> "$AUTH_ENV"
  fi
}

# POSTGRES_PASSWORD first (needed for DATABASE_URL)
if ! grep -q "^POSTGRES_PASSWORD=" "$AUTH_ENV" 2>/dev/null; then
  # URL-safe password (hex only, no special chars that break URLs)
  ensure_key "POSTGRES_PASSWORD" "$(openssl rand -hex 24)"
fi
POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$AUTH_ENV" | cut -d= -f2-)

# DATABASE_URL and REDIS_URL (service names from same compose)
ensure_key "DATABASE_URL" "postgresql://postgres:${POSTGRES_PASSWORD}@user-db:5432/habidat_auth"
ensure_key "REDIS_URL" "redis://user-redis:6379"

# App URL (from protocol + subdomain + domain)
HOST="${HABIDAT_USER_SUBDOMAIN:-user}.${HABIDAT_DOMAIN:-habidat.local}"
PROTO="${HABIDAT_PROTOCOL:-https}"
APP_URL="${PROTO}://${HOST}"
ensure_key "APP_URL" "$APP_URL"
ensure_key "NEXT_PUBLIC_APP_URL" "$APP_URL"
ensure_key "TRUSTED_ORIGINS" "${PROTO}://*.${HABIDAT_DOMAIN:-habidat.local}"

# Secrets (from legacy or generate)
SECRET="${HABIDAT_USER_SESSION_SECRET:-}"
[ -z "$SECRET" ] && SECRET=$(openssl rand -base64 32 | tr -d '\n')
ensure_key "SESSION_SECRET" "$SECRET"
ensure_key "BETTER_AUTH_SECRET" "$SECRET"

# Seed
ensure_key "ADMIN_EMAIL" "${HABIDAT_ADMIN_EMAIL:-admin@example.com}"
ensure_key "ADMIN_PASSWORD" "${HABIDAT_ADMIN_PASSWORD:-}"

# LDAP (from user.env)
LDAP_HOST="${HABIDAT_USER_LDAP_HOST:-ldap}"
LDAP_PORT="${HABIDAT_USER_LDAP_PORT:-389}"
ensure_key "LDAP_URL" "ldap://${LDAP_HOST}:${LDAP_PORT}"
ensure_key "LDAP_BIND_DN" "${HABIDAT_USER_LDAP_BINDDN:-}"
ensure_key "LDAP_BIND_PASSWORD" "${HABIDAT_USER_LDAP_PASSWORD:-}"
BASE_DN="${HABIDAT_USER_LDAP_BASE:-dc=habidat,dc=local}"
ensure_key "LDAP_BASE_DN" "$BASE_DN"
ensure_key "LDAP_USERS_DN" "ou=users,${BASE_DN}"
ensure_key "LDAP_GROUPS_DN" "ou=groups,${BASE_DN}"

# SMTP (from user.env)
ensure_key "SMTP_HOST" "${HABIDAT_USER_SMTP_HOST:-localhost}"
ensure_key "SMTP_PORT" "${HABIDAT_USER_SMTP_PORT:-1025}"
ensure_key "SMTP_SECURE" "${HABIDAT_USER_SMTP_TLS:-false}"
ensure_key "SMTP_USER" "${HABIDAT_USER_SMTP_USER:-}"
ensure_key "SMTP_PASS" "${HABIDAT_USER_SMTP_PASSWORD:-}"
ensure_key "SMTP_FROM" "${HABIDAT_USER_SMTP_EMAILFROM:-noreply@${HOST}}"

# discourse
ensure_key "DISCOURSE_URL" "http://${HABIDAT_DOCKER_PREFIX}-discourse:80"
ensure_key "DISCOURSE_API_KEY" "${HABIDAT_DISCOURSE_API_KEY:-}"
ensure_key "DISCOURSE_API_USERNAME" "system"
ensure_key "DISCOURSE_SSO_SECRET" "${HABIDAT_DISCOURSE_SSO_SECRET:-}"

# Source auth.env for envsubst (e.g. if compose used ${POSTGRES_PASSWORD})
set -a
[ -f "$AUTH_ENV" ] && source "$AUTH_ENV"
set +a

envsubst < docker-compose.yml > ../store/auth/docker-compose.yml
envsubst < config/bootstrap-update.ldif > ../store/auth/bootstrap/bootstrap.ldif
cp config/memberOf.ldif ../store/auth/memberOf.ldif

echo "Pulling images and recreate containers..."

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user-db user-redis ldap

echo "Running auth-init (migrate + seed)..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user user-worker
