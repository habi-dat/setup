#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): discourse gives auth its API key and URL from
# store/discourse/passwords.env. Safe to repeat.

if [[ ! -f ../store/auth/docker-compose.yml ]]; then
  echo "auth is not installed; nothing to link."
  exit 0
fi

# shellcheck disable=SC1091
source ../store/discourse/passwords.env
if [[ -z "${HABIDAT_DISCOURSE_API_KEY:-}" ]]; then
  echo "store/discourse/passwords.env has no API key." >&2
  exit 1
fi

touch ../store/auth/auth.env
sed -i '/DISCOURSE_API_KEY=/d; /DISCOURSE_URL=/d; /DISCOURSE_API_USERNAME=/d' ../store/auth/auth.env
{
  echo "DISCOURSE_API_KEY=$HABIDAT_DISCOURSE_API_KEY"
  echo "DISCOURSE_URL=http://$HABIDAT_DOCKER_PREFIX-discourse:80"
  echo "DISCOURSE_API_USERNAME=system"
} >> ../store/auth/auth.env

echo "Recreating the auth containers that read auth.env..."
docker compose -f ../store/auth/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-auth" up -d user user-worker
