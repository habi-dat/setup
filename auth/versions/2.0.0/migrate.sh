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

mkdir -p ../store/auth/user-import

# Copy Vue/Express JSON stores into user-import BEFORE compose replaces {prefix}-user.
# 1.x kept settings/apps/invites under /app/data (volume user-data). Seed reads /app/import.
LEGACY_STORE_FILES=(
  appStore.json
  settingsStore.json
  activationStore.json
  emailTemplateStore.json
)
IMPORT_DIR="../store/auth/user-import"
USER_CONTAINER="${HABIDAT_DOCKER_PREFIX}-user"
COMPOSE_PROJECT="${HABIDAT_DOCKER_PREFIX}-auth"

legacy_store_present() {
  local dir="$1"
  local f
  for f in "${LEGACY_STORE_FILES[@]}"; do
    [[ -f "$dir/$f" ]] && return 0
  done
  return 1
}

copy_legacy_stores_from_dir() {
  local src="$1"
  local f
  for f in "${LEGACY_STORE_FILES[@]}"; do
    if [[ -f "$src/$f" ]]; then
      cp -f "$src/$f" "$IMPORT_DIR/$f"
      echo "Copied legacy $f into store/auth/user-import"
    fi
  done
}

copy_legacy_json_from_user_container() {
  if ! docker inspect "$USER_CONTAINER" &>/dev/null; then
    return 1
  fi
  local tmp
  tmp=$(mktemp -d)
  if ! docker cp "$USER_CONTAINER:/app/data/." "$tmp/" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  if ! legacy_store_present "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  echo "Found legacy /app/data on $USER_CONTAINER; overwriting user-import stores from 1.x..."
  copy_legacy_stores_from_dir "$tmp"
  rm -rf "$tmp"
}

copy_legacy_json_from_volume() {
  local vol=""
  if docker inspect "$USER_CONTAINER" &>/dev/null; then
    vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' "$USER_CONTAINER" 2>/dev/null || true)
  fi
  if [[ -z "$vol" ]]; then
    for candidate in "${COMPOSE_PROJECT}_user-data" "${COMPOSE_PROJECT}-user-data"; do
      if docker volume inspect "$candidate" &>/dev/null; then
        vol="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$vol" ]] || ! docker volume inspect "$vol" &>/dev/null; then
    return 1
  fi

  local tmp
  tmp=$(mktemp -d)
  if ! docker run --rm \
    -v "$vol":/legacy-data:ro \
    -v "$tmp":/out \
    alpine:3.20 \
    sh -c 'cp -a /legacy-data/. /out/ 2>/dev/null || true'; then
    rm -rf "$tmp"
    return 1
  fi
  if ! legacy_store_present "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  echo "Found legacy JSON on volume $vol; overwriting user-import stores from 1.x..."
  copy_legacy_stores_from_dir "$tmp"
  rm -rf "$tmp"
}

if copy_legacy_json_from_user_container; then
  :
elif [[ -f "$IMPORT_DIR/appStore.json" ]]; then
  echo "No live 1.x /app/data; keeping existing store/auth/user-import files."
elif copy_legacy_json_from_volume; then
  :
else
  echo "No legacy JSON stores found on $USER_CONTAINER:/app/data or user-data volume."
fi

AUTH_ENV="../store/auth/auth.env"
touch "$AUTH_ENV"

ensure_key() {
  local key="$1"
  local value="$2"
  if ! grep -q "^${key}=" "$AUTH_ENV" 2>/dev/null; then
    echo "${key}=${value}" >> "$AUTH_ENV"
  fi
}

if ! grep -q "^POSTGRES_PASSWORD=" "$AUTH_ENV" 2>/dev/null; then
  ensure_key "POSTGRES_PASSWORD" "$(openssl rand -hex 24)"
fi
POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$AUTH_ENV" | cut -d= -f2-)

