#!/usr/bin/env bats
# End-to-end CLI behaviour, in a throwaway copy of the repository.
#
# Nothing here touches a Docker daemon: a recording stub stands in for the
# docker binary, so tests can assert on the exact commands the CLI emits
# without side effects. See tests/helpers/sandbox.bash.

load helpers/load

setup_file() {
  sandbox_setup_file
}

setup() {
  new_sandbox dev
}

# ---------------------------------------------------------------------------
# Dispatch and usage
# ---------------------------------------------------------------------------

@test "help: lists every documented command" {
  habidat help
  assert_success
  for cmd in install remove start restart stop up down update pull build export import modules; do
    assert_output --partial "$cmd"
  done
}

@test "no arguments: prints usage and exits non-zero" {
  habidat
  assert_failure
  assert_output --partial "Usage: habidat.sh"
}

@test "unknown command: is rejected" {
  habidat frobnicate
  assert_failure
  assert_output --partial "Unknown command: frobnicate"
}

@test "unknown global flag: is rejected" {
  habidat --wat modules
  assert_failure
  assert_output --partial "Unknown flag: --wat"
}

@test "a command without a target: is rejected" {
  habidat update
  assert_failure
  assert_output --partial "Usage: habidat.sh update <module>|all"
}

@test "missing setup.env: aborts before doing anything" {
  rm "$SANDBOX/setup.env"
  habidat modules
  assert_failure
  assert_output --partial "setup.env not found"
}

# ---------------------------------------------------------------------------
# modules
# ---------------------------------------------------------------------------

@test "modules: reports every module as not installed on a fresh tree" {
  habidat modules
  assert_success
  assert_line --partial "nginx [NOT INSTALLED]"
  assert_line --partial "nextcloud [NOT INSTALLED]"
  assert [ "${#lines[@]}" -eq 8 ]
}

@test "modules: lists modules in dependency order" {
  habidat modules
  assert_success
  assert_line --index 0 --partial "nginx"
  assert_line --index 1 --partial "auth"
  assert_line --index 2 --partial "nextcloud"
}

@test "modules: shows the installed version when it matches the repo target" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat modules
  assert_success
  assert_line --partial "nextcloud [INSTALLED v$(repo_module_version nextcloud)]"
}

@test "modules: flags an available upgrade" {
  seed_module nextcloud 32.0.5
  habidat modules
  assert_success
  assert_line --partial "nextcloud [INSTALLED v32.0.5 -> v$(repo_module_version nextcloud) available]"
}

# ---------------------------------------------------------------------------
# validate_store warnings
# ---------------------------------------------------------------------------

@test "validate_store: warns about a store entry with no version file" {
  mkdir -p "$SANDBOX/store/nextcloud"
  : > "$SANDBOX/store/nextcloud/docker-compose.yml"

  habidat modules
  assert_success
  assert_output --partial "nextcloud has no version file"
  assert_output --partial "store integrity warning"
}

@test "validate_store: warns about a store entry that is not a module in the repo" {
  mkdir -p "$SANDBOX/store/obsolete"
  echo "1.0.0" > "$SANDBOX/store/obsolete/version"
  : > "$SANDBOX/store/obsolete/docker-compose.yml"

  habidat modules
  assert_success
  assert_output --partial "obsolete is installed but not found as a module"
}

@test "validate_store: does not warn about a healthy store" {
  seed_module nginx "$(repo_module_version nginx)"
  habidat modules
  assert_success
  refute_output --partial "store integrity warning"
}

# ---------------------------------------------------------------------------
# update: migration planning (the core of the versioned upgrade system)
# ---------------------------------------------------------------------------

@test "update: plans every migration step between installed and repo target" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud
  assert_success
  assert_output --partial "nextcloud/versions/32.0.6/migrate.sh"
  assert_output --partial "nextcloud/versions/33.0.0/migrate.sh"
  assert_output --partial "nextcloud/versions/34.0.3/migrate.sh"
}

