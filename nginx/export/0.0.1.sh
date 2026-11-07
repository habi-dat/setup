#!/usr/bin/env bash
set -euo pipefail

# Certificates and the rendered configuration live in store/nginx/. Of the
# volumes, vhost.d holds per-host settings the letsencrypt companion writes, and
# dhparam is slow to generate again; html only holds ACME challenges. With
# HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK there are no nginx containers at all.
# See lib/export.sh for the contract.

if [[ ! -f ../store/nginx/docker-compose.yml ]]; then
  echo "nginx runs outside habidat; only store/nginx/ is backed up."
  exit 0
fi

export_volume "$HABIDAT_DOCKER_PREFIX-nginx_vhost"
export_volume "$HABIDAT_DOCKER_PREFIX-nginx_dhparam"