ensure_key "DATABASE_URL" "postgresql://postgres:${POSTGRES_PASSWORD}@user-db:5432/habidat_auth"
ensure_key "REDIS_URL" "redis://user-redis:6379"

HOST="${HABIDAT_USER_SUBDOMAIN:-user}.${HABIDAT_DOMAIN:-habidat.local}"
PROTO="${HABIDAT_PROTOCOL:-https}"
APP_URL="${PROTO}://${HOST}"
ensure_key "APP_URL" "$APP_URL"
ensure_key "NEXT_PUBLIC_APP_URL" "$APP_URL"
ensure_key "TRUSTED_ORIGINS" "${PROTO}://*.${HABIDAT_DOMAIN:-habidat.local}"

SECRET="${HABIDAT_USER_SESSION_SECRET:-}"
[[ -z "$SECRET" ]] && SECRET=$(openssl rand -base64 32 | tr -d '\n')
ensure_key "SESSION_SECRET" "$SECRET"
ensure_key "BETTER_AUTH_SECRET" "$SECRET"

ensure_key "ADMIN_EMAIL" "${HABIDAT_ADMIN_EMAIL:-admin@example.com}"
ensure_key "ADMIN_PASSWORD" "${HABIDAT_ADMIN_PASSWORD:-}"

LDAP_HOST="${HABIDAT_USER_LDAP_HOST:-ldap}"
LDAP_PORT="${HABIDAT_USER_LDAP_PORT:-389}"
ensure_key "LDAP_URL" "ldap://${LDAP_HOST}:${LDAP_PORT}"
ensure_key "LDAP_BIND_DN" "${HABIDAT_USER_LDAP_BINDDN:-}"
ensure_key "LDAP_BIND_PASSWORD" "${HABIDAT_USER_LDAP_PASSWORD:-}"
BASE_DN="${HABIDAT_USER_LDAP_BASE:-dc=habidat,dc=local}"
ensure_key "LDAP_BASE_DN" "$BASE_DN"
ensure_key "LDAP_USERS_DN" "ou=users,${BASE_DN}"
ensure_key "LDAP_GROUPS_DN" "ou=groups,${BASE_DN}"

ensure_key "SMTP_HOST" "${HABIDAT_USER_SMTP_HOST:-localhost}"
ensure_key "SMTP_PORT" "${HABIDAT_USER_SMTP_PORT:-1025}"
ensure_key "SMTP_SECURE" "${HABIDAT_USER_SMTP_TLS:-false}"
ensure_key "SMTP_USER" "${HABIDAT_USER_SMTP_USER:-}"
ensure_key "SMTP_PASS" "${HABIDAT_USER_SMTP_PASSWORD:-}"
ensure_key "SMTP_FROM" "${HABIDAT_USER_SMTP_EMAILFROM:-noreply@${HOST}}"

ensure_key "DISCOURSE_URL" "http://${HABIDAT_DOCKER_PREFIX}-discourse:80"
ensure_key "DISCOURSE_API_KEY" "${HABIDAT_DISCOURSE_API_KEY:-}"
ensure_key "DISCOURSE_API_USERNAME" "system"
ensure_key "DISCOURSE_SSO_SECRET" "${HABIDAT_DISCOURSE_SSO_SECRET:-}"

set -a
[[ -f "$AUTH_ENV" ]] && source "$AUTH_ENV"
set +a

render_versioned_template auth "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 ../store/auth/docker-compose.yml
render_versioned_template auth "$HABIDAT_MIGRATE_VERSION" \
  config/bootstrap-update.ldif.j2 ../store/auth/bootstrap/bootstrap.ldif
render_versioned_template auth "$HABIDAT_MIGRATE_VERSION" \
  config/memberOf.ldif.j2 ../store/auth/memberOf.ldif

echo "Pulling images and recreating containers..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user-db user-redis ldap

echo "Running auth-init (migrate + seed)..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init

if [[ "${HABIDAT_MAILHOG:-false}" == "true" ]]; then
  docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d mailhog
fi

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user user-worker 