@test "update: stops at an explicitly requested version" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud 33.0.0
  assert_success
  assert_output --partial "nextcloud/versions/32.0.6/migrate.sh"
  assert_output --partial "nextcloud/versions/33.0.0/migrate.sh"
  refute_output --partial "nextcloud/versions/34.0.3/migrate.sh"
  assert_output --partial "Stopping at 33.0.0"
}

@test "update: --dry-run leaves the recorded version untouched" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud
  assert_success

  run cat "$SANDBOX/store/nextcloud/version"
  assert_output "32.0.5"
}

@test "update: --dry-run issues no docker commands" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud
  assert_success
  # `docker compose version` from check_prerequisites is expected; nothing that
  # names a compose file is.
  refute_docker_called "compose -f"
}

@test "update: refuses a version above the repo target" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud 99.0.0
  assert_failure
  assert_output --partial "Cannot update nextcloud to 99.0.0: repo target is $(repo_module_version nextcloud)"
}

@test "update: refuses a version with no migration and lists what is available" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud 33.5.0
  assert_failure
  assert_output --partial "No migration for nextcloud version 33.5.0"
  assert_output --partial "Available migrations:"
  assert_output --partial "32.0.6"
}

@test "update: refuses a malformed version string" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update nextcloud "not-a-version"
  assert_failure
  assert_output --partial "Invalid version"
}

@test "update: refuses a downgrade" {
  seed_module nextcloud 34.0.3
  habidat --dry-run update nextcloud 33.0.0
  assert_failure
  assert_output --partial "is newer than target"
  assert_output --partial "Downgrade not supported"
}

@test "update: reports an up-to-date module instead of re-running migrations" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat --dry-run update nextcloud
  assert_success
  assert_output --partial "is up to date"
  refute_output --partial "migrate.sh"
}

@test "update: force on an up-to-date module finds no steps to re-run" {
  # Documents a gap between the README and the code. `force` suppresses the
  # "up to date" early return, but the migration range stays exclusive of the
  # installed version (versions > installed AND <= target), so a module already
  # at the target has nothing to re-run and only its version marker is
  # rewritten. README calls this "force re-run migrations even if up to date".
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat --dry-run update nextcloud force
  assert_success
  assert_output --partial "no migration scripts between"
  refute_output --partial "is up to date"
  refute_output --partial "migrate.sh"
}

@test "update: force does re-run migrations when one is in range" {
  seed_module nextcloud 33.0.0
  habidat --dry-run update nextcloud force
  assert_success
  assert_output --partial "nextcloud/versions/34.0.3/migrate.sh"
}

@test "update: force permits a downgrade" {
  seed_module nextcloud 34.0.3
  habidat --dry-run update nextcloud 33.0.0 force
  assert_success
  refute_output --partial "Downgrade not supported"
}

@test "update: an uninstalled module is not updated" {
  habidat --dry-run update nextcloud
  assert_output --partial "not installed, cannot update"
}

@test "update: an unknown module is rejected" {
  habidat --dry-run update ghostmodule
  assert_failure
  assert_output --partial "Unknown module: ghostmodule"
}

@test "update: only the version marker moves when no migration script applies" {
  # dokuwiki ships versions/0.0.1/ with templates but no migrate.sh, so an
  # update has nothing to run and merely records the new version. That also
  # means a dokuwiki update never re-renders its compose file or config.
  seed_module dokuwiki 0.0.0
  habidat update dokuwiki
  assert_success
  assert_output --partial "no migration scripts between 0.0.0 and $(repo_module_version dokuwiki)"
  refute_docker_called "compose -f"

  run cat "$SANDBOX/store/dokuwiki/version"
  assert_output "$(repo_module_version dokuwiki)"
}

