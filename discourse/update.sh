#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env
source ../store/discourse/passwords.env

envsubst < docker-compose.yml > ../store/discourse/docker-compose.yml

echo "Pulling images and recreate containers..."

docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" pull
docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" up -d 

echo "Waiting for discourse container to initialize (this can take several minutes)..."
sleep 10	
# wait until discourse bootstrap is done
until nc -z $(docker inspect "$HABIDAT_DOCKER_PREFIX-discourse" | grep IPAddress | tail -n1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}') 3000
do
	sleep .5	
done
