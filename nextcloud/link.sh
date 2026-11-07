#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): nextcloud gives auth its database password, its API URL
# and the discourse SSO secret, all from store/nextcloud/. Safe to repeat.

if [[ ! -f ../store/auth/docker-compose.yml ]]; then
  echo "auth is not installed; nothing to link."
  exit 0
fi

# shellcheck disable=SC1091
source ../store/nextcloud/passwords.env
# shellcheck disable=SC1091
source ../store/auth/passwords.env

touch ../store/auth/auth.env
sed -i '/NEXTCLOUD_DB_PASSWORD=/d; /NEXTCLOUD_API_URL=/d; /DISCOURSE_SSO_SECRET=/d' ../store/auth/auth.env
{
  echo "NEXTCLOUD_DB_PASSWORD=$HABIDAT_NEXTCLOUD_DB_PASSWORD"
  echo "NEXTCLOUD_API_URL=http://admin:$HABIDAT_ADMIN_PASSWORD@$HABIDAT_DOCKER_PREFIX-nextcloud/ocs/v1.php"
  echo "DISCOURSE_SSO_SECRET=$HABIDAT_DISCOURSE_SSO_SECRET"
} >> ../store/auth/auth.env

echo "Recreating the auth containers that read auth.env..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user user-worker
