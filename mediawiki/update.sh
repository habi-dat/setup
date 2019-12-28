#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/mediawiki/passwords.env

envsubst < docker-compose.yml > ../store/mediawiki/docker-compose.yml

echo "Pulling images and recreate containers..."

docker-compose -f ../store/mediawiki/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki" up -d --pull
