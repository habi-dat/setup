#!/usr/bin/env bash
set -euo pipefail

# Dumps the LDAP directory and the auth database while auth keeps running, and
# names the volume with uploaded images. Redis only holds sessions and job
# queues and is not backed up. See lib/export.sh for the contract.

COMPOSE=(docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth")

echo "Dumping the LDAP directory..."
# Without the entries the bootstrap creates (base, organizational units, the
# admin role): restore/2.0.0.sh imports this on top of a fresh bootstrap.
"${COMPOSE[@]}" exec -T ldap slapcat \
  -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))' \
  | sed -f export.sed > "$HABIDAT_EXPORT_DIR/ldap.ldif"

echo "Dumping the auth database..."
"${COMPOSE[@]}" exec -T user-db \
  pg_dump -U postgres --clean --if-exists --create habidat_auth > "$HABIDAT_EXPORT_DIR/db.sql"

export_volume "$HABIDAT_DOCKER_PREFIX-auth_user-uploads"
