#!/usr/bin/env bash
# End-to-end smoke test: builds the sync image, starts Vaultwarden 1.37.4 + OpenLDAP, bootstraps
# an organization like the manual setup does, then runs the sync through several LDAP changes.
# KEEP=1 leaves the containers running for inspection.
set -euo pipefail
cd "$(dirname "$0")"
SMOKE_UID=$(id -u)
SMOKE_GID=$(id -g)
export SMOKE_UID SMOKE_GID

dc() { docker compose "$@"; }
cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then
    dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf .out
  fi
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
ldapmod() { dc exec -T ldap ldapmodify -x -D cn=admin,dc=habidat,dc=local -w admin "$@" >/dev/null; }
sync() { dc run --rm -T sync --once "$@"; }
verify() { dc run --rm -T tools /smoke/verify.ts "$1"; }

rm -rf .out
dc --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
step "build and start"
dc --profile tools build
dc up -d --wait ldap vaultwarden

step "seed LDAP, bootstrap Vaultwarden"
ldapmod -a < ldif/seed.ldif
dc run --rm -T tools /smoke/bootstrap.ts

step "dry run changes nothing"
sync --dry-run
verify dry

step "run 1: import, groups, collections, confirm, promote, disable unknown"
sync
verify run1

step "run 2: rename group, delete group and user, restore tampered access"
ldapmod < ldif/phase2.ldif
verify tamper
sync
verify run2

step "run 3: user returns"
ldapmod < ldif/phase3.ldif
sync
verify run3

step "smoke test passed"
