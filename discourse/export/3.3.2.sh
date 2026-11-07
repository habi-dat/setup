#!/usr/bin/env bash
set -euo pipefail

# Dumps the forum database from the data container and names the web
# container's /shared volume (uploads, logs). The data container's own volume
# holds the raw PostgreSQL and Redis files and is replaced by the dump. See
# lib/export.sh for the contract.

echo "Dumping the forum database..."
docker exec -u postgres "$HABIDAT_DOCKER_PREFIX-discourse-data" \
  pg_dump --clean --if-exists --create discourse > "$HABIDAT_EXPORT_DIR/db.sql"

export_volume "$HABIDAT_DOCKER_PREFIX-discourse"
