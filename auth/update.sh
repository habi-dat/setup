#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env

if [ -z $HABIDAT_EXISTING_BACKEND_NETWORK ]
then
	export HABIDAT_BACKEND_NETWORK="$HABIDAT_DOCKER_PREFIX-backend"
	export HABIDAT_EXTERNAL_NETWORK_DISABLE='#'
	export HABIDAT_INTERNAL_NETWORK_DISABLE=
else
	export HABIDAT_BACKEND_NETWORK="$HABIDAT_EXISTING_BACKEND_NETWORK"
	export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
	export HABIDAT_EXTERNAL_NETWORK_DISABLE=
fi

envsubst < docker-compose.yml > ../store/auth/docker-compose.yml
envsubst < config/bootstrap-update.ldif > ../store/auth/bootstrap/bootstrap.ldif

echo "Exporting ldap data..."

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" exec ldap slapcat -l /backup.ldif -H 'ldap:///???(&(!(objectClass=organizationalRole))(!(objectClass=dcObject))(!(objectClass=organizationalUnit)))'
docker cp "$HABIDAT_DOCKER_PREFIX-ldap":/backup.ldif ../store/auth/bootstrap/import.ldif
sed -f export.sed ../store/auth/bootstrap/import.ldif

echo "Pulling images and recreate containers..."

docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" down -v
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker-compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d 
