#!/usr/bin/env bash
set -euo pipefail

# Pulls the discourse_docker checkout and rebuilds both containers. Same as
# update.sh without re-rendering the settings file. The rebuild is slow and
# takes discourse down while it runs.

source ../store/nginx/networks.env

cd ../store/discourse
git pull

./launcher rebuild "$HABIDAT_DOCKER_PREFIX-discourse-data"
./launcher rebuild "$HABIDAT_DOCKER_PREFIX-discourse"

cd ../../discourse

docker network connect "$HABIDAT_PROXY_NETWORK" "$HABIDAT_DOCKER_PREFIX-discourse"
