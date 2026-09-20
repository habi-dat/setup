#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

echo "Copying assets to store..."
# Keep the bind-mounted directory inode. `rm -rf` + `cp -r` creates a new
# directory while nextcloud is still running, so the container stays mounted
# on the deleted inode and /habidat/habidat-afterupdate.sh is gone until
# the bind is remounted.
mkdir -p ../store/nextcloud/assets
find ../store/nextcloud/assets -mindepth 1 -delete
cp -a assets/. ../store/nextcloud/assets/
chmod +x ../store/nextcloud/assets/habidat-bootstrap.sh
chmod +x ../store/nextcloud/assets/habidat-afterupdate.sh
chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh

# Remount /habidat. A previous failed 34.0.4.1 run already replaced the
# assets directory inode; copying in place would then update a host path
# the running container cannot see. Image stays 34.0.4.
echo "Recreating Nextcloud to remount /habidat (image stays 34.0.4)..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d --force-recreate --no-deps nextcloud cron

../lib/wait-for.sh "Nextcloud container (occ usable)" 300 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T --user www-data \
     nextcloud php occ status 2>&1 | grep -qi installed"

echo "Applying SAML/LDAP profile mappings and removing discoursesso..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T --user www-data nextcloud /habidat/habidat-afterupdate.sh
