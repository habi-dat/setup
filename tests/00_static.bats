#!/usr/bin/env bats
# Static analysis of every shell script in the repository.
#
# Two gates:
#   - bash -n on everything: a syntax error in a migrate.sh is only otherwise
#     discovered partway through a user's upgrade.
#   - shellcheck at error severity on everything, and at warning severity on the
#     CLI and lib/ where correctness matters most. Module scripts still carry
#     warning-level findings, so those are held at a recorded baseline that can
#     shrink but not grow.

load helpers/load

# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------

@test "every shell script parses" {
  local script failures=()

  while IFS= read -r script; do
    run bash -n "$REPO_ROOT/$script"
    [[ "$status" -eq 0 ]] || failures+=("$script: $output")
  done < <(repo_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "scripts with syntax errors:" "${failures[@]}"
}

@test "every test helper parses" {
  local script failures=()

  while IFS= read -r script; do
    run bash -n "$REPO_ROOT/$script"
    [[ "$status" -eq 0 ]] || failures+=("$script: $output")
  done < <(repo_test_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "test helpers with syntax errors:" "${failures[@]}"
}

@test "shellcheck reports no warning-level findings in the test helpers" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  # SC2154 is expected throughout: `output`, `status`, `lines` and `stderr` are
  # set by bats' own `run`, which shellcheck cannot see.
  run bash -c "cd '$REPO_ROOT' && shellcheck -x -s bash -S warning -e SC2154 -f gcc \$(
    find tests -type f \\( -name '*.sh' -o -name '*.bash' \\) | sort
  ) 2>&1"

  if [[ "$status" -ne 0 ]]; then
    { echo "shellcheck findings in the test helpers:"; printf '%s\n' "$output"; } | fail
  fi
}

# ---------------------------------------------------------------------------
# shellcheck
# ---------------------------------------------------------------------------

@test "shellcheck reports no error-level findings anywhere" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  run bash -c "cd '$REPO_ROOT' && shellcheck -x -s bash -S error -f gcc \$(
    find . -name '*.sh' -type f -not -path './node_modules/*' -not -path './store/*'
  ) 2>&1"

  if [[ "$status" -ne 0 ]]; then
    { echo "shellcheck error-level findings:"; printf '%s\n' "$output"; } | fail
  fi
}

@test "shellcheck reports no warning-level findings in habidat.sh or lib/" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  run bash -c "cd '$REPO_ROOT' && shellcheck -x -s bash -S warning -f gcc habidat.sh lib/*.sh 2>&1"

  if [[ "$status" -ne 0 ]]; then
    { echo "shellcheck findings in the CLI core:"; printf '%s\n' "$output"; } | fail
  fi
}

@test "warning-level findings in module scripts have not grown" {
  # A ratchet rather than a wall: the existing findings are almost entirely
  # SC2155 (declare-and-assign) in the password-generation blocks, which is not
  # worth churning production scripts over right now. New ones should still be
  # caught.
  #
  # Regenerate with: ./tests/run.sh --update-baseline
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  local baseline="$BATS_TEST_DIRNAME/baseline/shellcheck-warnings.txt"
  assert [ -f "$baseline" ]

  run bash -c "cd '$REPO_ROOT' && '$BATS_TEST_DIRNAME/helpers/shellcheck_warnings.sh'"
  assert_success

  local current="$BATS_TEST_TMPDIR/current.txt"
  printf '%s\n' "$output" > "$current"

  run diff -u "$baseline" "$current"
  if [[ "$status" -ne 0 ]]; then
    {
      echo "shellcheck warning set changed (- baseline, + current)."
      echo "New findings must be fixed; if you fixed some, run:"
      echo "  ./tests/run.sh --update-baseline"
      printf '%s\n' "$output"
    } | fail
  fi
}

# ---------------------------------------------------------------------------
# Hygiene
# ---------------------------------------------------------------------------

