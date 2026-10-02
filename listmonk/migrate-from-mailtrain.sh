#!/usr/bin/env bash
# Copy one Mailtrain database into one Listmonk instance: lists, subscribers,
# SMTP (including the hourly send cap), HTML templates, campaign content, and
# uploaded files. Mailtrain is left running. Unsubscribe status is preserved
# per list. Built-in ZoneMTA and Amazon SES are not copied. Send history,
# automations, segments, and custom forms are not copied.
#
# Usage: ./migrate-from-mailtrain.sh <project-id> [--database <name>]
# --database names a MariaDB database on <prefix>-mailtrain-db that was not
# created by habidat-setup. The root password is read from that container and
# is not printed.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  echo "Usage: listmonk/migrate-from-mailtrain.sh <project-id> [--database <name>]" >&2
  exit 2
}

ID=""
DATABASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --database)
      [[ $# -ge 2 ]] || usage
      DATABASE="$2"
      shift 2
      ;;
    --database=*)
      DATABASE="${1#--database=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      [[ -z "$ID" ]] || usage
      ID="$1"
      shift
      ;;
  esac
done
[[ $# -eq 0 ]] || usage
[[ -n "$ID" ]] || usage

if [[ -n "$DATABASE" && ! "$DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Mailtrain database name must contain only letters, numbers, and underscores." >&2
  exit 1
fi

if [[ ! -f "$(listmonk_compose "$ID")" ]]; then
  echo "Listmonk instance ${ID} is not installed." >&2
  exit 1
fi

if [[ -z "${HABIDAT_DOCKER_PREFIX:-}" ]]; then
  echo "HABIDAT_DOCKER_PREFIX is not set." >&2
  exit 1
fi

listmonk_load_instance "$ID"

# shellcheck source=lib/api.sh
source "$(dirname "$0")/lib/api.sh"
listmonk_wait_http "$ID"

export MAILTRAIN_DB_CONTAINER="${HABIDAT_DOCKER_PREFIX}-mailtrain-db"
if [[ -n "$DATABASE" ]]; then
  export MAILTRAIN_DB_NAME="$DATABASE"
  # An external Mailtrain has no store/mailtrain and no <prefix>-mailtrain
  # container. The app containers are <prefix>-mailtrain-<project-id>.
  unset MAILTRAIN_CONTAINER || true
  if ! docker inspect -f '{{.State.Running}}' "$MAILTRAIN_DB_CONTAINER" 2>/dev/null | grep -qx true; then
    echo "Mailtrain database container ${MAILTRAIN_DB_CONTAINER} is not running." >&2
    exit 1
  fi
  MAILTRAIN_DB_PASSWORD="$(
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$MAILTRAIN_DB_CONTAINER" \
      | sed -n 's/^MYSQL_ROOT_PASSWORD=//p' \
      | head -n 1
  )"
  if [[ -z "$MAILTRAIN_DB_PASSWORD" ]]; then
    echo "Mailtrain database container ${MAILTRAIN_DB_CONTAINER} has no MYSQL_ROOT_PASSWORD." >&2
    exit 1
  fi
  export MAILTRAIN_DB_PASSWORD
else
  if [[ ! -d "$LISTMONK_REPO_ROOT/store/mailtrain" ]] || [[ ! -f "$LISTMONK_REPO_ROOT/store/mailtrain/passwords.env" ]]; then
    echo "Mailtrain is not installed. Install it first, pass --database, or omit --from-mailtrain." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$LISTMONK_REPO_ROOT/store/mailtrain/passwords.env"
  export MAILTRAIN_CONTAINER="${HABIDAT_DOCKER_PREFIX}-mailtrain"
  export MAILTRAIN_DB_NAME="${HABIDAT_DOCKER_PREFIX}"
  export MAILTRAIN_DB_PASSWORD="${HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD}"
fi

export LISTMONK_CONTAINER
LISTMONK_CONTAINER="$(listmonk_container "$ID")"
export LISTMONK_CURL_IMAGE="${LISTMONK_CURL_IMAGE:-curlimages/curl:8.13.0}"
export HABIDAT_LISTMONK_API_USER HABIDAT_LISTMONK_API_TOKEN

echo "Importing Mailtrain database ${MAILTRAIN_DB_NAME} into listmonk instance ${ID}..."
echo "Mailtrain will be left running."
python3 "$(dirname "$0")/lib/import_mailtrain.py"
