#!/usr/bin/env bash
# Run the habidat-setup test suite.
#
#   ./tests/run.sh                    everything
#   ./tests/run.sh 20_version         one file (prefix match)
#   ./tests/run.sh 20 30              several files
#   ./tests/run.sh --list             show the tiers
#   ./tests/run.sh --update-baseline  refresh tests/baseline/shellcheck-warnings.txt
#
# Options are passed through to bats, so `./tests/run.sh --filter 'resolve_' 21`
# works too.
#
# bats and its helper libraries come from either the Nix dev shell
# (`nix develop`, which sets BATS_LIB_PATH) or npm (`npm install`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Locate bats
# ---------------------------------------------------------------------------
if [[ -n "${BATS_LIB_PATH:-}" ]] && command -v bats >/dev/null 2>&1; then
  BATS=bats
elif [[ -x node_modules/.bin/bats ]]; then
  BATS=node_modules/.bin/bats
  export BATS_LIB_PATH="$REPO_ROOT/node_modules"
elif command -v bats >/dev/null 2>&1; then
  BATS=bats
else
  cat >&2 <<'EOF'
bats is not available. Either:

  nix develop            # brings bats, shellcheck, python+jinja2, docker CLI
  npm install            # installs bats into node_modules/

EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisites the suite needs
# ---------------------------------------------------------------------------
missing=()

# Check that the renderer *runs*, not merely that it exists: without Jinja2 it
# is present but useless, and the render tier would report every template as
# broken rather than blaming the environment.
if ! command -v python3 >/dev/null 2>&1; then
  missing+=("python3 -- needed by lib/render.py and the invariant checks")
elif ! ./lib/render.py --help >/dev/null 2>&1; then
  missing+=("lib/render.py cannot run: $(./lib/render.py --help 2>&1 | tail -n2 | tr '\n' ' ')")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'missing prerequisite: %s\n' "${missing[@]}" >&2
  echo "run inside 'nix develop' for a complete environment" >&2
  exit 1
fi

command -v shellcheck >/dev/null 2>&1 || echo "note: shellcheck not found, the static tier will skip" >&2
command -v docker >/dev/null 2>&1 || echo "note: docker CLI not found, compose validation will skip" >&2

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
declare -a bats_opts=() selectors=()

for arg in "$@"; do
  case "$arg" in
    --list)
      printf '%s\n' tests/*.bats | sed 's|tests/||; s|\.bats$||'
      exit 0
      ;;
    --update-baseline)
      mkdir -p tests/baseline
      tests/helpers/shellcheck_warnings.sh > tests/baseline/shellcheck-warnings.txt
      echo "wrote tests/baseline/shellcheck-warnings.txt ($(wc -l < tests/baseline/shellcheck-warnings.txt) findings)"
      exit 0
      ;;
    -*) bats_opts+=("$arg") ;;
    *) selectors+=("$arg") ;;
  esac
done

# ---------------------------------------------------------------------------
# Select test files
# ---------------------------------------------------------------------------
declare -a files=()

if [[ ${#selectors[@]} -eq 0 ]]; then
  files=(tests/*.bats)
else
  for selector in "${selectors[@]}"; do
    matched=false
    for candidate in tests/*.bats; do
      if [[ "$(basename "$candidate")" == "$selector"* ]]; then
        files+=("$candidate")
        matched=true
      fi
    done
    if [[ "$matched" != true ]]; then
      echo "no test file matches '$selector' (see --list)" >&2
      exit 1
    fi
  done
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
# TERM=dumb keeps lib/common.sh from emitting terminal escapes, so assertions
# match plain text.
exec env TERM=dumb "$BATS" --print-output-on-failure "${bats_opts[@]+"${bats_opts[@]}"}" "${files[@]}"
