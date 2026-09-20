#!/usr/bin/env bash
# Render every repository template under one configuration profile.
#
# Called once per .bats file from setup_file(). Each render is a Python process,
# so rendering 65 templates x 3 profiles inside every test would dominate the
# suite; this renders each combination once, in parallel, into a cache the
# individual tests read.
#
# Usage: render_all.sh <profile-env-file> <runtime-vars-file> <out-dir> <fail-file> <repo-root>
#
# Output:
#   <out-dir>/<template-path>   rendered result, for templates that succeeded
#   <fail-file>                 TAB-separated "<template-path>\t<error>" per failure

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

export OUT_DIR="$out_dir" FAIL_FILE="$fail_file" REPO_ROOT="$repo_root"

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
    if ! err=$("$REPO_ROOT/lib/render.py" "$template" "$out" 2>&1); then
      rm -f "$out"
      printf "%s\t%s\n" "$template" \
        "$(printf "%s" "$err" | tr "\n" " " | tail -c 300)" >> "$FAIL_FILE"
    fi
  '

exit 0
