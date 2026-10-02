#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  echo "./habidat.sh install listmonk <project-id> <title> <ldap-group> [--from-mailtrain] [--database <name>]"
  exit 1
}

FROM_MAILTRAIN=false
MAILTRAIN_DATABASE=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-mailtrain)
      FROM_MAILTRAIN=true
      shift
      ;;
    --database)
      [[ $# -ge 2 ]] || usage
      MAILTRAIN_DATABASE="$2"
      shift 2
      ;;
    --database=*)
      MAILTRAIN_DATABASE="${1#--database=}"
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[[ ${#ARGS[@]} -ge 3 ]] || usage

if [[ -n "$MAILTRAIN_DATABASE" && "$FROM_MAILTRAIN" != "true" ]]; then
  echo "--database requires --from-mailtrain." >&2
  exit 1
fi

PROJECT_ID="${ARGS[0]}"
TITLE="${ARGS[1]}"
LDAP_GROUP="${ARGS[2]}"

if [[ ! "$PROJECT_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  echo "Project ID must be a DNS label (letters, numbers, hyphens)."
  exit 1
fi

if [[ ! -f ../store/nginx/networks.env ]] || [[ ! -f ../store/auth/docker-compose.yml ]]; then
  echo "listmonk requires nginx and auth to be installed first."
  exit 1
fi

if [[ -d "../store/listmonk/${PROJECT_ID}" ]]; then
  echo "Listmonk instance ${PROJECT_ID} already exists, aborting..."
  exit 1
fi

echo "Installing listmonk instance ${PROJECT_ID}..."

# shellcheck disable=SC1091
source ../store/nginx/networks.env
# shellcheck disable=SC1091
source ../store/auth/passwords.env

export HABIDAT_LISTMONK_PROJECTID="$PROJECT_ID"
export HABIDAT_LISTMONK_TITLE="$TITLE"
export HABIDAT_LISTMONK_LDAP_GROUP="$LDAP_GROUP"

mkdir -p "../store/listmonk/${PROJECT_ID}"

SETUP_OK=0
cleanup() {
  if [[ "$SETUP_OK" -eq 1 ]]; then
    return 0
  fi
  echo "Listmonk setup failed, cleaning up instance ${PROJECT_ID}..."
  rm -f "../store/auth/user-import/appStore-listmonk-${PROJECT_ID}.json"
  if [[ -f "../store/listmonk/${PROJECT_ID}/docker-compose.yml" ]]; then
    docker compose -f "../store/listmonk/${PROJECT_ID}/docker-compose.yml" \
      -p "$(listmonk_project "$PROJECT_ID")" down -v --remove-orphans || true
  fi
  rm -rf "../store/listmonk/${PROJECT_ID}"
}
trap cleanup EXIT

echo "Generating passwords..."
HABIDAT_LISTMONK_DB_PASSWORD="$(openssl rand -hex 24)"
HABIDAT_LISTMONK_ADMIN_PASSWORD="$(openssl rand -hex 24)"
HABIDAT_LISTMONK_OIDC_CLIENT_SECRET="$(openssl rand -hex 24)"
HABIDAT_LISTMONK_OIDC_CLIENT_ID="$(listmonk_slug "$PROJECT_ID")"
export HABIDAT_LISTMONK_DB_PASSWORD
export HABIDAT_LISTMONK_ADMIN_PASSWORD
export HABIDAT_LISTMONK_ADMIN_USER=admin
export HABIDAT_LISTMONK_OIDC_CLIENT_SECRET
export HABIDAT_LISTMONK_OIDC_CLIENT_ID

{
  echo "export HABIDAT_LISTMONK_DB_PASSWORD=${HABIDAT_LISTMONK_DB_PASSWORD}"
  echo "export HABIDAT_LISTMONK_ADMIN_PASSWORD=${HABIDAT_LISTMONK_ADMIN_PASSWORD}"
  echo "export HABIDAT_LISTMONK_ADMIN_USER=admin"
  echo "export HABIDAT_LISTMONK_OIDC_CLIENT_ID=${HABIDAT_LISTMONK_OIDC_CLIENT_ID}"
  echo "export HABIDAT_LISTMONK_OIDC_CLIENT_SECRET=${HABIDAT_LISTMONK_OIDC_CLIENT_SECRET}"
  echo "export HABIDAT_LISTMONK_TITLE=$(printf '%q' "$TITLE")"
  echo "export HABIDAT_LISTMONK_LDAP_GROUP=$(printf '%q' "$LDAP_GROUP")"
} > "../store/listmonk/${PROJECT_ID}/passwords.env"

../lib/render.py config/db.env.j2 "../store/listmonk/${PROJECT_ID}/db.env"
../lib/render.py config/listmonk.env.j2 "../store/listmonk/${PROJECT_ID}/listmonk.env"
../lib/render.py config/config.toml.j2 "../store/listmonk/${PROJECT_ID}/config.toml"
../lib/render.py docker-compose.yml.j2 "../store/listmonk/${PROJECT_ID}/docker-compose.yml"

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  echo "CERT_NAME=${HABIDAT_DOMAIN}" >> "../store/listmonk/${PROJECT_ID}/listmonk.env"
  # shellcheck source=../lib/selfsigned-cert.sh
  source ../lib/selfsigned-cert.sh
  habidat_ensure_selfsigned_cert
  cp "$(mkcert -CAROOT)/rootCA.pem" "../store/listmonk/${PROJECT_ID}/mkcert-root.crt"
fi

echo "Registering Listmonk OIDC app in habidat-auth..."
mkdir -p ../store/auth/user-import
../lib/render.py config/auth-app.json.j2 "../store/auth/user-import/appStore-listmonk-${PROJECT_ID}.json"
if ! docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init; then
  echo "Failed to register Listmonk OIDC app in habidat-auth."
  exit 1
fi

# Current habidat/auth:2.0.0 seed only imports SAML. Force-enable OIDC on the
# app row so Listmonk works before a newer auth image ships the seed change.
slug="$(listmonk_slug "$PROJECT_ID")"
slug_sql="$(listmonk_sql_escape "$slug")"
client_id_sql="$(listmonk_sql_escape "$HABIDAT_LISTMONK_OIDC_CLIENT_ID")"
secret_sql="$(listmonk_sql_escape "$HABIDAT_LISTMONK_OIDC_CLIENT_SECRET")"
redirect_json="$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1] + "/auth/oidc"]))' "$(listmonk_public_url "$PROJECT_ID")")"
redirect_sql="$(listmonk_sql_escape "$redirect_json")"
# user-init only updates an app it already imported. When that row is missing,
# insert it here with the same OIDC client the JSON file describes.
name_sql="$(listmonk_sql_escape "$TITLE")"
url_sql="$(listmonk_sql_escape "$(listmonk_public_url "$PROJECT_ID")")"
group_sql="$(listmonk_sql_escape "$LDAP_GROUP")"
oidc_result="$(docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
  exec -T user-db psql -U postgres -d habidat_auth -v ON_ERROR_STOP=1 -tA <<SQL
WITH updated AS (
  UPDATE "App"
  SET "oidcEnabled" = true,
      "oidcClientId" = '${client_id_sql}',
      "oidcRedirectUris" = '${redirect_sql}',
      "oidcClientSecret" = '${secret_sql}'
  WHERE slug = '${slug_sql}'
  RETURNING slug
),
inserted AS (
  INSERT INTO "App" (
    "id", slug, name, url, "updatedAt",
    "oidcEnabled", "oidcClientId", "oidcRedirectUris", "oidcClientSecret"
  )
  SELECT gen_random_uuid()::text, '${slug_sql}', '${name_sql}', '${url_sql}', CURRENT_TIMESTAMP,
         true, '${client_id_sql}', '${redirect_sql}', '${secret_sql}'
  WHERE NOT EXISTS (SELECT 1 FROM updated)
  RETURNING slug
)
SELECT 'inserted|' || slug FROM inserted
UNION ALL
SELECT 'updated|' || slug FROM updated;
SQL
)"
oidc_result="${oidc_result//$'\r'/}"
oidc_result="$(printf '%s' "$oidc_result" | tr -d '[:space:]')"
oidc_slug="${oidc_result#*|}"
if [[ "$oidc_slug" != "$slug" ]]; then
  echo "habidat-auth App row for ${slug} was neither updated nor inserted." >&2
  exit 1
fi
if [[ "$oidc_result" == inserted\|* ]]; then
  echo "Inserted habidat-auth App ${slug}."
fi
group_state="$(docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" \
  exec -T user-db psql -U postgres -d habidat_auth -v ON_ERROR_STOP=1 -tA <<SQL
INSERT INTO "AppGroupAccess" ("id", "appId", "groupId")
SELECT gen_random_uuid()::text, a.id, g.id
FROM "App" a
JOIN "Group" g
  ON lower(g.slug) = lower('${group_sql}')
  OR lower(coalesce(g."ldapDn", '')) = lower('${group_sql}')
WHERE a.slug = '${slug_sql}'
ON CONFLICT ("appId", "groupId") DO NOTHING;
SELECT CASE
  WHEN EXISTS (
    SELECT 1 FROM "Group" g
    WHERE lower(g.slug) = lower('${group_sql}')
       OR lower(coalesce(g."ldapDn", '')) = lower('${group_sql}')
  ) THEN 'group-ok'
  ELSE 'group-missing'
END;
SQL
)"
group_state="${group_state//$'\r'/}"
group_state="$(printf '%s' "$group_state" | tr -d '[:space:]')"
if [[ "$group_state" != "group-ok" ]]; then
  echo "habidat-auth has no group ${LDAP_GROUP}; App ${slug} was registered without group access." >&2
fi

echo "Spinning up containers..."
compose_file="$(listmonk_compose "$PROJECT_ID")"
compose_project="$(listmonk_project "$PROJECT_ID")"
docker compose -f "$compose_file" -p "$compose_project" pull
docker compose -f "$compose_file" -p "$compose_project" up -d db
../lib/wait-for.sh "listmonk ${PROJECT_ID} database" 180 \
  "docker compose -f '$compose_file' -p '$compose_project' exec -T db pg_isready -U listmonk"

echo "Installing Listmonk schema and API user..."
# --install prints `export LISTMONK_ADMIN_API_TOKEN="..."` on stderr once.
# The long-running container repeats --install --idempotent, which then no-ops.
install_out="$(docker compose -f "$compose_file" -p "$compose_project" run --rm --no-deps -T listmonk \
  ./listmonk --install --idempotent --yes --config /listmonk/config.toml 2>&1)" || {
  printf '%s\n' "$install_out" >&2
  echo "Listmonk --install failed." >&2
  exit 1
}
HABIDAT_LISTMONK_API_TOKEN="$(printf '%s\n' "$install_out" | sed -n 's/.*LISTMONK_ADMIN_API_TOKEN="\([^"]*\)".*/\1/p' | tail -n 1)"
if [[ -z "$HABIDAT_LISTMONK_API_TOKEN" ]]; then
  printf '%s\n' "$install_out" >&2
  echo "Listmonk did not print LISTMONK_ADMIN_API_TOKEN. Refusing to use the web admin password." >&2
  exit 1
fi
export HABIDAT_LISTMONK_API_USER=habidat-api
export HABIDAT_LISTMONK_API_TOKEN
{
  echo "export HABIDAT_LISTMONK_API_USER=habidat-api"
  printf 'export HABIDAT_LISTMONK_API_TOKEN=%q\n' "$HABIDAT_LISTMONK_API_TOKEN"
} >> "../store/listmonk/${PROJECT_ID}/passwords.env"

docker compose -f "$compose_file" -p "$compose_project" up -d listmonk

"./lib/configure-instance.sh" "$PROJECT_ID"

if [[ -f ../store/nextcloud/docker-compose.yml ]]; then
  echo "Add link to nextcloud..."
  mkdir -p ../store/nextcloud/assets
  cp ../nextcloud/assets/habidat-add-externalsite.sh ../store/nextcloud/assets/habidat-add-externalsite.sh
  chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh
  ../lib/wait-for.sh "nextcloud" 300 \
    "docker compose -f ../store/nextcloud/docker-compose.yml \
       -p '$HABIDAT_DOCKER_PREFIX-nextcloud' exec -T --user www-data \
       nextcloud php occ status | grep -q 'installed: true'" || \
    echo "Nextcloud is not ready; skip external site tile."
  if docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" \
      exec --user www-data nextcloud \
      /habidat/habidat-add-externalsite.sh listmonk "$TITLE" "$(listmonk_public_url "$PROJECT_ID")"; then
    :
  else
    echo "Could not add Nextcloud external site for ${PROJECT_ID}."
  fi
fi

if [[ "$FROM_MAILTRAIN" == "true" ]]; then
  if [[ -n "$MAILTRAIN_DATABASE" ]]; then
    "./migrate-from-mailtrain.sh" "$PROJECT_ID" --database "$MAILTRAIN_DATABASE"
  else
    "./migrate-from-mailtrain.sh" "$PROJECT_ID"
  fi
fi

SETUP_OK=1
trap - EXIT

echo
echo "Listmonk instance ${PROJECT_ID} installed."
echo "  URL:      $(listmonk_public_url "$PROJECT_ID")"
echo "  Admin:    $(listmonk_public_url "$PROJECT_ID")/admin  (user admin / password ${HABIDAT_LISTMONK_ADMIN_PASSWORD})"
echo "  OIDC:     sign in through habidat-auth; group '${LDAP_GROUP}' is required."
echo "  App slug: ${slug}"
