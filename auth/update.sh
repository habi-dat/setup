#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env

export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
export HABIDAT_EXTERNAL_NETWORK_DISABLE=

envsubst < docker-compose.yml > ../store/auth/docker-compose.yml
envsubst < config/bootstrap-update.ldif > ../store/auth/bootstrap/bootstrap.ldif
cp memberOf.ldif ../store/auth/memberOf.ldif

#DATE=$(date +"%Y%m%d%H%M")
#docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
#docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif ../store/export/auth/export-$DATE.ldif
#docker cp "$HABIDAT_DOCKER_PREFIX-user":/habidat-user/data/activationStore.json ../store/export/auth/activationStore-$DATE.json
#sed -f export.sed ../store/export/auth/export-$DATE.ldif > ../store/auth/bootstrap/import.ldif
# check if seded file is not empty
#if [ -s ../store/auth/bootstrap/import.ldif ]
#then#
#	rm ../store/export/auth/export-$DATE.ldif

echo "Pulling images and recreate containers..."

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d 

#docker cp ../store/export/auth/activationStore-$DATE.json "$HABIDAT_DOCKER_PREFIX-user":/habidat-user/data/activationStore.json
#rm ../store/export/auth/activationStore-$DATE.json

echo "Restarting user module..."
sleep 10
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" restart user
#else
#	echo "Exported LDIF is empty, abort update to prevent data loss..."	
#fi


