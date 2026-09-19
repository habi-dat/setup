# Template rendering helpers.
#
# lib/render.py runs Jinja2 with StrictUndefined, so a template that reads a
# variable nobody provides is a hard failure at install time, not an empty string.
# That makes "render everything under every profile" a cheap, high-value check
# -- as long as the test supplies exactly the variables a real run would.
#
# Two sources feed a render:
#   1. setup.env            -- one of tests/helpers/profiles/*.env
#   2. runtime variables    -- generated during install by setup.sh / migrate.sh
#                              (passwords, network names, per-instance args) and
#                              exported before the j2 call
#
# RUNTIME_VARS below is the authoritative list of (2). When a template starts
# reading something new, either setup.env.example gains a key or this list
# does -- and 10_invariants.bats fails until one of them happens.

RENDER_PROFILES=(dev prod existing-net)

# Runtime variables, annotated with where the real code sets them.
RUNTIME_VARS=(
  # nginx/setup.sh, auth/setup.sh -> store/nginx/networks.env
  "HABIDAT_PROXY_NETWORK=habidattest-proxy"
  "HABIDAT_BACKEND_NETWORK=habidattest-backend"

  # auth/setup.sh
  "HABIDAT_LDAP_PORT_MAPPING=389"
  "HABIDAT_INTERNAL_NETWORK_DISABLE="
  "HABIDAT_EXTERNAL_NETWORK_DISABLE=#"
  "HABIDAT_LDAP_ADMIN_PASSWORD=ldap-admin-pw"
  "HABIDAT_LDAP_READ_PASSWORD=ldap-read-pw"
  "HABIDAT_LDAP_CONFIG_PASSWORD=ldap-config-pw"
  "HABIDAT_USER_SESSION_SECRET=session-secret"
  "HABIDAT_USER_INSTALLED_MODULES=nginx,auth"
  "HABIDAT_SSO_CERTIFICATE=-----BEGIN CERTIFICATE-----\\nAAAA\\n-----END CERTIFICATE-----"
  "HABIDAT_SSO_CERTIFICATE_SINGLE_LINE=AAAA"

  # nextcloud/setup.sh
  "HABIDAT_NEXTCLOUD_DB_PASSWORD=nc-db-pw"
  "HABIDAT_NEXTCLOUD_DB_ROOT_PASSWORD=nc-db-root-pw"
  "HABIDAT_NEXTCLOUD_REDIS_PASSWORD=nc-redis-pw"
  "HABIDAT_DISCOURSE_SSO_SECRET=discourse-sso-secret"

  # discourse/setup.sh
  "HABIDAT_DISCOURSE_DB_PASSWORD=discourse-db-pw"
  "HABIDAT_DISCOURSE_ADMIN_PASSWORD=discourse-admin-pw"
  "HABIDAT_DISCOURSE_API_KEY=discourse-api-key"

  # mediawiki/setup.sh -- the three positional install arguments, plus passwords
  "HABIDAT_MEDIAWIKI_PROJECTID=testwiki"
  "HABIDAT_MEDIAWIKI_TITLE=Test Wiki"
  "HABIDAT_MEDIAWIKI_LDAP_GROUP=testgroup"
  "HABIDAT_MEDIAWIKI_DB_PASSWORD=mw-db-pw"
  "HABIDAT_MEDIAWIKI_DB_ROOT_PASSWORD=mw-db-root-pw"

  # mailtrain/setup.sh
  "HABIDAT_MAILTRAIN_DB_PASSWORD=mt-db-pw"
  "HABIDAT_MAILTRAIN_DB_ROOT_PASSWORD=mt-db-root-pw"
)

# ---------------------------------------------------------------------------
# Cached bulk rendering
# ---------------------------------------------------------------------------