@test "no script hardcodes a developer's absolute path" {
  local script failures=() hits

  while IFS= read -r script; do
    hits="$(grep -nE '(/home/[a-z]+/|/Users/[a-z]+/)' "$REPO_ROOT/$script" || true)"
    [[ -n "$hits" ]] && failures+=("$script: $hits")
  done < <(repo_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "hardcoded absolute paths:" "${failures[@]}"
}

@test "setup.env.example carries no credential values" {
  # setup.env is gitignored, but the example ships in the repository. The only
  # permitted values for a secret are empty or the literal "generate" sentinel.
  local line key value
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]*(PASSWORD|SECRET|API_KEY|TOKEN))=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[3]}"
    # Drop a trailing inline comment and surrounding whitespace/quotes.
    value="${value%%#*}"
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/')"

    [[ -z "$value" || "$value" == "generate" ]] \
      || fail "setup.env.example sets $key to a literal value: '$value'"
  done < "$REPO_ROOT/setup.env.example"
}

@test "setup.env is not tracked by git" {
  run git -C "$REPO_ROOT" ls-files --error-unmatch setup.env
  assert_failure
}

@test ".gitignore covers the runtime state directories" {
  local entry
  for entry in store backup setup.env; do
    run grep -qxF "$entry" "$REPO_ROOT/.gitignore"
    assert_success
  done
}

# ---------------------------------------------------------------------------
# GitHub Actions workflows
# ---------------------------------------------------------------------------

@test "every workflow file is valid YAML" {
  # A broken workflow is only reported by GitHub after a push, and the error it
  # gives is a bare line number. Catch it here instead.
  #
  # The trap that produced this test: a `run:` written as an unquoted multi-line
  # scalar containing ": ", which YAML reads as a mapping key. Use a block
  # scalar (`run: |`) for anything multi-line.
  command -v yq >/dev/null || skip "yq not installed"

  local workflow failures=()
  while IFS= read -r workflow; do
    run yq -e 'true' "$workflow"
    [[ "$status" -eq 0 ]] || failures+=("$workflow: $(printf '%s' "$output" | head -2 | tr '\n' ' ')")
  done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "invalid workflow YAML:" "${failures[@]}"
}

@test "the CI workflow runs the test suite the same way a developer does" {
  # Guards against CI drifting from tests/run.sh, which would let the suite pass
  # locally and be skipped or invoked differently in CI.
  command -v yq >/dev/null || skip "yq not installed"

  run yq -e '.jobs.test.steps[] | select(.name == "Run the test suite") | .run' \
    "$REPO_ROOT/.github/workflows/ci.yml"
  assert_success
  assert_output --partial "./tests/run.sh"

  run yq -e '.jobs["test-npm"].steps[] | select(.name == "Run the test suite") | .run' \
    "$REPO_ROOT/.github/workflows/ci.yml"
  assert_success
  assert_output --partial "./tests/run.sh"
}

@test "no workflow step uses a multi-line plain scalar for run:" {
  # The specific syntax error this suite was taught by: `run:` followed by more
  # lines without a block scalar marker. Anything multi-line must use `run: |`.
  local workflow failures=()
  while IFS= read -r workflow; do
    # A run: whose value starts on the same line and is not a block scalar,
    # followed by a more-indented continuation line, is the broken shape.
    local n=0 prev_run_indent=-1 line indent
    while IFS= read -r line; do
      n=$((n + 1))
      if [[ "$line" =~ ^([[:space:]]*)run:[[:space:]]+[^|\>] ]]; then
        prev_run_indent=${#BASH_REMATCH[1]}
        continue
      fi
      if [[ "$prev_run_indent" -ge 0 ]]; then
        if [[ "$line" =~ ^([[:space:]]*)[^[:space:]] ]]; then
          indent=${#BASH_REMATCH[1]}
          [[ "$indent" -gt "$prev_run_indent" ]] \
            && failures+=("${workflow#"$REPO_ROOT/"} line $n: continuation of a plain 'run:' scalar")
        fi
        prev_run_indent=-1
      fi
    done < "$workflow"
  done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "multi-line plain 'run:' scalars (use 'run: |'):" "${failures[@]}"
}
