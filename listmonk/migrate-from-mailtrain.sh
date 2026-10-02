#!/usr/bin/env bash
# Copy every Mailtrain list, subscriber and SMTP send configuration into one
# Listmonk instance, including the hourly send cap. Mailtrain is left running.
# Unsubscribe status is preserved per list. Built-in ZoneMTA and Amazon SES
# are not copied.
#
# Usage: ./migrate-from-mailtrain.sh <project-id>
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: listmonk/migrate-from-mailtrain.sh <project-id>" >&2
  exit 2
fi

ID="$1"

if [[ ! -f "$(listmonk_compose "$ID")" ]]; then
  echo "Listmonk instance ${ID} is not installed." >&2
  exit 1
fi

if [[ ! -d "$LISTMONK_REPO_ROOT/store/mailtrain" ]] || [[ ! -f "$LISTMONK_REPO_ROOT/store/mailtrain/passwords.env" ]]; then
  echo "Mailtrain is not installed. Install it first, or omit --from-mailtrain." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$LISTMONK_REPO_ROOT/store/mailtrain/passwords.env"
listmonk_load_instance "$ID"

# shellcheck source=lib/api.sh
source "$(dirname "$0")/lib/api.sh"
listmonk_wait_http "$ID"

export MAILTRAIN_CONTAINER="${HABIDAT_DOCKER_PREFIX}-mailtrain"
export MAILTRAIN_DB_CONTAINER="${HABIDAT_DOCKER_PREFIX}-mailtrain-db"
export MAILTRAIN_DB_NAME="${HABIDAT_DOCKER_PREFIX}"
export MAILTRAIN_DB_PASSWORD="${HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD}"
export LISTMONK_CONTAINER
LISTMONK_CONTAINER="$(listmonk_container "$ID")"
export LISTMONK_CURL_IMAGE="${LISTMONK_CURL_IMAGE:-curlimages/curl:8.13.0}"
export HABIDAT_LISTMONK_API_USER HABIDAT_LISTMONK_API_TOKEN

echo "Importing Mailtrain lists and subscribers into listmonk instance ${ID}..."
echo "Mailtrain will be left running."
python3 "$(dirname "$0")/lib/import_mailtrain.py"
