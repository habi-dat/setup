#!/bin/bash
set +x

#export HABIDAT_LDAP_BASE=dc=habidat-staging
#export HABIDAT_LDAP_ADMIN_PASSWORD=A5AFsfDrsr4DYswQ

echo "Exporting LDAP data..."

mkdir -p ../store/export/auth

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
#slapadd -v -c -l backup.ldif
DATE=$(date +"%Y%m%d%H%M")
docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif ../store/export/auth/export-$DATE.ldif
sed -f export.sed ../store/export/auth/export-$DATE.ldif
echo "Compressing data..."
cd ../store/export/auth/ 
tar -czf auth-$DATE.tar.gz export-$DATE.ldif
rm export-$DATE.ldif

echo "Finished, filename: export/auth/auth-$DATE.tar.gz"
