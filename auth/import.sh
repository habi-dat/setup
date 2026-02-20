#!/bin/bash
set +x

echo "NOTE: importing data only works for data with the same domain / LDAP base"

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth"
COMPOSE="docker compose -f ../store/auth/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-auth"

if [ -f "$BACKUP_DIR/$1" ]; then
  echo "Importing data from $BACKUP_DIR/$1"
else
  echo "Import file $BACKUP_DIR/$1 not found"
  echo "Available files:"
  ls -ltr "$BACKUP_DIR"
  exit 1
fi

echo "Extracting data..."
tar -xzf "$BACKUP_DIR/$1" -C "$BACKUP_DIR"

rm -rf ../store/auth/user-import/*

# Legacy v1 format: data/ directory with JSON stores
if [ -d "$BACKUP_DIR/data" ]; then
  echo "Detected legacy export format (v1)..."

  echo "Restoring user module activation store..."
  if [ -f "$BACKUP_DIR/data/activationStore.json" ]; then
    cp "$BACKUP_DIR/data/activationStore.json" ../store/auth/user-import/activationStore.json
  fi

  echo "Restoring user module app store..."
  if [ -f "$BACKUP_DIR/data/appStore.json" ]; then
    cp "$BACKUP_DIR/data/appStore.json" ../store/auth/user-import/appStore.json
  fi

  echo "Restoring settings store..."
  if [ -f "$BACKUP_DIR/data/settingsStore.json" ]; then
    cp "$BACKUP_DIR/data/settingsStore.json" ../store/auth/user-import/settingsStore.json
  fi

  rm -rf "$BACKUP_DIR/data"
fi

echo "Importing LDAP data..."
cp "$BACKUP_DIR/export.ldif" ../store/auth/bootstrap/import.ldif
rm "$BACKUP_DIR/export.ldif"

envsubst < config/bootstrap-update.ldif > ../store/auth/bootstrap/bootstrap.ldif

$COMPOSE down -v
$COMPOSE up -d user-db user-redis ldap

echo "Waiting for LDAP to be ready..."
sleep 60

# v2 format: restore PostgreSQL dump before running init
if [ -f "$BACKUP_DIR/db.sql" ]; then
  echo "Restoring PostgreSQL database..."
  $COMPOSE exec -T user-db psql -U postgres -d habidat_auth < "$BACKUP_DIR/db.sql"
  rm "$BACKUP_DIR/db.sql"
fi

$COMPOSE run --rm user-init
$COMPOSE up -d user user-worker

# v2 format: restore uploaded images into the user container
if [ -d "$BACKUP_DIR/uploads" ]; then
  echo "Restoring uploaded images..."
  docker cp "$BACKUP_DIR/uploads/." "$HABIDAT_DOCKER_PREFIX-user":/app/apps/web/public/uploads/
  rm -rf "$BACKUP_DIR/uploads"
fi

echo "Finished, imported: $1"
