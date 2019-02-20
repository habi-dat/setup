#!/bin/bash
set +x

mkdir -p ../store/nginx

envsubst < docker-compose.yml > ../store/nginx/docker-compose.yml

echo "Spinning up containers..."

docker-compose -f ../store/nginx/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nginx" up -d

if [ $HABIDAT_CREATE_SELFSIGNED == "true" ]
then
	echo "Generating self signed certificate..."
	openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=AT/ST=UA/L=Linz/O=habiDAT/CN=*.$HABIDAT_DOMAIN" \
    -keyout "../store/nginx/certificates/$HABIDAT_DOMAIN.key"  -out "../store/nginx/certificates/$HABIDAT_DOMAIN.crt"
fi