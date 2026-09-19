#!/usr/bin/env bats
# lib/version.sh -- version comparison and export/import script resolution.
#
# Every update decision the CLI makes (which migrations to run, whether a
# downgrade was requested, which export script matches the installed version)
# routes through these comparisons, so they are worth pinning precisely.

load helpers/load

# ---------------------------------------------------------------------------
# version_cmp and the predicates built on it
# ---------------------------------------------------------------------------

@test "version_cmp: equal versions compare as 0" {
  assert_version_cmp "33.0.0" "33.0.0" "0"
  assert_version_cmp "1.35.8" "1.35.8" "0"
}

@test "version_cmp: orders the real nextcloud upgrade path" {
  assert_version_order "32.0.5" "32.0.6"
  assert_version_order "32.0.6" "33.0.0"
  assert_version_order "33.0.0" "34.0.3"
  assert_version_order "32.0.5" "34.0.3"
}

@test "version_cmp: compares numerically, not lexically" {
  # The bug this guards: "1.35.8" > "1.35.10" under string comparison, which
  # would silently skip a mediawiki migration.
  assert_version_order "1.35.8" "1.35.10"
  assert_version_order "2.0.0" "10.0.0"
  assert_version_order "3.3.2" "3.3.10"
}

@test "version_cmp: handles differing component counts" {
  assert_version_order "33.0" "33.0.1"
  assert_version_order "1" "1.0.1"
}

@test "version_eq: only exact string equality counts" {
  lib_eval "version_eq '33.0.0' '33.0.0'"
  assert_success
  lib_eval "version_eq '33.0.0' '33.0'"
  assert_failure
}

@test "version_ge/version_le: are reflexive" {
  lib_eval "version_ge '33.0.0' '33.0.0'"
  assert_success
  lib_eval "version_le '33.0.0' '33.0.0'"
  assert_success
}

# ---------------------------------------------------------------------------
# Version discovery
# ---------------------------------------------------------------------------

@test "get_installed_version: reads store/<module>/version and strips whitespace" {
  lib_eval "get_installed_version alpha"
  assert_success
  assert_output "2.0.0"
}

@test "get_installed_version: is empty for a module that is not installed" {
  lib_eval "get_installed_version beta"
  assert_success
  assert_output ""
}

@test "get_target_version: reads <module>/version" {
  lib_eval "get_target_version alpha"
  assert_success
  assert_output "3.0.0"
}

@test "list_migration_versions: only lists version dirs that have a migrate.sh" {
  # alpha/versions/4.0.0 exists but carries no migrate.sh.
  lib_eval "list_migration_versions alpha"
  assert_success
  assert_output - <<'EOF'
1.0.0
2.0.0
3.0.0
EOF
}

@test "list_all_version_dirs: lists every version dir, ascending" {
  lib_eval "list_all_version_dirs alpha"
  assert_success
  assert_output - <<'EOF'
1.0.0
2.0.0
3.0.0
4.0.0
EOF
}

@test "list_migration_versions: is empty for a module without versions/" {
  lib_eval "list_migration_versions beta"
  assert_success
  assert_output ""
}

@test "is_known_migration_version: distinguishes migration steps from bare version dirs" {
  lib_eval "is_known_migration_version alpha 3.0.0"
  assert_success
  lib_eval "is_known_migration_version alpha 4.0.0"
  assert_failure
  lib_eval "is_known_migration_version alpha 9.9.9"
  assert_failure
}

# ---------------------------------------------------------------------------
# resolve_versioned_script -- "latest applicable" export/import selection
# ---------------------------------------------------------------------------

@test "resolve_versioned_script: picks the highest script version <= installed" {
  # alpha/export has 1.0.0 and 3.0.0; alpha is installed at 2.0.0.
  lib_eval "resolve_versioned_script alpha export"
  assert_success
  assert_output --partial "/alpha/export/1.0.0.sh"
}

@test "resolve_versioned_script: an explicit version overrides the installed one" {
  lib_eval "resolve_versioned_script alpha export 3.0.0"
  assert_success
  assert_output --partial "/alpha/export/3.0.0.sh"
}

@test "resolve_versioned_script: an exact match wins over an older script" {
  lib_eval "resolve_versioned_script alpha export 1.0.0"
  assert_success
  assert_output --partial "/alpha/export/1.0.0.sh"
}

@test "resolve_versioned_script: fails when every script is newer than installed" {
  lib_eval "resolve_versioned_script alpha export 0.9.0"
  assert_failure
  assert_output ""
}

@test "resolve_versioned_script: fails when the module has no such script dir" {
  lib_eval "resolve_versioned_script beta export 1.0.0"
  assert_failure
  assert_output ""
}

@test "resolve_versioned_script: fails when the module is not installed and no version given" {
  lib_eval "resolve_versioned_script beta import"
  assert_failure
  assert_output ""
}