# render_setup_file
#   Renders every template under every profile once, into
#   $BATS_FILE_TMPDIR/rendered/<profile>/. Call from setup_file().
render_setup_file() {
  RENDER_CACHE="$BATS_FILE_TMPDIR/rendered"
  RUNTIME_VARS_FILE="$BATS_FILE_TMPDIR/runtime-vars.env"
  printf '%q\n' "${RUNTIME_VARS[@]}" > "$RUNTIME_VARS_FILE"

  local profile
  for profile in "${RENDER_PROFILES[@]}"; do
    "$BATS_TEST_DIRNAME/helpers/render_all.sh" \
      "$BATS_TEST_DIRNAME/helpers/profiles/$profile.env" \
      "$RUNTIME_VARS_FILE" \
      "$RENDER_CACHE/$profile" \
      "$BATS_FILE_TMPDIR/failures-$profile.txt" \
      "$REPO_ROOT"
  done

  export RENDER_CACHE RUNTIME_VARS_FILE
}

# rendered <template-path> [profile]
#   Path to the cached render, or empty if the template failed to render.
rendered() {
  local path="$RENDER_CACHE/${2:-dev}/$1"
  [[ -f "$path" ]] && printf '%s' "$path"
}

# render_failures [profile]
#   TAB-separated "<template>\t<error>" lines for templates that failed.
render_failures() {
  cat "$BATS_FILE_TMPDIR/failures-${1:-dev}.txt" 2>/dev/null
}

# for_each_rendered <profile> <glob>
#   Repo-relative paths of cached renders whose path matches <glob>.
for_each_rendered() {
  local profile="$1" pattern="$2"
  (cd "$RENDER_CACHE/$profile" && find . -type f -path "*$pattern" | sed 's|^\./||' | sort)
}

# ---------------------------------------------------------------------------
# Ad-hoc single-template rendering, for tests that vary the variables
# ---------------------------------------------------------------------------

# render_template <template-path> [profile]
#   Renders one template with the given profile plus RUNTIME_VARS as they stand
#   in the calling test, so a test can append to RUNTIME_VARS first. Sets
#   `output` to the rendered text and `status` to j2's exit code.
render_template() {
  local template="$1" profile="${2:-dev}"
  local profile_file="$BATS_TEST_DIRNAME/helpers/profiles/$profile.env"

  run --separate-stderr env -i \
    PATH="$PATH" \
    HOME="${HOME:-/tmp}" \
    bash -c "
      set -a
      source '$profile_file'
      $(printf 'export %q\n' "${RUNTIME_VARS[@]}")
      set +a
      cd '$REPO_ROOT' && exec ./lib/render.py '$template'
    "
}

# assert_renders <template-path> [profile]
assert_renders() {
  local template="$1" profile="${2:-dev}"
  render_template "$template" "$profile"
  if [[ "$status" -ne 0 ]]; then
    {
      echo "template failed to render: $template (profile: $profile)"
      echo "--- j2 error ---"
      # shellcheck disable=SC2154  # `stderr` comes from run --separate-stderr
      printf '%s\n' "$stderr" | tail -n 6
    } | fail
  fi
}

# ---------------------------------------------------------------------------
# Compose validation
# ---------------------------------------------------------------------------

# compose_config <rendered-compose-file> [extra-args...]
#   Runs `docker compose config` against a rendered file. Compose resolves
#   `env_file:` paths relative to the file, and setup.sh writes those alongside
#   the compose file in store/<module>/ -- so the referenced files are created
#   empty first. Sets `output` and `status`; stderr is folded in so deprecation
#   warnings are visible to callers.
compose_config() {
  local file="$1"; shift
  local dir env_ref
  dir="$(dirname "$file")"

  while IFS= read -r env_ref; do
    env_ref="${env_ref#./}"
    mkdir -p "$dir/$(dirname "$env_ref")"
    touch "$dir/$env_ref"
  done < <(grep -oE '^\s*-\s*\./[^:[:space:]]+\.(env|yaml)$' "$file" | sed -E 's/^\s*-\s*//')

  run docker compose -f "$file" config "$@"
}
