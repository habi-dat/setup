#!/usr/bin/env bash
set -euo pipefail

# Pulls the direktkredit code and recreates the containers of all projects,
# without re-rendering templates or touching store/direktkredit/version.

echo "Pulling images and recreating containers (for all projects)..."

cd ../store/direktkredit
git pull
./update-projects.sh all
./update-projects.sh nginx
