#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

stop_one() {
  echo "Stopping website instance $1..."
  docker compose -f "$(website_compose "$1")" -p "$(website_project "$1")" stop
}

website_each_instance stop_one "${1:-}"
