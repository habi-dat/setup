# Read-only queries against the real repository.
#
# The invariant and render tiers assert things about the checked-in tree
# itself, so they use these rather than a sandbox.

# All module names: a top-level directory carrying a `version` file.
# Mirrors get_available_modules() in lib/modules.sh.
repo_modules() {
  local dir name
  for dir in "$REPO_ROOT"/*/; do
    name="$(basename "$dir")"
    case "$name" in
      lib | store | scripts | tests | node_modules | .git | .github) continue ;;
    esac
    [[ -f "$dir/version" ]] && echo "$name"
  done
}

# Declared target version of a module, whitespace stripped.
repo_module_version() {
  tr -d '[:space:]' < "$REPO_ROOT/$1/version"
}

# Version directories under <module>/versions/, ascending.
repo_version_dirs() {
  local d
  [[ -d "$REPO_ROOT/$1/versions" ]] || return 0
  for d in "$REPO_ROOT/$1/versions"/*/; do
    [[ -d "$d" ]] && basename "$d"
  done | sort -V
}

# Highest version directory under <module>/versions/, or empty.
repo_newest_version_dir() {
  repo_version_dirs "$1" | tail -n1
}

# Every .j2 template in the repo, repo-relative.
# tests/ is excluded: its fixture templates are deliberately not valid configs.
repo_templates() {
  (cd "$REPO_ROOT" && find . -name '*.j2' -type f \
    -not -path './node_modules/*' -not -path './tests/*' | sed 's|^\./||' | sort)
}

# Every shell script shipped by the repo, repo-relative.
repo_scripts() {
  (cd "$REPO_ROOT" && find . -name '*.sh' -type f \
    -not -path './node_modules/*' -not -path './store/*' -not -path './tests/*' \
    | sed 's|^\./||' | sort)
}

# Every plain shell file under tests/, repo-relative.
#
# .bats files are excluded: bats preprocesses `@test "..." { }` into functions,
# so they are not valid bash and `bash -n` rejects them. Bats validates them by
# running them.
repo_test_scripts() {
  (cd "$REPO_ROOT" && find tests -type f \( -name '*.sh' -o -name '*.bash' \) | sort)
}

# Names of every HABIDAT_* variable assigned in setup.env.example.
repo_example_env_keys() {
  sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$REPO_ROOT/setup.env.example" | sort -u
}

# Nextcloud app image tag in a compose file (habidat/nextcloud:X or nextcloud:X).
repo_nextcloud_image_tag() {
  repo_compose_image_tag "$1" '(habidat/)?nextcloud'
}

# Tag of `image: <name>:<tag>` in a compose file. `name` is an ERE.
repo_compose_image_tag() {
  local file="$1" name="$2" line
  line="$(grep -E "^[[:space:]]*image:[[:space:]]+${name}:" "$file" | head -1)" || return 1
  line="${line##*:}"
  tr -d '[:space:]' <<< "$line"
}

# True when a habidat module/snapshot version is the Nextcloud image tag or a
# further suffix of it (34.0.4.1 still ships nextcloud:34.0.4).
version_covers_image_tag() {
  local version="$1" tag="$2"
  [[ -n "$tag" && ( "$version" == "$tag" || "$version" == "$tag".* ) ]]
}

# Fail with a multi-line message listing offenders. Keeps assertions readable
# when a convention is violated in several places at once.
fail_with_list() {
  local headline="$1"; shift
  local item
  {
    echo "$headline"
    for item in "$@"; do echo "  - $item"; done
  } | fail
}
