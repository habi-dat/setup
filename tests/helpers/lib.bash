# Unit-testing helpers for lib/*.sh.
#
# lib/common.sh sets `set -euo pipefail`, rewrites IFS and installs an EXIT
# trap, so it must never be sourced into the test shell itself. Every call runs
# in a fresh bash process instead. That also means each case gets the exact
# shell options production code runs under, rather than bats' defaults.

# lib_eval <code> [base_dir]
#   Runs <code> with lib/ sourced and BASE_DIR pointing at <base_dir>
#   (default: the fixture module tree). Honours the BASE_DIR override added to
#   lib/common.sh for exactly this purpose.
lib_eval() {
  local code="$1"
  local base_dir="${2:-$BATS_TEST_DIRNAME/fixtures/modules}"

  run env -i \
    PATH="$PATH" \
    HOME="${HOME:-/tmp}" \
    TERM=dumb \
    BASE_DIR="$base_dir" \
    bash -c "
      source '$REPO_ROOT/lib/common.sh'
      source '$REPO_ROOT/lib/template.sh'
      source '$REPO_ROOT/lib/version.sh'
      source '$REPO_ROOT/lib/modules.sh'
      $code
    "
}

# assert_version_cmp <v1> <v2> <expected>
#   expected is -1, 0 or 1.
assert_version_cmp() {
  lib_eval "version_cmp '$1' '$2'"
  assert_success
  assert_output "$3"
}

# assert_version_order <lower> <higher>
#   Checks all five comparison predicates agree that lower < higher.
assert_version_order() {
  local lo="$1" hi="$2"
  assert_version_cmp "$lo" "$hi" "-1"
  assert_version_cmp "$hi" "$lo" "1"

  lib_eval "version_lt '$lo' '$hi'"
  assert_success
  lib_eval "version_gt '$hi' '$lo'"
  assert_success
  lib_eval "version_le '$lo' '$hi'"
  assert_success
  lib_eval "version_ge '$hi' '$lo'"
  assert_success
  lib_eval "version_gt '$lo' '$hi'"
  assert_failure
  lib_eval "version_eq '$lo' '$hi'"
  assert_failure
}
