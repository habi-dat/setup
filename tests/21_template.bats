#!/usr/bin/env bats
# lib/template.sh -- version-aware template resolution.
#
# This is the subtlest piece of the design: a migration to version N must use
# the templates as they existed at N, inheriting anything that did not change
# since an earlier version, and must never reach forward to a newer snapshot.

load helpers/load

FIXTURE="$BATS_TEST_DIRNAME/fixtures/modules"

# ---------------------------------------------------------------------------
# resolve_template
# ---------------------------------------------------------------------------

@test "resolve_template: exact version match wins" {
  lib_eval "resolve_template alpha 3.0.0 docker-compose.yml.j2"
  assert_success
  assert_output "$FIXTURE/alpha/versions/3.0.0/docker-compose.yml.j2"
}

@test "resolve_template: walks backwards when the version dir lacks the template" {
  # 2.0.0 has only migrate.sh, so the compose template is inherited from 1.0.0.
  lib_eval "resolve_template alpha 2.0.0 docker-compose.yml.j2"
  assert_success
  assert_output "$FIXTURE/alpha/versions/1.0.0/docker-compose.yml.j2"
}

@test "resolve_template: never reaches forward to a newer version" {
  # 4.0.0 also has a compose template. Resolving for 3.0.0 must not see it.
  lib_eval "resolve_template alpha 3.0.0 docker-compose.yml.j2"
  assert_success
  refute_output --partial "4.0.0"
}

@test "resolve_template: walks backwards past several versions" {
  # b.conf.j2 only ever existed in 1.0.0.
  lib_eval "resolve_template alpha 3.0.0 config/b.conf.j2"
  assert_success
  assert_output "$FIXTURE/alpha/versions/1.0.0/config/b.conf.j2"
}

@test "resolve_template: picks the newest applicable version of a changed template" {
  # a.conf.j2 exists in both 1.0.0 and 3.0.0.
  lib_eval "resolve_template alpha 3.0.0 config/a.conf.j2"
  assert_success
  assert_output "$FIXTURE/alpha/versions/3.0.0/config/a.conf.j2"

  lib_eval "resolve_template alpha 2.0.0 config/a.conf.j2"
  assert_success
  assert_output "$FIXTURE/alpha/versions/1.0.0/config/a.conf.j2"
}

@test "resolve_template: resolves for a target version above every snapshot" {
  lib_eval "resolve_template alpha 9.9.9 docker-compose.yml.j2"
  assert_success
  assert_output "$FIXTURE/alpha/versions/4.0.0/docker-compose.yml.j2"
}

@test "resolve_template: fails when no version provides the template" {
  lib_eval "resolve_template alpha 3.0.0 config/nope.j2"
  assert_failure
  assert_output ""
}

@test "resolve_template: fails for a target older than every snapshot" {
  lib_eval "resolve_template alpha 0.1.0 docker-compose.yml.j2"
  assert_failure
  assert_output ""
}

@test "resolve_template: fails for a module without a versions/ directory" {
  lib_eval "resolve_template beta 1.0.0 docker-compose.yml.j2"
  assert_failure
  assert_output ""
}

@test "resolve_template: never falls back to the module's root template" {
  # Documented contract: root templates are for setup.sh only. Give beta a root
  # template and confirm resolution still fails.
  cp -a "$FIXTURE" "$BATS_TEST_TMPDIR/fixture"
  echo "root compose" > "$BATS_TEST_TMPDIR/fixture/beta/docker-compose.yml.j2"

  lib_eval "resolve_template beta 1.0.0 docker-compose.yml.j2" "$BATS_TEST_TMPDIR/fixture"
  assert_failure
  assert_output ""
}

# ---------------------------------------------------------------------------
# render_template / render_versioned_template / copy_versioned_file
# ---------------------------------------------------------------------------

@test "render_template: renders a .j2 file through j2cli" {
  printf 'prefix=%s\n' '{{ HABIDAT_DOCKER_PREFIX }}' > "$BATS_TEST_TMPDIR/in.j2"

  lib_eval "
    export HABIDAT_DOCKER_PREFIX=habidattest
    render_template '$BATS_TEST_TMPDIR/in.j2' '$BATS_TEST_TMPDIR/out'
  "
  assert_success
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output "prefix=habidattest"
}

@test "render_template: a non-.j2 template goes through envsubst" {
  # NOTE: check_prerequisites() does not verify envsubst is installed, so this
  # fallback fails at run time on a host without gettext. No template in the
  # repo currently takes this path -- see 10_invariants.bats.
  command -v envsubst >/dev/null || skip "envsubst (gettext) not installed"

  printf 'prefix=$HABIDAT_DOCKER_PREFIX\n' > "$BATS_TEST_TMPDIR/in.tmpl"

  lib_eval "
    export HABIDAT_DOCKER_PREFIX=habidattest
    render_template '$BATS_TEST_TMPDIR/in.tmpl' '$BATS_TEST_TMPDIR/out'
  "
  assert_success
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output "prefix=habidattest"
}

@test "render_template: creates the output's parent directory" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/in.j2"

  lib_eval "render_template '$BATS_TEST_TMPDIR/in.j2' '$BATS_TEST_TMPDIR/deep/er/out'"
  assert_success
  assert [ -f "$BATS_TEST_TMPDIR/deep/er/out" ]
}

@test "render_template: dies on a missing template" {
  lib_eval "render_template '$BATS_TEST_TMPDIR/absent.j2' '$BATS_TEST_TMPDIR/out'"
  assert_failure
  assert_output --partial "Template not found"
}

@test "render_template: --dry-run writes nothing" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/in.j2"

  lib_eval "DRY_RUN=true; render_template '$BATS_TEST_TMPDIR/in.j2' '$BATS_TEST_TMPDIR/out'"
  assert_success
  assert_output --partial "[dry-run] Would render"
  assert [ ! -e "$BATS_TEST_TMPDIR/out" ]
}

@test "render_versioned_template: resolves then renders" {
  lib_eval "render_versioned_template alpha 2.0.0 docker-compose.yml.j2 '$BATS_TEST_TMPDIR/out'"
  assert_success
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output "compose v1"
}

@test "render_versioned_template: dies when the template cannot be resolved" {
  lib_eval "render_versioned_template alpha 3.0.0 config/nope.j2 '$BATS_TEST_TMPDIR/out'"
  assert_failure
  assert_output --partial "not found for alpha version 3.0.0"
}

@test "copy_versioned_file: copies without rendering" {
  lib_eval "copy_versioned_file alpha 1.0.0 config/a.conf.j2 '$BATS_TEST_TMPDIR/out'"
  assert_success
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output "a.conf v1"
}

@test "copy_versioned_file: --dry-run writes nothing" {
  lib_eval "DRY_RUN=true; copy_versioned_file alpha 1.0.0 config/a.conf.j2 '$BATS_TEST_TMPDIR/out'"
  assert_success
  assert_output --partial "[dry-run] Would copy"
  assert [ ! -e "$BATS_TEST_TMPDIR/out" ]
}

@test "remove_store_file: removes, and --dry-run does not" {
  touch "$BATS_TEST_TMPDIR/victim"

  lib_eval "DRY_RUN=true; remove_store_file '$BATS_TEST_TMPDIR/victim'"
  assert_success
  assert [ -e "$BATS_TEST_TMPDIR/victim" ]

  lib_eval "remove_store_file '$BATS_TEST_TMPDIR/victim'"
  assert_success
  assert [ ! -e "$BATS_TEST_TMPDIR/victim" ]
}