@test "update: runs a real migration, rendering templates and advancing the marker" {
  # The one place a migrate.sh actually executes in this tier. nginx is the
  # cheapest: its migration renders four config files plus the compose file,
  # then pulls and recreates containers -- all of which the docker stub absorbs.
  seed_module nginx 0.0.0
  seed_networks_env

  habidat update nginx
  assert_success
  assert_output --partial "migrating 0.0.0 -> $(repo_module_version nginx)"
  assert_output --partial "Module nginx migrated to $(repo_module_version nginx)"

  # migrate.sh had render_versioned_template available and used it.
  assert [ -s "$SANDBOX/store/nginx/docker-compose.yml" ]
  for conf in nginx.conf user.conf cors_map.conf cookies.conf; do
    assert [ -s "$SANDBOX/store/nginx/config/$conf" ]
  done

  # Templates were rendered, not copied verbatim.
  run grep -c '{{' "$SANDBOX/store/nginx/docker-compose.yml"
  assert_output "0"
  run grep -q 'habidattest-proxy' "$SANDBOX/store/nginx/docker-compose.yml"
  assert_success

  assert_docker_called "-p habidattest-nginx pull"
  assert_docker_called "-p habidattest-nginx up -d"

  run cat "$SANDBOX/store/nginx/version"
  assert_output "$(repo_module_version nginx)"
}

# install_failing_migration <module>
#   Replaces the module's migration with one that fails partway through, so the
#   two tests below can observe how the failure is handled.
install_failing_migration() {
  local module="$1" ver="$2"
  cat > "$SANDBOX/$module/versions/$ver/migrate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "MIGRATION STEP 1"
false
echo "MIGRATION STEP 2"
EOF
}

@test "update <module>: a failing migration aborts and preserves the version marker" {
  seed_module nginx 0.0.0
  install_failing_migration nginx "$(repo_module_version nginx)"

  habidat update nginx
  assert_failure
  assert_output --partial "MIGRATION STEP 1"
  refute_output --partial "MIGRATION STEP 2"

  run cat "$SANDBOX/store/nginx/version"
  assert_output "0.0.0"

  # DEFECT, pinned deliberately: run_migrations' own diagnostic never appears.
  # The `( ... ) | log_module` pipeline fails under the script's `set -e`, so
  # the shell exits before reaching `log_error "Migration ... FAILED"`. The user
  # sees the migration's own stderr and a non-zero exit, but not which step
  # failed or that a retry resumes from here.
  refute_output --partial "FAILED"
  refute_output --partial "Fix the issue and retry"
}

@test "update all: a failing migration is recorded as a SUCCESS (defect)" {
  # DEFECT, pinned deliberately. `dispatch` calls `update_module ... || { ... }`,
  # and putting the call in a `||` list makes bash suspend errexit for the whole
  # dynamic extent -- including the subshell that sources migrate.sh, whose own
  # `set -euo pipefail` cannot restore it. So the migration runs past its
  # failure, the subshell returns the status of its *last* command, and
  # run_migrations advances store/<module>/version.
  #
  # Consequence: `update all` can mark a half-applied migration complete,
  # defeating the documented "fix the issue and retry -- it will resume from
  # where it left off".
  #
  # When this is fixed, invert the three assertions below.
  seed_module nginx 0.0.0
  install_failing_migration nginx "$(repo_module_version nginx)"

  habidat update all

  assert_output --partial "MIGRATION STEP 1"
  assert_output --partial "MIGRATION STEP 2"
  assert_output --partial "Module nginx migrated to $(repo_module_version nginx)"

  run cat "$SANDBOX/store/nginx/version"
  assert_output "$(repo_module_version nginx)"
}

@test "update all: rejects a target version, which only makes sense per module" {
  seed_module nextcloud 32.0.5
  habidat --dry-run update all 33.0.0
  assert_failure
  assert_output --partial "can only be specified for a single module"
}

@test "update all: accepts force and skips uninstalled modules" {
  seed_module nginx "$(repo_module_version nginx)"
  habidat --dry-run update all force
  assert_success
  refute_output --partial "nextcloud"
}

@test "update: a module with a custom update script refuses a target version" {
  # discourse ships update.sh instead of versioned migrations.
  seed_module discourse "$(repo_module_version discourse)"
  habidat --dry-run update discourse 3.3.2
  assert_failure
  assert_output --partial "custom update script"
  assert_output --partial "does not support updating to a specific version"
}

