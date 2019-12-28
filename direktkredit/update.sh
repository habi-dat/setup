#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/direktkredit/passwords.env

envsubst < docker-compose.yml > ../store/direktkredit/docker-compose.yml

echo "Pulling images and recreate containers..."

docker-compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" up -d --pull
