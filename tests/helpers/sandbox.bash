# Sandbox harness for end-to-end CLI tests.
#
# habidat.sh derives BASE_DIR from its own location and then reads setup.env,
# store/ and the module directories relative to it. So a throwaway copy of the
# tree is a complete, isolated installation: no test can touch the developer's
# real store/ or setup.env.
#
# Module directories are COPIED rather than symlinked on purpose. The CLI does
# `cd "$BASE_DIR/$module" && ./setup.sh`, and a child process inherits the
# physical cwd -- through a symlink, the script's own `../store/...` writes
# would land in the real repository.

# Built once per .bats file, then cloned per test.
sandbox_setup_file() {
  SANDBOX_TEMPLATE="$BATS_FILE_TMPDIR/sandbox-template"
  mkdir -p "$SANDBOX_TEMPLATE"

  cp "$REPO_ROOT/habidat.sh" "$SANDBOX_TEMPLATE/"
  cp -a "$REPO_ROOT/lib" "$SANDBOX_TEMPLATE/lib"

  local mod
  while IFS= read -r mod; do
    cp -a "$REPO_ROOT/$mod" "$SANDBOX_TEMPLATE/$mod"
  done < <(repo_modules)

  mkdir -p "$SANDBOX_TEMPLATE/store"
  export SANDBOX_TEMPLATE
}

# new_sandbox [profile]
#   Clones the template, installs the named setup.env profile (default: dev)
#   and puts the recording docker stub at the front of PATH.
#   Exports SANDBOX and DOCKER_LOG.
new_sandbox() {
  local profile="${1:-dev}"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  cp -a "$SANDBOX_TEMPLATE" "$SANDBOX"
  cp "$BATS_TEST_DIRNAME/helpers/profiles/$profile.env" "$SANDBOX/setup.env"

  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$DOCKER_LOG"

  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cp "$BATS_TEST_DIRNAME/helpers/stub/docker" "$STUB_BIN/docker"
  chmod +x "$STUB_BIN/docker"

  export SANDBOX DOCKER_LOG STUB_BIN
}

# habidat <args...>
#   Runs the sandboxed CLI under `run`, with the docker stub on PATH and colour
#   disabled so assertions match plain text. Output is stripped of the
#   "HABIDAT      | " log prefix to keep assertions about the message itself.
habidat() {
  run env \
    PATH="$STUB_BIN:$PATH" \
    TERM=dumb \
    HABIDAT_TEST_DOCKER_LOG="$DOCKER_LOG" \
    "$SANDBOX/habidat.sh" "$@"

  output="$(printf '%s' "$output" | sed -E 's/^[^|]*\| ?//')"
  # shellcheck disable=SC2034,SC2154  # `lines` is bats' own result variable
  mapfile -t lines <<< "$output"
}

# seed_module <module> <installed-version> [extra-files...]
#   Marks a module as installed in the sandbox store at the given version, with
#   the docker-compose.yml and dependencies file a real install would leave
#   behind.
seed_module() {
  local module="$1" version="$2"
  local dir="$SANDBOX/store/$module"

  mkdir -p "$dir"
  echo "$version" > "$dir/version"
  : > "$dir/docker-compose.yml"
  if [[ -f "$SANDBOX/$module/dependencies" ]]; then
    cp "$SANDBOX/$module/dependencies" "$dir/dependencies"
  fi
}

# seed_networks_env
#   Writes the store/nginx/networks.env that nginx/setup.sh normally produces.
#   Nearly every setup.sh and migrate.sh sources it first thing, so a module
#   test that runs real module scripts needs it present.
seed_networks_env() {
  local prefix
  prefix="$(sed -n 's/^HABIDAT_DOCKER_PREFIX=//p' "$SANDBOX/setup.env")"

  mkdir -p "$SANDBOX/store/nginx"
  {
    echo "export HABIDAT_PROXY_NETWORK=$prefix-proxy"
    echo "export HABIDAT_BACKEND_NETWORK=$prefix-backend"
  } > "$SANDBOX/store/nginx/networks.env"
}

# docker_calls
#   Every docker invocation the last CLI run made, one per line.
docker_calls() {
  cat "$DOCKER_LOG"
}

# assert_docker_called <substring>
assert_docker_called() {
  if ! grep -qF -- "$1" "$DOCKER_LOG"; then
    {
      echo "expected a docker call containing:"
      echo "  $1"
      echo "actual calls:"
      sed 's/^/  /' "$DOCKER_LOG"
    } | fail
  fi
}

# refute_docker_called <substring>
refute_docker_called() {
  if grep -qF -- "$1" "$DOCKER_LOG"; then
    {
      echo "expected no docker call containing:"
      echo "  $1"
      echo "actual calls:"
      sed 's/^/  /' "$DOCKER_LOG"
    } | fail
  fi
}

# assert_no_destructive_docker
#   Guards the tests themselves: nothing below `install` should ever reach a
#   command that removes volumes or images.
assert_no_destructive_docker() {
  local pattern='down -v|volume rm|image rm|rmi |system prune'
  if grep -qE -- "$pattern" "$DOCKER_LOG"; then
    {
      echo "unexpected destructive docker call:"
      grep -E -- "$pattern" "$DOCKER_LOG" | sed 's/^/  /'
    } | fail
  fi
}
