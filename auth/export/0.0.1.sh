#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth"
DATE=$(date +"%Y%m%d%H%M")
COMPOSE_FILE="../store/auth/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-auth"

mkdir -p "$BACKUP_DIR"

echo "Exporting LDAP data..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif "$BACKUP_DIR/export.ldif.tmp"
sed -f export.sed "$BACKUP_DIR/export.ldif.tmp" > "$BACKUP_DIR/export.ldif"
rm "$BACKUP_DIR/export.ldif.tmp"

echo "Exporting legacy /app/data..."
rm -rf "$BACKUP_DIR/data"
docker cp "$HABIDAT_DOCKER_PREFIX-user":/app/data "$BACKUP_DIR/data" 2>/dev/null || mkdir -p "$BACKUP_DIR/data"

echo "Compressing data..."
tar -czf "$BACKUP_DIR/auth-$DATE.tar.gz" -C "$BACKUP_DIR" export.ldif data

rm -rf "$BACKUP_DIR/export.ldif" "$BACKUP_DIR/data"

echo "NOTE: importing this data only works for data with the same domain / LDAP base"
echo "Finished, filename: $BACKUP_DIR/auth-$DATE.tar.gz"
