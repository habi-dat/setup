#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env
source ../store/discourse/passwords.env

echo "Rebuilding and starting containers..."

# delete settings bootstrap to avoid overriding settings that have been made already
echo "" > ../store/discourse/bootstrap/discourse-settings.yml

../store/discourse/launcher rebuild $HABIDAT_DOCKER_PREFIX-discourse-data
../store/discourse/launcher rebuild $HABIDAT_DOCKER_PREFIX-discourse

docker network connect $HABIDAT_PROXY_NETWORK $HABIDAT_DOCKER_PREFIX-discourse