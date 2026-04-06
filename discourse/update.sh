#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env
source ../store/discourse/passwords.env

echo "Rebuilding and starting containers..."

j2 config/discourse-settings-update.yml.j2 -o ../store/discourse/bootstrap/discourse-settings.yml

cd ../store/discourse
git pull

./launcher rebuild "$HABIDAT_DOCKER_PREFIX-discourse-data"
./launcher rebuild "$HABIDAT_DOCKER_PREFIX-discourse"

cd ../../discourse

docker network connect "$HABIDAT_PROXY_NETWORK" "$HABIDAT_DOCKER_PREFIX-discourse"
