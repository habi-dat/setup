#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Exporting LDAP data..."

mkdir -p $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif ../store/export/auth/export-$DATE.ldif.tmp
sed -f export.sed $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export-$DATE.ldif.tmp > $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export-$DATE.ldif
rm $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/export-$DATE.ldif.tmp
echo "Compressing data..."
cd $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth 
tar -czf auth-$DATE.tar.gz export-$DATE.ldif
rm export-$DATE.ldif

echo "Finished, filename: $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/auth/auth-$DATE.tar.gz"
