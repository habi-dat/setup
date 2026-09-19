#!/usr/bin/env bats
# lib/render.py -- the template renderer.
#
# This replaced j2cli, so the properties the rest of the design leans on are
# now ours to guarantee rather than a third party's. Chief among them:
# StrictUndefined, which is what turns a misspelled variable into a failed
# install instead of a config file with a hole in it.

load helpers/load

RENDER="$BATS_TEST_DIRNAME/../lib/render.py"

# render_py <template-content> [env assignments...]
#   Writes the content to a temp template and renders it to stdout.
render_py() {
  local content="$1"; shift
  printf '%s' "$content" > "$BATS_TEST_TMPDIR/t.j2"
  run env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@" "$RENDER" "$BATS_TEST_TMPDIR/t.j2"
}

# ---------------------------------------------------------------------------
# The guarantees the suite and the module scripts depend on
# ---------------------------------------------------------------------------

@test "substitutes variables from the process environment" {
  render_py 'domain={{ HABIDAT_DOMAIN }}' HABIDAT_DOMAIN=example.org
  assert_success
  assert_output "domain=example.org"
}

@test "an undefined variable is an error, not an empty string" {
  # The single most important property: a typo must stop the install.
  render_py 'x={{ HABIDAT_NOT_SET }}'
  assert_failure
  assert_output --partial "HABIDAT_NOT_SET' is undefined"
}

@test "the error names the template so the failure is actionable" {
  render_py 'x={{ HABIDAT_NOT_SET }}'
  assert_failure
  assert_output --partial "t.j2"
  # ...and is a message, not a Python traceback.
  refute_output --partial "Traceback"
}

@test "default(\"\") yields an empty string" {
  render_py 'x={{ HABIDAT_ABSENT | default("") }}'
  assert_success
  assert_output "x="
}

@test "default(none) yields the literal string None" {
  # Documented here because it is a trap, not a feature: nextcloud.env.j2 uses
  # it and 30_render.bats ratchets the result. Pinned so the behaviour cannot
  # change silently underneath that ratchet.
  render_py 'x={{ HABIDAT_ABSENT | default(none) }}'
  assert_success
  assert_output "x=None"
}

@test "an empty environment variable renders as empty, not as undefined" {
  render_py 'x={{ HABIDAT_EMPTY }}' HABIDAT_EMPTY=
  assert_success
  assert_output "x="
}

@test "conditionals and filters work" {
  render_py '{% if HABIDAT_FLAG == "true" %}on{% else %}off{% endif %}' HABIDAT_FLAG=true
  assert_success
  assert_output "on"

  render_py '{{ HABIDAT_DOMAIN | replace(".", "\\.") }}' HABIDAT_DOMAIN=example.org
  assert_success
  assert_output 'example\.org'
}

@test "{% raw %} passes other tools' syntax through untouched" {
  # nginx, openldap and direktkredit templates all rely on this.
  render_py '{% raw %}$http_origin {{ LDAP_BACKEND }}{% endraw %}'
  assert_success
  assert_output '$http_origin {{ LDAP_BACKEND }}'
}

@test "a trailing newline is preserved" {
  printf 'line\n' > "$BATS_TEST_TMPDIR/nl.j2"
  run env -i PATH="$PATH" "$RENDER" "$BATS_TEST_TMPDIR/nl.j2" "$BATS_TEST_TMPDIR/nl.out"
  assert_success
  run od -c "$BATS_TEST_TMPDIR/nl.out"
  assert_output --partial 'l   i   n   e  \n'
}

@test "output is not HTML-escaped" {
  # These are config files; escaping & or quotes would corrupt passwords.
  render_py 'pw={{ HABIDAT_PW }}' 'HABIDAT_PW=a&b<c>"d'"'"'e'
  assert_success
  assert_output 'pw=a&b<c>"d'"'"'e'
}

# ---------------------------------------------------------------------------
# File handling
# ---------------------------------------------------------------------------

@test "writes to the named output file" {
  printf 'x={{ V }}\n' > "$BATS_TEST_TMPDIR/o.j2"
  run env -i PATH="$PATH" V=1 "$RENDER" "$BATS_TEST_TMPDIR/o.j2" "$BATS_TEST_TMPDIR/o.out"
  assert_success
  assert_output ""
  run cat "$BATS_TEST_TMPDIR/o.out"
  assert_output "x=1"
}

@test "creates missing parent directories of the output" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/p.j2"
  run env -i PATH="$PATH" "$RENDER" "$BATS_TEST_TMPDIR/p.j2" "$BATS_TEST_TMPDIR/a/b/c.out"
  assert_success
  assert [ -f "$BATS_TEST_TMPDIR/a/b/c.out" ]
}

@test "writes nothing when rendering fails" {
  printf 'x={{ MISSING }}\n' > "$BATS_TEST_TMPDIR/f.j2"
  run env -i PATH="$PATH" "$RENDER" "$BATS_TEST_TMPDIR/f.j2" "$BATS_TEST_TMPDIR/f.out"
  assert_failure
  assert [ ! -e "$BATS_TEST_TMPDIR/f.out" ]
}

@test "reports a missing template without a traceback" {
  run env -i PATH="$PATH" "$RENDER" "$BATS_TEST_TMPDIR/nope.j2"
  assert_failure
  assert_output --partial "template not found"
  refute_output --partial "Traceback"
}

@test "reports a syntax error with its line number" {
  printf 'ok\n{%% if %%}\n' > "$BATS_TEST_TMPDIR/s.j2"
  run env -i PATH="$PATH" "$RENDER" "$BATS_TEST_TMPDIR/s.j2"
  assert_failure
  assert_output --partial ":2:"
  refute_output --partial "Traceback"
}

@test "--help works, which is how check_prerequisites probes for Jinja2" {
  run "$RENDER" --help
  assert_success
  assert_output --partial "template"
}

# ---------------------------------------------------------------------------
# Integration with the shell libraries
# ---------------------------------------------------------------------------

@test "no module script calls j2 any more" {
  # The migration away from j2cli must be complete: a leftover `j2` call would
  # fail on any host that followed the current README.
  local hits
  hits="$(cd "$REPO_ROOT" && grep -rn '^[[:space:]]*j2 ' --include='*.sh' . \
    | grep -v './node_modules/' | grep -v './tests/' || true)"

  [[ -z "$hits" ]] || fail_with_list "leftover j2cli invocations:" "$hits"
}

@test "every module script renders through lib/render.py" {
  # Counts the call sites so a newly added setup.sh that shells out to something
  # else is noticed.
  local count
  count="$(cd "$REPO_ROOT" && grep -rc 'lib/render.py' --include='setup.sh' --include='update.sh' . \
    | grep -v ':0$' | wc -l)"
  assert [ "$count" -ge 8 ]
}
