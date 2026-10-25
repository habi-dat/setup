#!/usr/bin/env bash
set -euo pipefail

# Stores the keys the sync container needs and restarts it. Run after the
# one-time browser setup printed by setup.sh. Values come from the environment
# when set (for unattended runs), otherwise they are prompted for:
#
#   VW_ORG_CLIENT_ID, VW_ORG_CLIENT_SECRET        organization API key
#   VW_BOT_CLIENT_ID, VW_BOT_CLIENT_SECRET        the bot's personal API key
#   VW_BOT_MASTER_PASSWORD                        the bot's master password

COMPOSE=(docker compose -f ../store/vaultwarden/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-vaultwarden")
CREDENTIALS=../store/vaultwarden/credentials.env
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

ask() {
  local var="$1" prompt="$2" secret="${3:-}"
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    echo "$var is not set and there is no terminal to ask for it." >&2
    exit 1
  fi
  local value
  if [[ "$secret" == "secret" ]]; then
    read -r -s -p "$prompt: " value </dev/tty
    echo >/dev/tty
  else
    read -r -p "$prompt: " value </dev/tty
  fi
  printf -v "$var" '%s' "$value"
}

ask VW_ORG_CLIENT_ID "Organization API key client_id (organization.<id>)"
ask VW_ORG_CLIENT_SECRET "Organization API key client_secret" secret
ask VW_BOT_CLIENT_ID "Bot personal API key client_id (user.<id>)"
ask VW_BOT_CLIENT_SECRET "Bot personal API key client_secret" secret
ask VW_BOT_MASTER_PASSWORD "Bot master password" secret

if [[ ! "$VW_ORG_CLIENT_ID" =~ ^organization\.($UUID_RE)$ ]]; then
  echo "The organization client_id must look like organization.<uuid>." >&2
  exit 1
fi
VW_ORG_ID="${BASH_REMATCH[1]}"
if [[ ! "$VW_BOT_CLIENT_ID" =~ ^user\.$UUID_RE$ ]]; then
  echo "The bot client_id must look like user.<uuid> (the bot's personal API key, not the organization's)." >&2
  exit 1
fi
for var in VW_ORG_CLIENT_SECRET VW_BOT_CLIENT_SECRET VW_BOT_MASTER_PASSWORD; do
  if [[ -z "${!var}" ]]; then
    echo "$var must not be empty." >&2
    exit 1
  fi
  # credentials.env is a compose env file; single-quoted values are taken
  # literally, which leaves a single quote as the only character to avoid.
  if [[ "${!var}" == *"'"* ]]; then
    echo "$var must not contain a single quote." >&2
    exit 1
  fi
done

umask 077
{
  echo "VW_ORG_ID=${VW_ORG_ID}"
  echo "VW_ORG_CLIENT_ID=${VW_ORG_CLIENT_ID}"
  echo "VW_ORG_CLIENT_SECRET='${VW_ORG_CLIENT_SECRET}'"
  echo "VW_BOT_CLIENT_ID=${VW_BOT_CLIENT_ID}"
  echo "VW_BOT_CLIENT_SECRET='${VW_BOT_CLIENT_SECRET}'"
  echo "VW_BOT_MASTER_PASSWORD='${VW_BOT_MASTER_PASSWORD}'"
} > "$CREDENTIALS"
echo "Stored credentials in store/vaultwarden/credentials.env."

echo "Planned changes of a first sync (dry run):"
"${COMPOSE[@]}" run --rm --no-deps sync --once --dry-run

echo "Starting the sync..."
"${COMPOSE[@]}" up -d --force-recreate sync
