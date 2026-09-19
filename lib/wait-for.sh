#!/usr/bin/env bash
# Poll a readiness condition until it holds, or give up with a useful message.
#
#   ../lib/wait-for.sh <description> <timeout-seconds> <shell-command>
#
# <shell-command> is run repeatedly with `bash -c` until it exits 0. Quote it as
# a single argument; single quotes are usually easiest.
#
#   ../lib/wait-for.sh "PostgreSQL" 120 \
#     'docker compose -f "$F" -p "$P" exec -T user-db pg_isready -U postgres'
#
# Why this exists: the module scripts used to wait with fixed `sleep` calls --
# 30 seconds for a database, 120 for a Nextcloud upgrade. Those are
# simultaneously too long on a warm machine and too short on a cold one that is
# still pulling images, and when they are too short the *next* command fails
# with something unrelated to the real cause ("Nextcloud is not installed"
# rather than "Nextcloud is still starting"). Polling reports the actual
# problem, and returns as soon as the service is up.
#
# On timeout the condition is run once more with its output shown, so a CI log
# says why it never became ready.

set -uo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: wait-for.sh <description> <timeout-seconds> <shell-command>" >&2
  exit 2
fi

description="$1"
timeout="$2"
condition="$3"

interval="${HABIDAT_WAIT_INTERVAL:-2}"
elapsed=0

printf 'Waiting for %s (up to %ss)...\n' "$description" "$timeout"

while true; do
  if bash -c "$condition" >/dev/null 2>&1; then
    printf '%s ready after %ss.\n' "$description" "$elapsed"
    exit 0
  fi

  if [[ "$elapsed" -ge "$timeout" ]]; then
    printf 'Timed out after %ss waiting for %s.\n' "$elapsed" "$description" >&2
    printf 'Condition: %s\n' "$condition" >&2
    # Traced, so a condition built from several clauses shows *which* one failed.
    # Without this a condition ending in `grep -q` prints nothing at all and the
    # timeout says only that it never succeeded.
    printf -- '--- last attempt (traced) ---\n' >&2
    bash -xc "$condition" 2>&1 | tail -n 40 >&2 || true
    exit 1
  fi

  sleep "$interval"
  elapsed=$((elapsed + interval))
done
