#!/usr/bin/env bash
set -euo pipefail

# Turns the nightly snapshot and the watch timer off. Snapshots in the
# repository are untouched.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh
backup_disable_timers
