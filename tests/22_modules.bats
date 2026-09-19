#!/usr/bin/env bats
# lib/modules.sh -- module discovery and dependency ordering.
#
# get_ordered_modules() decides the order `install all` / `update all` walk the
# modules, so a wrong order means installing nextcloud before the LDAP backend
# it binds to.

load helpers/load

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

@test "get_available_modules: a directory is a module only if it has a version file" {
  lib_eval "get_available_modules | sort"
  assert_success
  assert_output - <<'EOF'
alpha
beta
delta
gamma
EOF
}

@test "get_available_modules: skips lib/, store/, scripts/ and the dotfile dirs" {
  cp -a "$BATS_TEST_DIRNAME/fixtures/modules" "$BATS_TEST_TMPDIR/fixture"
  for d in lib store scripts .github; do
    mkdir -p "$BATS_TEST_TMPDIR/fixture/$d"
    echo "9.9.9" > "$BATS_TEST_TMPDIR/fixture/$d/version"
  done

  lib_eval "get_available_modules | sort" "$BATS_TEST_TMPDIR/fixture"
  assert_success
  refute_line "lib"
  refute_line "store"
  refute_line "scripts"
  refute_line ".github"
}

@test "is_valid_module: requires both the directory and its version file" {
  lib_eval "is_valid_module alpha"
  assert_success
  lib_eval "is_valid_module noversions"
  assert_failure
  lib_eval "is_valid_module ghost"
  assert_failure
}

@test "is_installed: reflects the presence of a store/ directory" {
  lib_eval "is_installed alpha"
  assert_success
  lib_eval "is_installed beta"
  assert_failure
}

@test "get_installed_modules: lists the store/ subdirectories" {
  lib_eval "get_installed_modules"
  assert_success
  assert_output "alpha"
}

@test "get_module_dependencies: reads the dependencies file" {
  lib_eval "get_module_dependencies gamma"
  assert_success
  assert_output - <<'EOF'
beta
alpha
EOF
}

@test "get_module_dependencies: is empty for a module without the file" {
  lib_eval "get_module_dependencies noversions"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Topological ordering
# ---------------------------------------------------------------------------

@test "get_ordered_modules: emits dependencies before their dependents" {
  lib_eval "get_ordered_modules"
  assert_success

  local order=" ${lines[*]} "
  # gamma -> beta -> alpha
  assert [ "${lines[0]}" = "alpha" ]
  assert_line "beta"
  assert_line "gamma"

  local i_alpha i_beta i_gamma n=0 line
  for line in "${lines[@]}"; do
    case "$line" in
      alpha) i_alpha=$n ;;
      beta) i_beta=$n ;;
      gamma) i_gamma=$n ;;
    esac
    n=$((n + 1))
  done
  assert [ "$i_alpha" -lt "$i_beta" ]
  assert [ "$i_beta" -lt "$i_gamma" ]
  refute [ -z "$order" ]
}

@test "get_ordered_modules: includes every available module exactly once" {
  lib_eval "get_ordered_modules | sort"
  assert_success
  assert_output - <<'EOF'
alpha
beta
delta
gamma
EOF
}

@test "get_ordered_modules: tolerates a dependency on a nonexistent module" {
  # delta depends on "ghost", which is not a module. It must still be ordered
  # rather than aborting the whole listing.
  lib_eval "get_ordered_modules"
  assert_success
  assert_line "delta"
  refute_line "ghost"
}

@test "get_ordered_modules: matches the real repository's documented order" {
  lib_eval "get_ordered_modules" "$REPO_ROOT"
  assert_success

  # README: nginx -> auth -> nextcloud -> everything else.
  assert [ "${lines[0]}" = "nginx" ]
  assert [ "${lines[1]}" = "auth" ]
  assert [ "${lines[2]}" = "nextcloud" ]
  assert [ "${#lines[@]}" -eq 8 ]
}

# ---------------------------------------------------------------------------
# update_installed_modules_env
# ---------------------------------------------------------------------------

@test "update_installed_modules_env: is a no-op when auth is not installed" {
  lib_eval "update_installed_modules_env" "$BATS_TEST_TMPDIR"
  assert_success
}

@test "update_installed_modules_env: always lists nginx and auth first, then the rest" {
  local base="$BATS_TEST_TMPDIR/base"
  mkdir -p "$base/store/auth" "$base/store/nginx" "$base/store/nextcloud" "$base/store/dokuwiki"

  lib_eval "update_installed_modules_env" "$base"
  assert_success

  run cat "$base/store/auth/auth.env"
  assert_output "HABIDAT_USER_INSTALLED_MODULES=nginx,auth,dokuwiki,nextcloud"
}

@test "update_installed_modules_env: is idempotent and rewrites rather than appends" {
  local base="$BATS_TEST_TMPDIR/base"
  mkdir -p "$base/store/auth" "$base/store/nextcloud"
  printf 'OTHER_KEY=keepme\nHABIDAT_USER_INSTALLED_MODULES=stale,values\n' > "$base/store/auth/auth.env"

  lib_eval "update_installed_modules_env" "$base"
  assert_success
  lib_eval "update_installed_modules_env" "$base"
  assert_success

  run grep -c 'HABIDAT_USER_INSTALLED_MODULES' "$base/store/auth/auth.env"
  assert_output "1"

  run grep -q 'OTHER_KEY=keepme' "$base/store/auth/auth.env"
  assert_success

  run grep 'HABIDAT_USER_INSTALLED_MODULES' "$base/store/auth/auth.env"
  assert_output "HABIDAT_USER_INSTALLED_MODULES=nginx,auth,nextcloud"
}
