#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env

git clone https://github.com/soudis/habidat-direktkredit-platform.git ../store/direktkredit

../lib/render.py config/settings.env.j2 ../store/direktkredit/settings.env
../lib/render.py docker-compose.yml.j2 ../store/direktkredit/docker-compose.yml

echo "Spinning up containers..."

docker network create "$HABIDAT_DOCKER_PREFIX-direktkredit-proxy"
cd ../store/direktkredit
./bootstrap.sh
cd ../../direktkredit
docker compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" pull
docker compose -f ../store/direktkredit/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-direktkredit" up -d

echo "Add link to nextcloud..."
sed -i '/HABIDAT_DIREKTKREDIT_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_DIREKTKREDIT_SUBDOMAIN=$HABIDAT_DIREKTKREDIT_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
# nextcloud was just recreated to pick up the new subdomain; the external-site
# helper below calls occ, which fails while it is still starting.
../lib/wait-for.sh "nextcloud" 300 \
  "docker compose -f ../store/nextcloud/docker-compose.yml \
     -p '$HABIDAT_DOCKER_PREFIX-nextcloud' exec -T --user www-data \
     nextcloud php occ status | grep -q 'installed: true'"
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" exec --user www-data nextcloud /habidat/habidat-add-externalsite.sh direktkredit
