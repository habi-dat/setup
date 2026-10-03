#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  echo "./habidat.sh install website <project-id> <title> <ldap-group> <hostname>"
  exit 1
}

[[ $# -ge 4 ]] || usage

PROJECT_ID="$1"
TITLE="$2"
LDAP_GROUP="$3"
HABIDAT_WEBSITE_HOST="$(website_hostname "$4")"

if [[ ! "$PROJECT_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  echo "Project ID must be a DNS label (letters, numbers, hyphens)."
  exit 1
fi

if [[ ! -f ../store/nginx/networks.env ]] || [[ ! -f ../store/auth/docker-compose.yml ]]; then
  echo "website requires nginx and auth to be installed first."
  exit 1
fi

if [[ -d "../store/website/${PROJECT_ID}" ]]; then
  echo "Website instance ${PROJECT_ID} already exists, aborting..."
  exit 1
fi

echo "Installing website instance ${PROJECT_ID}..."

# shellcheck disable=SC1091
source ../store/nginx/networks.env

export HABIDAT_WEBSITE_PROJECTID="$PROJECT_ID"
export HABIDAT_WEBSITE_TITLE="$TITLE"
export HABIDAT_WEBSITE_LDAP_GROUP="$LDAP_GROUP"
export HABIDAT_WEBSITE_HOST
export HABIDAT_WEBSITE_SRC="${HABIDAT_WEBSITE_SRC:-}"
export HABIDAT_WEBSITE_IMAGE="${HABIDAT_WEBSITE_IMAGE:-}"

if [[ -n "$HABIDAT_WEBSITE_SRC" && ! -f "$HABIDAT_WEBSITE_SRC/Dockerfile" ]]; then
  echo "HABIDAT_WEBSITE_SRC has no Dockerfile: $HABIDAT_WEBSITE_SRC"
  exit 1
fi

mkdir -p "../store/website/${PROJECT_ID}/data"

SETUP_OK=0
cleanup() {
  if [[ "$SETUP_OK" -eq 1 ]]; then
    return 0
  fi
  local container
  container="$(website_container "$PROJECT_ID")"
  if docker inspect "$container" >/dev/null 2>&1; then
    echo "----- logs from ${container} (before removal) -----"
    docker logs --tail 200 "$container" 2>&1 || true
    echo "----- end logs from ${container} -----"
  fi
  echo "Website setup failed, cleaning up instance ${PROJECT_ID}..."
  rm -f "../store/auth/user-import/appStore-website-${PROJECT_ID}.json"
  if [[ -f "../store/website/${PROJECT_ID}/docker-compose.yml" ]]; then
    docker compose -f "../store/website/${PROJECT_ID}/docker-compose.yml" \
      -p "$(website_project "$PROJECT_ID")" down --remove-orphans || true
  fi
  rm -rf "../store/website/${PROJECT_ID}"
}
trap cleanup EXIT

echo "Generating secrets..."
HABIDAT_WEBSITE_SESSION_SECRET="$(openssl rand -hex 32)"
HABIDAT_WEBSITE_OIDC_CLIENT_SECRET="$(openssl rand -hex 24)"
HABIDAT_WEBSITE_OIDC_CLIENT_ID="$(website_slug "$PROJECT_ID")"
export HABIDAT_WEBSITE_SESSION_SECRET
export HABIDAT_WEBSITE_OIDC_CLIENT_SECRET
export HABIDAT_WEBSITE_OIDC_CLIENT_ID

{
  echo "export HABIDAT_WEBSITE_SESSION_SECRET=${HABIDAT_WEBSITE_SESSION_SECRET}"
  echo "export HABIDAT_WEBSITE_OIDC_CLIENT_ID=${HABIDAT_WEBSITE_OIDC_CLIENT_ID}"
  echo "export HABIDAT_WEBSITE_OIDC_CLIENT_SECRET=${HABIDAT_WEBSITE_OIDC_CLIENT_SECRET}"
  echo "export HABIDAT_WEBSITE_TITLE=$(printf '%q' "$TITLE")"
  echo "export HABIDAT_WEBSITE_LDAP_GROUP=$(printf '%q' "$LDAP_GROUP")"
  echo "export HABIDAT_WEBSITE_HOST=$(printf '%q' "$HABIDAT_WEBSITE_HOST")"
  echo "export HABIDAT_WEBSITE_IMAGE=$(printf '%q' "${HABIDAT_WEBSITE_IMAGE:-soudis/draftpunk:latest}")"
} > "../store/website/${PROJECT_ID}/passwords.env"

../lib/render.py config/website.env.j2 "../store/website/${PROJECT_ID}/website.env"
../lib/render.py docker-compose.yml.j2 "../store/website/${PROJECT_ID}/docker-compose.yml"

if [[ "${HABIDAT_CREATE_SELFSIGNED:-false}" == "true" ]]; then
  cert_dir="../store/nginx/certificates"
  mkdir -p "$cert_dir"
  echo "Minting a certificate for ${HABIDAT_WEBSITE_HOST}..."
  mkcert -install \
    -key-file "${cert_dir}/${HABIDAT_WEBSITE_HOST}.key" \
    -cert-file "${cert_dir}/${HABIDAT_WEBSITE_HOST}.crt" \
    "$HABIDAT_WEBSITE_HOST"
  echo "CERT_NAME=${HABIDAT_WEBSITE_HOST}" >> "../store/website/${PROJECT_ID}/website.env"
  cp "$(mkcert -CAROOT)/rootCA.pem" "../store/website/${PROJECT_ID}/mkcert-root.crt"
fi

source_site="${HABIDAT_WEBSITE_SRC}/instances/${PROJECT_ID}"
if [[ -n "$HABIDAT_WEBSITE_SRC" && -d "${source_site}/design" ]]; then
  echo "Copying ${source_site} into the instance data..."
  mkdir -p "../store/website/${PROJECT_ID}/data/site"
  cp -a "${source_site}/." "../store/website/${PROJECT_ID}/data/site/"
fi

echo "Registering website OIDC app in habidat-auth..."
mkdir -p ../store/auth/user-import
../lib/render.py config/auth-app.json.j2 "../store/auth/user-import/appStore-website-${PROJECT_ID}.json"
if ! docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" run --rm user-init; then
  echo "Failed to register website OIDC app in habidat-auth."
  exit 1
fi

slug="$(website_slug "$PROJECT_ID")"
slug_sql="$(website_sql_escape "$slug")"
client_id_sql="$(website_sql_escape "$HABIDAT_WEBSITE_OIDC_CLIENT_ID")"
secret_sql="$(website_sql_escape "$HABIDAT_WEBSITE_OIDC_CLIENT_SECRET")"
redirect_json="$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1] + "/auth/callback"]))' "$(website_public_url "$PROJECT_ID")")"
redirect_sql="$(website_sql_escape "$redirect_json")"
name_sql="$(website_sql_escape "$TITLE")"
url_sql="$(website_sql_escape "$(website_public_url "$PROJECT_ID")")"
group_sql="$(website_sql_escape "$LDAP_GROUP")"
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
if [[ "$group_state" != *group-ok* ]]; then
  echo "habidat-auth has no group ${LDAP_GROUP}." >&2
  exit 1
fi

compose_file="$(website_compose "$PROJECT_ID")"
compose_project="$(website_project "$PROJECT_ID")"
if [[ -n "$HABIDAT_WEBSITE_SRC" ]]; then
  echo "Building and starting the editor..."
  docker compose -f "$compose_file" -p "$compose_project" build
else
  echo "Pulling and starting the editor..."
  docker compose -f "$compose_file" -p "$compose_project" pull
fi
docker compose -f "$compose_file" -p "$compose_project" up -d

SETUP_OK=1
echo "Website instance ${PROJECT_ID} is installed."
echo "  Editor:   $(website_public_url "$PROJECT_ID")"
echo "  Group:    ${LDAP_GROUP}"
echo "  Publish:  off. The public domain is unchanged until cutover."
