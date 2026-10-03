#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

start_one() {
  echo "Starting website instance $1..."
  docker compose -f "$(website_compose "$1")" -p "$(website_project "$1")" start
}

website_each_instance start_one "${1:-}"
