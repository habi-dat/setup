#!/usr/bin/env bash
set -euo pipefail

echo "NOTE: importing data only works for data with the same domain / LDAP base"

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth"
COMPOSE_FILE="../store/auth/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-auth"

if [[ -f "$BACKUP_DIR/$1" ]]; then
  echo "Importing data from $BACKUP_DIR/$1"
else
  echo "Import file $BACKUP_DIR/$1 not found"
  echo "Available files:"
  ls -ltr "$BACKUP_DIR"
  exit 1
fi

echo "Extracting data..."
tar -xzf "$BACKUP_DIR/$1" -C "$BACKUP_DIR"

echo "Importing LDAP data..."
mkdir -p ../store/auth/bootstrap
cp "$BACKUP_DIR/export.ldif" ../store/auth/bootstrap/import.ldif
rm "$BACKUP_DIR/export.ldif"

# Pre-version-aware installs have no store/auth/version.
installed=""
if [[ -f ../store/auth/version ]]; then
  installed="$(cat ../store/auth/version)"
fi
if [[ -z "$installed" ]]; then
  installed="0.0.1"
fi

render_versioned_template auth "$installed" \
  config/bootstrap-update.ldif.j2 ../store/auth/bootstrap/bootstrap.ldif

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" down -v
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d ldap

../lib/wait-for.sh "LDAP directory" 300 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T ldap \
    ldapsearch -x -H ldap://localhost -b '' -s base namingContexts"

if [[ -d "$BACKUP_DIR/data" ]]; then
  echo "Restoring legacy /app/data..."
  docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d user
  docker cp "$BACKUP_DIR/data/." "$HABIDAT_DOCKER_PREFIX-user":/app/data/
  rm -rf "$BACKUP_DIR/data"
fi

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

echo "Finished, imported: $1"
