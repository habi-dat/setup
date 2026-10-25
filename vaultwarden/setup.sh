#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f ../store/nginx/networks.env ]] || [[ ! -f ../store/auth/docker-compose.yml ]]; then
  echo "vaultwarden requires nginx and auth to be installed first."
  exit 1
fi

if [[ -z "${HABIDAT_VAULTWARDEN_ADMIN_EMAIL:-}" ]]; then
  echo "Set HABIDAT_VAULTWARDEN_ADMIN_EMAIL in setup.env to the email of the auth account that will own the Vaultwarden organization."
  exit 1
fi

# shellcheck disable=SC1091
source ../store/nginx/networks.env
# shellcheck disable=SC1091
source ../store/auth/passwords.env

COMPOSE_FILE="../store/vaultwarden/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-vaultwarden"
AUTH_COMPOSE=(docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth")

sql_escape() {
  python3 -c 'import sys; print(sys.argv[1].replace("\x27", "\x27\x27"))' "$1"
}

mkdir -p ../store/vaultwarden

SETUP_OK=0
cleanup() {
  if [[ "$SETUP_OK" -eq 1 ]]; then
    return 0
  fi
  echo "Vaultwarden setup failed, cleaning up..."
  rm -f ../store/auth/user-import/appStore-vaultwarden.json
  if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" down -v --remove-orphans || true
  fi
  rm -rf ../store/vaultwarden
}
trap cleanup EXIT

echo "Generating secrets..."
HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET="$(openssl rand -hex 24)"
HABIDAT_VAULTWARDEN_ADMIN_TOKEN="$(openssl rand -base64 48 | tr -d '\n/+=')"
export HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET
export HABIDAT_VAULTWARDEN_ADMIN_TOKEN
{
  echo "export HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET=${HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET}"
  echo "export HABIDAT_VAULTWARDEN_ADMIN_TOKEN=${HABIDAT_VAULTWARDEN_ADMIN_TOKEN}"
} > ../store/vaultwarden/passwords.env
chmod 600 ../store/vaultwarden/passwords.env

../lib/render.py config/vaultwarden.env.j2 ../store/vaultwarden/vaultwarden.env
../lib/render.py config/sync.env.j2 ../store/vaultwarden/sync.env
../lib/render.py docker-compose.yml.j2 "$COMPOSE_FILE"
chmod 600 ../store/vaultwarden/vaultwarden.env ../store/vaultwarden/sync.env

# Filled in by `habidat.sh configure vaultwarden` once the organization exists.
# Until then the sync container idles.
: > ../store/vaultwarden/credentials.env
chmod 600 ../store/vaultwarden/credentials.env

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=${HABIDAT_DOMAIN}" >> ../store/vaultwarden/vaultwarden.env
  # shellcheck source=../lib/selfsigned-cert.sh
  source ../lib/selfsigned-cert.sh
  habidat_ensure_selfsigned_cert
  cp "$(mkcert -CAROOT)/rootCA.pem" ../store/vaultwarden/mkcert-root.crt
fi

echo "Registering Vaultwarden OIDC app in habidat-auth..."
mkdir -p ../store/auth/user-import
../lib/render.py config/auth-app.json.j2 ../store/auth/user-import/appStore-vaultwarden.json
if ! "${AUTH_COMPOSE[@]}" run --rm user-init; then
  echo "Failed to register Vaultwarden OIDC app in habidat-auth."
  exit 1
fi

# The seed only fills OIDC fields on an app row that has none yet, so a
# reinstall would keep the old client secret. Upsert the row so it always
# matches the secret generated above. No AppGroupAccess rows: every auth user
# may log in.
url="${HABIDAT_PROTOCOL:-https}://${HABIDAT_VAULTWARDEN_SUBDOMAIN}.${HABIDAT_DOMAIN}"
redirect_json="$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1] + "/identity/connect/oidc-signin"]))' "$url")"
secret_sql="$(sql_escape "$HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET")"
redirect_sql="$(sql_escape "$redirect_json")"
url_sql="$(sql_escape "$url")"
oidc_result="$("${AUTH_COMPOSE[@]}" exec -T user-db psql -U postgres -d habidat_auth -v ON_ERROR_STOP=1 -tA <<SQL
WITH updated AS (
  UPDATE "App"
  SET "oidcEnabled" = true,
      "oidcClientId" = 'vaultwarden',
      "oidcRedirectUris" = '${redirect_sql}',
      "oidcClientSecret" = '${secret_sql}'
  WHERE slug = 'vaultwarden'
  RETURNING slug
),
inserted AS (
  INSERT INTO "App" (
    "id", slug, name, url, "updatedAt",
    "oidcEnabled", "oidcClientId", "oidcRedirectUris", "oidcClientSecret"
  )
  SELECT gen_random_uuid()::text, 'vaultwarden', 'Passwörter', '${url_sql}', CURRENT_TIMESTAMP,
         true, 'vaultwarden', '${redirect_sql}', '${secret_sql}'
  WHERE NOT EXISTS (SELECT 1 FROM updated)
  RETURNING slug
)
SELECT slug FROM inserted
UNION ALL
SELECT slug FROM updated;
SQL
)"
oidc_result="$(printf '%s' "${oidc_result//$'\r'/}" | tr -d '[:space:]')"
if [[ "$oidc_result" != "vaultwarden" ]]; then
  echo "habidat-auth App row for vaultwarden was neither updated nor inserted." >&2
  exit 1
fi

echo "Building the sync image and starting containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull vaultwarden
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" build sync
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d
../lib/wait-for.sh "Vaultwarden" 180 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T vaultwarden /healthcheck.sh"

SETUP_OK=1

cat <<EOF

Vaultwarden is running at ${url}.

One-time setup (the organization's encryption keys are created in the browser):
  1. In auth, create two users: the super admin (email ${HABIDAT_VAULTWARDEN_ADMIN_EMAIL})
     and a bot account (e.g. vaultwarden-bot). Neither needs to be an auth admin.
  2. As the super admin, log in at ${url} through auth, set a master password
     and create the organization.
  3. As the bot, log in once the same way, set a master password, and copy its
     personal API key (Account settings > Security > Keys > View API key).
  4. As the super admin, invite the bot to the organization as Admin and confirm
     it, then create the organization API key (Organization settings > API key).
  5. Run: ./habidat.sh configure vaultwarden
EOF
