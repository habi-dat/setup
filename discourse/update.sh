#!/bin/bash
set -e

source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env
source ../store/discourse/passwords.env

envsubst < docker-compose.yml > ../store/discourse/docker-compose.yml

echo "Pulling images and recreate containers..."

docker-compose -f ../store/discourse/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-discourse" up -d --pull
