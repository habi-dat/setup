#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

restart_one() {
  echo "Restarting website instance $1..."
  docker compose -f "$(website_compose "$1")" -p "$(website_project "$1")" restart
}

website_each_instance restart_one "${1:-}"
