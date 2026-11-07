#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): dokuwiki tells nextcloud its subdomain, for the app menu.
# Safe to repeat. The external-site tile itself lives in nextcloud's database and
# comes back with nextcloud.

if [[ ! -f ../store/nextcloud/docker-compose.yml ]]; then
  echo "nextcloud is not installed; nothing to link."
  exit 0
fi

touch ../store/nextcloud/nextcloud.env
sed -i '/HABIDAT_DOKUWIKI_SUBDOMAIN/d' ../store/nextcloud/nextcloud.env
echo "HABIDAT_DOKUWIKI_SUBDOMAIN=$HABIDAT_DOKUWIKI_SUBDOMAIN" >> ../store/nextcloud/nextcloud.env

echo "Recreating the nextcloud container that reads nextcloud.env..."
docker compose -f ../store/nextcloud/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-nextcloud" up -d nextcloud
