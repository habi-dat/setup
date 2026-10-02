#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

pull_one() {
  echo "Pulling images for listmonk instance $1..."
  docker compose -f "$(listmonk_compose "$1")" -p "$(listmonk_project "$1")" pull
}

listmonk_each_instance pull_one "${1:-}"
