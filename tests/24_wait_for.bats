#!/usr/bin/env bats
# lib/wait-for.sh -- readiness polling.
#
# This replaced the fixed `sleep 30` / `sleep 120` waits in the module scripts.
# Those were simultaneously too long on a warm machine and too short on a cold
# one, and when too short the *following* command failed with something
# unrelated to the real cause. The value of the replacement is entirely in its
# edge cases, so they are pinned here.

load helpers/load

WAIT_FOR="$BATS_TEST_DIRNAME/../lib/wait-for.sh"

@test "returns immediately when the condition already holds" {
  run "$WAIT_FOR" "an already-true condition" 30 'true'
  assert_success
  assert_output --partial "ready after 0s"
}

@test "returns as soon as the condition becomes true" {
  local flag="$BATS_TEST_TMPDIR/ready"
  ( sleep 2; touch "$flag" ) &

  HABIDAT_WAIT_INTERVAL=1 run "$WAIT_FOR" "a delayed flag" 30 "[[ -e '$flag' ]]"
  assert_success
  assert_output --partial "ready after"
  # Must not have waited for the whole timeout.
  refute_output --partial "ready after 30s"
}

@test "fails after the timeout rather than hanging" {
  HABIDAT_WAIT_INTERVAL=1 run "$WAIT_FOR" "something that never comes" 2 'false'
  assert_failure
  assert_output --partial "Timed out after"
  assert_output --partial "something that never comes"
}

@test "shows the failing condition and its output on timeout" {
  # This is the whole point: a CI log must say why the wait never succeeded.
  HABIDAT_WAIT_INTERVAL=1 run "$WAIT_FOR" "a broken service" 2 'echo "connection refused"; false'
  assert_failure
  assert_output --partial "Condition:"
  assert_output --partial "last attempt"
  assert_output --partial "connection refused"
}

@test "a condition's own output is not repeated once per poll attempt" {
  # Otherwise a service that takes two minutes to start floods the log with
  # identical failures. With a 1s interval and a 2s timeout the loop runs the
  # condition ~3 times, yet NOISE may appear exactly three times: once in the
  # echoed `Condition:` line, once in the `bash -x` trace of the final attempt,
  # and once as that attempt's actual output. Per-attempt output would be more.
  HABIDAT_WAIT_INTERVAL=1 run "$WAIT_FOR" "a noisy check" 2 'echo NOISE; false'
  assert_failure
  assert_equal "$(printf '%s\n' "$output" | grep -c NOISE)" "3"
}

@test "rejects a malformed invocation" {
  run "$WAIT_FOR" "only two args" 5
  assert_failure
  assert_output --partial "usage:"
}

@test "the description appears in the waiting message" {
  run "$WAIT_FOR" "PostgreSQL" 5 'true'
  assert_success
  assert_output --partial "Waiting for PostgreSQL"
}

# ---------------------------------------------------------------------------
# Adoption
# ---------------------------------------------------------------------------

@test "no fixed sleep remains in a module's install path" {
  # setup.sh is what the integration job exercises; a fixed sleep there is the
  # failure mode this work removed.
  local failures=() mod hits
  while IFS= read -r mod; do
    hits="$(grep -n '^[[:space:]]*sleep [0-9]' "$REPO_ROOT/$mod/setup.sh" 2>/dev/null || true)"
    [[ -n "$hits" ]] && failures+=("$mod/setup.sh: $hits")
  done < <(repo_modules)

  # RATCHET: discourse still sleeps 10s before reading its container IP. It is
  # not covered by the integration job, so it was left alone deliberately.
  local known="discourse/setup.sh"
  local found
  found="$(printf '%s\n' "${failures[@]+"${failures[@]}"}" | cut -d: -f1 | grep -v '^$' || true)"
  assert_equal "$found" "$known"
}

@test "the live nextcloud upgrade and import paths poll instead of sleeping" {
  # Current nextcloud/version may be a config-only step (34.0.4.1 keeps the
  # 34.0.4 image and only runs afterupdate). That migrate has nothing to wait
  # for. The last migrate that pulls/recreates containers, and the import
  # script resolve_versioned_script would pick, still must poll.
  local version migrate import live_migrate f ver
  version="$(repo_module_version nextcloud)"
  migrate="$REPO_ROOT/nextcloud/versions/$version/migrate.sh"

  [[ -f "$migrate" ]]
  run grep -q 'sleep 120' "$migrate"
  assert_failure

  import=""
  for f in "$REPO_ROOT/nextcloud/import/"*.sh; do
    [[ -f "$f" ]] || continue
    ver="$(basename "$f" .sh)"
    [[ "$(printf '%s\n%s' "$ver" "$version" | sort -V | tail -n1)" == "$version" ]] || continue
    if [[ -z "$import" ]] || [[ "$(printf '%s\n%s' "$(basename "$import" .sh)" "$ver" | sort -V | tail -n1)" == "$ver" ]]; then
      import="$f"
    fi
  done
  [[ -n "$import" ]]
  run grep -c 'wait-for.sh' "$import"
  assert_success
  refute_output "0"
  run grep -q 'sleep 120' "$import"
  assert_failure

  live_migrate=""
  while IFS= read -r f; do
    grep -qE 'docker compose .*[[:space:]](up|pull)' "$f" || continue
    live_migrate="$f"
  done < <(find "$REPO_ROOT/nextcloud/versions" -name migrate.sh -type f | sort -V)

  [[ -n "$live_migrate" ]]
  run grep -c 'wait-for.sh' "$live_migrate"
  assert_success
  refute_output "0"
  run grep -q 'sleep 120' "$live_migrate"
  assert_failure
}

@test "the timeout trace shows which clause of a multi-part condition failed" {
  # Regression test. The integration job twice reported only "timed out" because
  # the condition ended in `grep -q`, which is silent, so the log never said
  # which clause was false. Tracing the final attempt makes that visible.
  HABIDAT_WAIT_INTERVAL=1 run "$WAIT_FOR" "a multi-clause check" 1 \
    '[ -e /definitely/absent ] && echo reached-second-clause'
  assert_failure
  assert_output --partial "traced"
  assert_output --partial "/definitely/absent"
  # Short-circuited: the trace shows the first clause and nothing after it. The
  # string itself still appears in the echoed `Condition:` line, so assert on the
  # absence of its *trace* line rather than on the whole output.
  refute_line --partial "+ echo reached-second-clause"
}
