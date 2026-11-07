#!/usr/bin/env bash
set -euo pipefail

# Link step (ADR 0007): auth adds its backend network to nginx's networks.env,
# which every module sources. Safe to repeat.

if [[ -z "${HABIDAT_EXISTING_BACKEND_NETWORK:-}" ]]; then
  network="$HABIDAT_DOCKER_PREFIX-backend"
else
  network="$HABIDAT_EXISTING_BACKEND_NETWORK"
fi

touch ../store/nginx/networks.env
sed -i '/HABIDAT_BACKEND_NETWORK=/d' ../store/nginx/networks.env
echo "export HABIDAT_BACKEND_NETWORK=$network" >> ../store/nginx/networks.env
echo "networks.env: backend network is $network."