# ---------------------------------------------------------------------------
# install / remove guard rails
# ---------------------------------------------------------------------------

@test "install: refuses to reinstall over an existing installation" {
  seed_module nginx "$(repo_module_version nginx)"
  habidat install nginx
  assert_failure
  assert_output --partial "already installed"
  assert_no_destructive_docker
}

@test "install: an unknown module is rejected" {
  habidat install ghostmodule
  assert_failure
  assert_output --partial "Unknown module: ghostmodule"
}

@test "remove: an uninstalled module is rejected" {
  habidat remove nginx force
  assert_failure
  assert_output --partial "not installed, cannot remove"
}

@test "remove: an unknown module not present in store/ is rejected" {
  habidat remove ghostmodule force
  assert_failure
  assert_output --partial "Unknown module: ghostmodule"
}

@test "remove: refuses while another installed module depends on the target" {
  seed_module nginx "$(repo_module_version nginx)"
  seed_module auth "$(repo_module_version auth)"

  habidat remove nginx force
  assert_failure
  assert_output --partial "auth depends on nginx"
  assert_output --partial "remove dependent modules first"
  assert_no_destructive_docker
}

@test "remove: tears down compose and drops the store directory" {
  seed_module nginx "$(repo_module_version nginx)"

  habidat remove nginx force
  assert_success
  assert_docker_called "compose -f $SANDBOX/store/nginx/docker-compose.yml -p habidattest-nginx down -v --remove-orphans"
  assert [ ! -d "$SANDBOX/store/nginx" ]
}

@test "remove: cleans up a partially installed module without a version file" {
  mkdir -p "$SANDBOX/store/nginx"
  : > "$SANDBOX/store/nginx/docker-compose.yml"

  habidat remove nginx force
  assert_success
  assert_output --partial "partially installed"
  assert [ ! -d "$SANDBOX/store/nginx" ]
}

@test "remove: refreshes the installed-modules list for the auth service" {
  seed_module auth "$(repo_module_version auth)"
  seed_module dokuwiki "$(repo_module_version dokuwiki)"

  habidat remove dokuwiki force
  assert_success

  run grep 'HABIDAT_USER_INSTALLED_MODULES' "$SANDBOX/store/auth/auth.env"
  assert_output "HABIDAT_USER_INSTALLED_MODULES=nginx,auth"
}

# ---------------------------------------------------------------------------
# Lifecycle verbs -> docker compose commands
# ---------------------------------------------------------------------------

@test "start/stop/restart: map to the matching compose subcommand" {
  seed_module nextcloud "$(repo_module_version nextcloud)"

  for action in start stop restart; do
    : > "$DOCKER_LOG"
    habidat "$action" nextcloud
    assert_success
    assert_docker_called "compose -f $SANDBOX/store/nextcloud/docker-compose.yml -p habidattest-nextcloud $action"
  done
}

@test "up: becomes 'compose up -d'" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat up nextcloud
  assert_success
  assert_docker_called "-p habidattest-nextcloud up -d"
}

@test "down: becomes 'compose down' and never removes volumes" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat down nextcloud
  assert_success
  assert_docker_called "-p habidattest-nextcloud down"
  assert_no_destructive_docker
}

@test "pull and build: map to the matching compose subcommand" {
  seed_module nextcloud "$(repo_module_version nextcloud)"

  for action in pull build; do
    : > "$DOCKER_LOG"
    habidat "$action" nextcloud
    assert_success
    assert_docker_called "-p habidattest-nextcloud $action"
  done
}

@test "lifecycle: the compose project name is <prefix>-<module>" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat up nextcloud
  assert_success
  # HABIDAT_DOCKER_PREFIX=habidattest in the dev profile.
  assert_docker_called "-p habidattest-nextcloud"
}

@test "lifecycle: an uninstalled module is skipped silently" {
  habidat start nextcloud
  assert_success
  refute_docker_called "compose -f"
}

@test "lifecycle: a module's own script takes precedence over generic compose" {
  # discourse ships start.sh, which drives its launcher rather than compose.
  seed_module discourse "$(repo_module_version discourse)"
  chmod +x "$SANDBOX/discourse/start.sh"

  habidat start discourse
  refute_docker_called "compose -f $SANDBOX/store/discourse/docker-compose.yml"
}

