#!/usr/bin/env bash
# Print the warning-level shellcheck findings for module scripts, in a stable
# form suitable for diffing against tests/baseline/shellcheck-warnings.txt.
#
# Line numbers and columns are dropped deliberately: moving a line should not
# invalidate the baseline, but introducing a new finding should.
#
# Run from the repository root.

set -uo pipefail

command -v shellcheck >/dev/null || {
  echo "shellcheck not installed" >&2
  exit 1
}

mapfile -t files < <(
  find . -name '*.sh' -type f \
    -not -path './node_modules/*' \
    -not -path './store/*' \
    -not -path './tests/*' \
    -not -path './lib/*' \
    -not -path './habidat.sh' |
    sort
)

[[ ${#files[@]} -eq 0 ]] && exit 0

shellcheck -x -s bash -S warning -f gcc "${files[@]}" 2>/dev/null |
  sed -E 's|^\./||; s|^([^:]+):[0-9]+:[0-9]+: |\1: |' |
  sort -u

exit 0
