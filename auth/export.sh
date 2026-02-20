#!/bin/bash
set +x

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth"
DATE=$(date +"%Y%m%d%H%M")
COMPOSE="docker compose -f ../store/auth/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-auth"

mkdir -p "$BACKUP_DIR"

echo "Exporting LDAP data..."
$COMPOSE exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif "$BACKUP_DIR/export.ldif.tmp"
sed -f export.sed "$BACKUP_DIR/export.ldif.tmp" > "$BACKUP_DIR/export.ldif"
rm "$BACKUP_DIR/export.ldif.tmp"

echo "Exporting PostgreSQL database..."
$COMPOSE exec -T user-db pg_dump -U postgres --clean --if-exists habidat_auth > "$BACKUP_DIR/db.sql"

echo "Exporting uploaded images..."
rm -rf "$BACKUP_DIR/uploads"
docker cp "$HABIDAT_DOCKER_PREFIX-user":/app/apps/web/public/uploads "$BACKUP_DIR/uploads" 2>/dev/null || mkdir -p "$BACKUP_DIR/uploads"

echo "Compressing data..."
tar -czf "$BACKUP_DIR/auth-$DATE.tar.gz" -C "$BACKUP_DIR" export.ldif db.sql uploads

rm -rf "$BACKUP_DIR/export.ldif" "$BACKUP_DIR/db.sql" "$BACKUP_DIR/uploads"

echo "NOTE: importing this data only works for data with the same domain / LDAP base"
echo "Finished, filename: $BACKUP_DIR/auth-$DATE.tar.gz"
