#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

up_one() {
  echo "Starting listmonk instance $1..."
  docker compose -f "$(listmonk_compose "$1")" -p "$(listmonk_project "$1")" up -d
}

listmonk_each_instance up_one "${1:-}"
