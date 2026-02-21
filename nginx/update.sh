#!/bin/bash
set -e

source ../store/nginx/networks.env

if [ -z $HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK ]
then

	if [ "$HABIDAT_LETSENCRYPT" != "true" ]
	then
		export HABIDAT_LETSENCRYPT_DISABLE='#'
	fi

	envsubst < docker-compose.yml > ../store/nginx/docker-compose.yml

	cp user.conf ../store/nginx
	cp cors_map.conf ../store/nginx
	cp cookies.conf ../store/nginx

	echo "Pulling images and recreate containers..."

	docker compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" pull
	docker compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" up -d

else

    echo "Using existing nginx generator and proxy network, skipping module containers..."
    echo "export HABIDAT_PROXY_NETWORK=$HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK" > ../store/nginx/networks.env

fi