# Entry point for every .bats file: `load helpers/load`.
#
# Resolves the bats helper libraries from either Nix (BATS_LIB_PATH, set by the
# dev shell) or npm (node_modules/), then pulls in the habidat-specific
# helpers.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

# bats_load_library searches BATS_LIB_PATH. The Nix dev shell sets it; when the
# suite is run from an npm checkout, point it at node_modules instead.
if [[ -z "${BATS_LIB_PATH:-}" ]] && [[ -d "$REPO_ROOT/node_modules/bats-support" ]]; then
  export BATS_LIB_PATH="$REPO_ROOT/node_modules"
fi

bats_load_library bats-support
bats_load_library bats-assert

load "$BATS_TEST_DIRNAME/helpers/repo.bash"
load "$BATS_TEST_DIRNAME/helpers/lib.bash"
load "$BATS_TEST_DIRNAME/helpers/sandbox.bash"
load "$BATS_TEST_DIRNAME/helpers/render.bash"
