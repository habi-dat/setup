#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env

render_versioned_template direktkredit "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 ../store/direktkredit/docker-compose.yml

echo "Pulling images and recreating containers (for all projects)..."

cd ../store/direktkredit
git pull
./update-projects.sh all
./update-projects.sh nginx
cd ../../direktkredit
