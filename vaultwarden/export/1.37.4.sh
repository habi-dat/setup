#!/usr/bin/env bash
set -euo pipefail

# Archives the /data volume (SQLite database, RSA keys, attachments, sends,
# config.json). Vaultwarden is stopped meanwhile so the database is consistent.

BACKUP_DIR="$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/vaultwarden"
COMPOSE=(docker compose -f ../store/vaultwarden/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-vaultwarden")
DATE=$(date +"%Y%m%d%H%M")

mkdir -p "$BACKUP_DIR"

echo "Stopping Vaultwarden..."
"${COMPOSE[@]}" stop sync vaultwarden
trap '"${COMPOSE[@]}" start vaultwarden sync' EXIT

echo "Archiving data volume..."
"${COMPOSE[@]}" run --rm --no-deps -T -v "$BACKUP_DIR:/backup" --entrypoint tar \
  vaultwarden czf "/backup/vaultwarden-$DATE.tar.gz" -C /data .

echo "Export written to $BACKUP_DIR/vaultwarden-$DATE.tar.gz"
