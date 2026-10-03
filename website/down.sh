#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

down_one() {
  echo "Stopping website instance $1..."
  docker compose -f "$(website_compose "$1")" -p "$(website_project "$1")" down
}

website_each_instance down_one "${1:-}"
