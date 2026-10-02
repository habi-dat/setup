#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

down_one() {
  echo "Stopping listmonk instance $1..."
  docker compose -f "$(listmonk_compose "$1")" -p "$(listmonk_project "$1")" down
}

listmonk_each_instance down_one "${1:-}"
