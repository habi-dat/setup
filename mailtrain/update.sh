#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/mailtrain/passwords.env

envsubst < docker-compose.yml > ../store/mailtrain/docker-compose.yml

echo "Pulling images and recreate containers..."

docker compose -f ../store/mailtrain/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mailtrain" up -d --pull
