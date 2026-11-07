#!/usr/bin/env bash
set -euo pipefail

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/nextcloud/passwords.env

COMPOSE_FILE="../store/nextcloud/docker-compose.yml"
COMPOSE_PROJECT="$HABIDAT_DOCKER_PREFIX-nextcloud"
ANTIVIRUS_CONTAINER="$HABIDAT_DOCKER_PREFIX-nextcloud-antivirus"

# ---------------------------------------------------------------------------
# 35.0.2 -> 35.0.2.1: no Nextcloud upgrade, only the stack around it.
#
# - The nextcloud image is tagged with the major version only (nextcloud:35),
#   so ./habidat.sh fix nextcloud pulls the newest 35.x from now on. If a newer
#   35.x than 35.0.2 is out, this step already moves to it (a minor update,
#   run by the image entrypoint like any other).
# - The antivirus container runs the official clamav/clamav:1.5 image instead
#   of dinkel/clamavd, which has not been updated since 2018 (ClamAV 0.100.2
#   on Debian 9) and can no longer download virus signatures. The signatures
#   now live in the "clamav" volume. Nextcloud's files_antivirus settings stay
#   as they are: same container name, same port 3310.
# - Neither the antivirus nor nextcloud publishes a port on the host any more.
#   Both were published on a random port on every interface, past the
#   firewall; nginx and nextcloud reach them over the docker networks.
# ---------------------------------------------------------------------------

render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  docker-compose.yml.j2 "$COMPOSE_FILE"

render_versioned_template nextcloud "$HABIDAT_MIGRATE_VERSION" \
  config/mariadb.cnf.j2 ../store/nextcloud/mariadb.cnf

echo "Pulling images and recreating containers..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d

# The entrypoint runs `occ upgrade` when the image version changes and holds the
# instance in maintenance mode while it does.
../lib/wait-for.sh "Nextcloud upgrade" 900 \
  "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T --user www-data \
     nextcloud php occ status | grep -q 'installed: true' &&
   docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT' exec -T --user www-data \
     nextcloud php occ status | grep -q 'maintenance: false'"

# The first start downloads the signature database before clamd listens.
# Uploads are scanned as soon as clamd is up; until then files_antivirus only
# logs that it cannot reach the scanner.
../lib/wait-for.sh "ClamAV (signature download and start)" 600 \
  "docker inspect -f '{{.State.Health.Status}}' '$ANTIVIRUS_CONTAINER' | grep -qx healthy" \
  || echo "WARNING: ClamAV is not healthy yet, check 'docker logs $ANTIVIRUS_CONTAINER'."

echo "Installing dependencies in container..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec nextcloud bash -c \
  "apt-get update && apt-get -y install jq && apt-get clean && rm -rf /var/lib/apt/lists/*"

echo "Running post-update configuration..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud /habidat/habidat-afterupdate.sh

echo "DB updates..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-indices
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-columns
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec --user www-data nextcloud php occ db:add-missing-primary-keys

echo "Removing the old antivirus image..."
docker image rm dinkel/clamavd 2>/dev/null || true
