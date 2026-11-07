#!/usr/bin/env bash
set -euo pipefail

# Restores one website instance ($1). Its data came back with
# store/website/<id>/; only the container needs to be recreated.

# shellcheck source=../lib/common.sh
source lib/common.sh

ID="${1:?website restore needs an instance id}"
COMPOSE=(docker compose -f "$(website_compose "$ID")" -p "$(website_project "$ID")")

"${COMPOSE[@]}" rm --stop --force
"${COMPOSE[@]}" up -d