@test "lifecycle: a non-executable module script aborts the command with no diagnostic" {
  # DEFECT, pinned deliberately. discourse and mediawiki ship every lifecycle
  # script except setup.sh as mode 644 in git, so `./start.sh` is "Permission
  # denied" (exit 126).
  #
  # _run_lifecycle never inspects the pipeline's status, so the abort comes from
  # lib/common.sh's `set -e` instead: the user sees a raw "Permission denied"
  # naming lib/modules.sh, with no indication of which module or verb failed.
  #
  # `git update-index --chmod=+x` on those files is the fix.
  seed_module discourse "$(repo_module_version discourse)"
  assert [ ! -x "$REPO_ROOT/discourse/start.sh" ]

  habidat start discourse
  assert_equal "$status" 126
  assert_output --partial "start.sh"
  # No habidat-level error explaining the failure.
  refute_output --partial "failed"
  refute_docker_called "compose -f"
}

@test "lifecycle all: one broken module script truncates the run (defect)" {
  # DEFECT, pinned deliberately. Because the abort above comes from `set -e`
  # rather than a checked return code, `start all` stops at the first module with
  # a non-executable script and never reaches the ones after it in dependency
  # order -- silently, apart from the permission error.
  #
  # Contrast with `update all`, which deliberately continues past a failed module
  # and reports at the end. Applying the same treatment to _run_lifecycle, plus
  # fixing the file modes, is the fix. Then invert this test.
  seed_module nginx "$(repo_module_version nginx)"
  seed_module discourse "$(repo_module_version discourse)"
  seed_module dokuwiki "$(repo_module_version dokuwiki)"

  habidat start all
  assert_equal "$status" 126

  # nginx sorts before discourse and was started; dokuwiki sorts after and was not.
  assert_docker_called "-p habidattest-nginx start"
  refute_docker_called "-p habidattest-dokuwiki start"
}

@test "lifecycle all: walks every installed module in dependency order" {
  seed_module nginx "$(repo_module_version nginx)"
  seed_module auth "$(repo_module_version auth)"
  seed_module nextcloud "$(repo_module_version nextcloud)"

  habidat up all
  assert_success

  run docker_calls
  local order i_nginx i_auth i_nc n=0 line
  while IFS= read -r line; do
    case "$line" in
      *"-p habidattest-nginx up"*) i_nginx=${i_nginx-$n} ;;
      *"-p habidattest-auth up"*) i_auth=${i_auth-$n} ;;
      *"-p habidattest-nextcloud up"*) i_nc=${i_nc-$n} ;;
    esac
    n=$((n + 1))
  done < "$DOCKER_LOG"

  assert [ "$i_nginx" -lt "$i_auth" ]
  assert [ "$i_auth" -lt "$i_nc" ]
  refute [ -n "${order:-}" ]
}

# ---------------------------------------------------------------------------
# export / import
# ---------------------------------------------------------------------------

@test "export: an uninstalled module reports rather than running" {
  habidat export nextcloud
  assert_output --partial "not installed, cannot export"
}

@test "export: a module with no export script for its version is reported" {
  # dokuwiki has no export/ directory at all.
  seed_module dokuwiki "$(repo_module_version dokuwiki)"
  habidat export dokuwiki
  assert_output --partial "no export script for installed version"
}

@test "import: requires a filename" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat import nextcloud
  assert_failure
  assert_output --partial "Usage: habidat.sh import <module> <filename>|list"
}

@test "import: rejects 'all'" {
  habidat import all somefile
  assert_failure
  assert_output --partial "Import can only be done per module"
}

@test "import: reports a missing backup file" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat import nextcloud absent.tar.gz
  assert_failure
  assert_output --partial "Import file absent.tar.gz not found"
}

@test "import list: shows the backup directory for the module" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat import nextcloud list
  assert_success
  assert_output --partial "Available import files for nextcloud"
}
