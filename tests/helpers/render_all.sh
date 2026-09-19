#!/usr/bin/env bash
# Render every repository template under one configuration profile.
#
# Called once per .bats file from setup_file(). j2cli costs ~350ms per
# invocation, so rendering 65 templates x 3 profiles per test would dominate the
# suite; this renders each combination once, in parallel, into a cache the
# individual tests read.
#
# Usage: render_all.sh <profile-env-file> <runtime-vars-file> <out-dir> <fail-file> <repo-root>
#
# Output:
#   <out-dir>/<template-path>   rendered result, for templates that succeeded
#   <fail-file>                 TAB-separated "<template-path>\t<j2 error>" per failure

set -uo pipefail

profile_file="$1"
runtime_file="$2"
out_dir="$3"
fail_file="$4"
repo_root="$5"

set -a
# shellcheck disable=SC1090
source "$profile_file"
# shellcheck disable=SC1090
source "$runtime_file"
set +a

mkdir -p "$out_dir"
: > "$fail_file"

export OUT_DIR="$out_dir" FAIL_FILE="$fail_file"

cd "$repo_root" || exit 1

# tests/ holds deliberately invalid fixture templates; node_modules is vendored.
find . -name '*.j2' -type f \
  -not -path './node_modules/*' \
  -not -path './tests/*' \
  -printf '%P\n' |
  xargs -r -P "$(nproc 2>/dev/null || echo 4)" -I{} bash -c '
    template="{}"
    out="$OUT_DIR/$template"
    mkdir -p "$(dirname "$out")"
    if ! err=$(j2 "$template" -o "$out" 2>&1); then
      rm -f "$out"
      # j2cli emits a pkg_resources deprecation warning on every run; drop it so
      # the recorded message is the actual Jinja error.
      printf "%s\t%s\n" "$template" \
        "$(printf "%s" "$err" | grep -v "pkg_resources" | tr "\n" " " | tail -c 300)" \
        >> "$FAIL_FILE"
    fi
  '

exit 0
