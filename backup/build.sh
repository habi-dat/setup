#!/usr/bin/env bash
set -euo pipefail

# Builds the pinned borg 1.4 image from borg/Dockerfile.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh
backup_build_image
