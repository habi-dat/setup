#!/usr/bin/env bash
set -euo pipefail

# Dokuwiki keeps pages, configuration, plugins and templates as files in four
# volumes; there is no database to dump. See lib/export.sh for the contract.

PROJECT="$HABIDAT_DOCKER_PREFIX-dokuwiki"

for volume in data config plugins templates; do
  export_volume "${PROJECT}_$volume"
done
