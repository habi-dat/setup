#!/usr/bin/env bash
set -euo pipefail

# Turns the nightly snapshot and the watch timer on.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh
backup_enable_timers
