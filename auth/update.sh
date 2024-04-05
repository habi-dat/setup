#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env

export HABIDAT_INTERNAL_NETWORK_DISABLE='#'
export HABIDAT_EXTERNAL_NETWORK_DISABLE=

if [ $HABIDAT_EXPOSE_LDAP == "true" ] 
then
  export HABIDAT_LDAP_PORT_MAPPING='127.0.0.1:389:389'
else
  export HABIDAT_LDAP_PORT_MAPPING='389'
fi

envsubst < docker-compose.yml > ../store/auth/docker-compose.yml
envsubst < config/bootstrap-update.ldif > ../store/auth/bootstrap/bootstrap.ldif
cp config/memberOf.ldif ../store/auth/memberOf.ldif

echo "Pulling images and recreate containers..."

docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" pull
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d 

echo "Restarting user module..."
sleep 10
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" restart user



