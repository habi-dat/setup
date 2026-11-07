#!/usr/bin/env bash
set -euo pipefail

# Restores what export/2.0.0.sh wrote. store/auth/ has already been put back.
#
# Never runs user-init: its seed re-attaches install-time groups to apps that
# exist, which would undo an admin's changes (ADR 0007). The database comes back
# at the snapshot's schema, and `update` migrates it afterwards.

PROJECT="$HABIDAT_DOCKER_PREFIX-auth"
COMPOSE_FILE=../store/auth/docker-compose.yml
COMPOSE=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")
VERSION="$(tr -d '[:space:]' < ../store/auth/version)"

# shellcheck disable=SC1091
source ../store/auth/passwords.env

echo "Stopping auth..."
"${COMPOSE[@]}" rm --stop --force

# The LDAP container imports the bootstrap folder only into an empty directory.
echo "Preparing the LDAP import..."
docker volume rm --force "${PROJECT}_ldap-data" "${PROJECT}_ldap-config" >/dev/null
mkdir -p ../store/auth/bootstrap
cp "$HABIDAT_RESTORE_DIR/ldap.ldif" ../store/auth/bootstrap/import.ldif
render_versioned_template auth "$VERSION" \
  config/bootstrap-update.ldif.j2 ../store/auth/bootstrap/bootstrap.ldif

restore_volume "${PROJECT}_user-uploads" "$PROJECT" user-uploads

"${COMPOSE[@]}" up -d --wait user-db user-redis
"${COMPOSE[@]}" up -d ldap
../lib/wait-for.sh "LDAP directory" 300 \
  "docker compose -f '$COMPOSE_FILE' -p '$PROJECT' exec -T ldap \
     ldapsearch -x -H ldap://localhost -D 'cn=admin,$HABIDAT_LDAP_BASE' \
     -w '$HABIDAT_LDAP_ADMIN_PASSWORD' -b '$HABIDAT_LDAP_BASE' -s base dn"

echo "Loading the auth database..."
"${COMPOSE[@]}" exec -T user-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
  < "$HABIDAT_RESTORE_DIR/db.sql"

services=(user user-worker user-avatars)
if [[ "${HABIDAT_MAILHOG:-false}" == "true" ]]; then
  services+=(mailhog)
fi
"${COMPOSE[@]}" up -d "${services[@]}"
