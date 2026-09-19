#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"

echo "Copying assets to store..."
rm -rf ../store/nextcloud/assets
cp -r assets ../store/nextcloud/assets
chmod +x ../store/nextcloud/assets/habidat-bootstrap.sh
chmod +x ../store/nextcloud/assets/habidat-afterupdate.sh
chmod +x ../store/nextcloud/assets/habidat-add-externalsite.sh

echo "Applying SAML/LDAP profile mappings and removing discoursesso (Nextcloud image stays 34.0.4)..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-afterupdate.sh
