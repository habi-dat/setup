#!/bin/bash
set +x

mkdir -p ../store/nginx/certificates


if [ -z $HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK ]
then

    echo "export HABIDAT_PROXY_NETWORK=$HABIDAT_DOCKER_PREFIX-proxy" > ../store/nginx/networks.env

	echo "Create environment files..."
	if [ $HABIDAT_LETSENCRYPT != "true" ]
	then
		export HABIDAT_LETSENCRYPT_DISABLE='#'
	fi

	envsubst < docker-compose.yml > ../store/nginx/docker-compose.yml

	cp nginx.conf ../store/nginx

	echo "Spinning up containers..."

	docker compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" up -d

	if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
	then
		echo "Generating self signed certificate..."
		mkcert -key-file "../store/nginx/certificates/$HABIDAT_DOMAIN.key" -cert-file "../store/nginx/certificates/$HABIDAT_DOMAIN.crt" "*.$HABIDAT_DOMAIN"
	fi

else

    echo "Using existing nginx generator and proxy network, skipping module containers..."
    echo "export HABIDAT_PROXY_NETWORK=$HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK" > ../store/nginx/networks.env

fi