#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

pull_one() {
  local compose
  compose="$(website_compose "$1")"
  if grep -q '^    build:' "$compose"; then
    echo "Building website image for instance $1..."
    docker compose -f "$compose" -p "$(website_project "$1")" build
  else
    echo "Pulling website image for instance $1..."
    docker compose -f "$compose" -p "$(website_project "$1")" pull
  fi
}

website_each_instance pull_one "${1:-}"
