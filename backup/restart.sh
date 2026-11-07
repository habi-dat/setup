#!/usr/bin/env bash
set -euo pipefail

# The backup module runs no containers; restarting means re-enabling its timers.

# shellcheck source=lib/bootstrap.sh
source lib/bootstrap.sh
backup_enable_timers
