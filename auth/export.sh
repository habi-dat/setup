#!/bin/bash
set +x

echo "Exporting LDAP data..."

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export.ldif.tmp
docker cp "$HABIDAT_DOCKER_PREFIX-user":/app/data $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/
sed -f export.sed $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export.ldif.tmp > $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export.ldif
rm $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export.ldif.tmp

echo "Compressing data..."
tar -czf auth-$DATE.tar.gz -C $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth export.ldif -C $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth data

mv auth-$DATE.tar.gz $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/
rm -rf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export.ldif
rm -rf $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/data

echo "NOTE: importing this data only works for data with the same domain / LDAP base"

echo "Finished, filename: $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/auth-$DATE.tar.gz"
