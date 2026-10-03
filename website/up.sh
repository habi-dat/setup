#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

up_one() {
  echo "Starting website instance $1..."
  docker compose -f "$(website_compose "$1")" -p "$(website_project "$1")" up -d
}

website_each_instance up_one "${1:-}"
