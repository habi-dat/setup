#!/usr/bin/env bats
# Template rendering across configuration profiles.
#
# lib/render.py runs Jinja2 with StrictUndefined: a template that reads a variable
# nobody supplies aborts the install at the point it is rendered, which for a
# migration means halfway through an upgrade. Rendering everything up front,
# under each supported configuration, moves that failure into CI.
#
# Every template is rendered once per profile in setup_file and cached; the
# tests below read that cache. See tests/helpers/render.bash.

load helpers/load

setup_file() {
  render_setup_file
}

# ---------------------------------------------------------------------------
# Everything renders, under every profile
# ---------------------------------------------------------------------------

@test "every template renders under every profile" {
  local profile failures=() line

  for profile in "${RENDER_PROFILES[@]}"; do
    while IFS=$'\t' read -r template err; do
      [[ -n "$template" ]] && failures+=("$template ($profile): $err")
    done < <(render_failures "$profile")
  done

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "templates failed to render:" "${failures[@]}"
  fi
}

@test "the render cache covers every template in the repository" {
  # Guards the harness itself: if the cache silently rendered nothing, every
  # test below would vacuously pass.
  local expected actual
  expected="$(repo_templates | wc -l)"
  actual="$(for_each_rendered dev '' | wc -l)"

  assert [ "$expected" -gt 40 ]
  assert_equal "$actual" "$expected"
}

@test "no rendered file leaves Jinja control markup behind" {
  local template failures=()

  while IFS= read -r template; do
    # {% raw %} blocks legitimately emit literal {{ }} for nginx, openldap and
    # direktkredit to expand, so only unprocessed control tags are suspicious.
    if grep -q '{%[[:space:]]*\(if\|for\|raw\|endif\|endfor\|endraw\)' "$RENDER_CACHE/dev/$template"; then
      failures+=("$template")
    fi
  done < <(for_each_rendered dev '')

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "rendered output still contains Jinja control markup:" "${failures[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Rendered compose files must be valid compose files
# ---------------------------------------------------------------------------

@test "every rendered docker-compose.yml.j2 is accepted by docker compose" {
  command -v docker >/dev/null || skip "docker CLI not available"

  local template profile failures=()

  for profile in "${RENDER_PROFILES[@]}"; do
    while IFS= read -r template; do
      compose_config "$RENDER_CACHE/$profile/$template" --quiet
      if [[ "$status" -ne 0 ]]; then
        failures+=("$template ($profile): $(printf '%s' "$output" | grep -v 'level=warning' | head -1)")
      fi
    done < <(for_each_rendered "$profile" 'docker-compose.yml.j2')
  done

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "rendered compose files were rejected:" "${failures[@]}"
  fi
}

@test "compose templates using the deprecated 'external: name:' form are exactly the known ones" {
  # Compose v2 replaced `external: {name: X}` with `name: X` plus
  # `external: true`. nextcloud was migrated in c0949a3; four modules were
  # missed and still emit a deprecation warning.
  #
  # RATCHET: this is the current known-bad set. Fixing a module means deleting
  # its two lines here; a new offender fails the test.
  command -v docker >/dev/null || skip "docker CLI not available"

  local known=(
    direktkredit/docker-compose.yml.j2
    direktkredit/versions/1.2.1/docker-compose.yml.j2
    dokuwiki/docker-compose.yml.j2
    dokuwiki/versions/0.0.1/docker-compose.yml.j2
    mailtrain/docker-compose.yml.j2
    mailtrain/versions/0.0.1/docker-compose.yml.j2
    mediawiki/docker-compose.yml.j2
    mediawiki/versions/1.35.8/docker-compose.yml.j2
  )

  local template found=()
  while IFS= read -r template; do
    compose_config "$RENDER_CACHE/dev/$template"
    if printf '%s' "$output" | grep -q 'external.name is deprecated'; then
      found+=("$template")
    fi
  done < <(for_each_rendered dev 'docker-compose.yml.j2')

  assert_equal "$(printf '%s\n' "${found[@]}")" "$(printf '%s\n' "${known[@]}")"
}

@test "every long-running compose service pins a container_name under the docker prefix" {
  # Export/import scripts and several setup steps address containers by literal
  # name ("$HABIDAT_DOCKER_PREFIX-nextcloud-db"), so a service that omits
  # container_name silently breaks backup and restore.
  #
  # One-shot services are exempt: auth's user-init declares restart: "no" and is
  # only ever started via `compose run --rm`, so naming it would prevent a
  # second run.
  command -v docker >/dev/null || skip "docker CLI not available"

  local template failures=() problems

  while IFS= read -r template; do
    compose_config "$RENDER_CACHE/dev/$template" --format json
    [[ "$status" -eq 0 ]] || continue

    problems=$(printf '%s' "$output" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
doc = json.loads(raw[start:]) if start >= 0 else {}
for name, svc in (doc.get("services") or {}).items():
    if str(svc.get("restart", "no")) == "no":
        continue  # one-shot task, see comment above
    cn = svc.get("container_name")
    if not cn:
        print(f"{name}: no container_name")
    elif not cn.startswith("habidattest"):
        print(f"{name}: container_name {cn!r} is not prefixed")
')
    [[ -n "$problems" ]] && failures+=("$template: $(printf '%s' "$problems" | tr '\n' ';')")
  done < <(for_each_rendered dev 'docker-compose.yml.j2')

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "compose services with container_name problems:" "${failures[@]}"
  fi
}

@test "no compose service binds a host port outside the reverse proxy" {
  # Services reach the outside world through the nginx proxy on 80/443. A
  # published port elsewhere exposes a database or admin UI to the host.
  command -v docker >/dev/null || skip "docker CLI not available"

  local template failures=() published
  local allowed='^(80|443|1025|8025|3003|3004|389)$'

  while IFS= read -r template; do
    compose_config "$RENDER_CACHE/dev/$template" --format json
    [[ "$status" -eq 0 ]] || continue

    published=$(printf '%s' "$output" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
doc = json.loads(raw[start:]) if start >= 0 else {}
for name, svc in (doc.get("services") or {}).items():
    for p in svc.get("ports") or []:
        pub = p.get("published")
        if pub:
            print(f"{name}:{pub}:{p.get('"'"'host_ip'"'"') or '"'"'*'"'"'}")
')
    local entry
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local port="${entry#*:}"; port="${port%%:*}"
      [[ "$port" =~ $allowed ]] || failures+=("$template: $entry")
    done <<< "$published"
  done < <(for_each_rendered dev 'docker-compose.yml.j2')

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "unexpected published host ports:" "${failures[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Rendered env files
# ---------------------------------------------------------------------------

@test "every rendered .env file is a valid KEY=VALUE file" {
  local template failures=() line n

  while IFS= read -r template; do
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" == *=* ]] || failures+=("$template line $n: not KEY=VALUE: $line")
    done < "$RENDER_CACHE/dev/$template"
  done < <(for_each_rendered dev '.env.j2')

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "invalid rendered env files:" "${failures[@]}"
  fi
}

@test "env values rendering as the literal string None are exactly the known ones" {
  # Jinja's `default(none)` renders as the four characters "None", not an empty
  # string. nextcloud/config/nextcloud.env.j2 uses it for five variables; the
  # 32.0.5 snapshot of the same file correctly used `default("")`. Any of those
  # five left unset in setup.env becomes the string None, which the nextcloud
  # bootstrap scripts then interpolate into URLs.
  #
  # RATCHET: only HABIDAT_WIKI_SUBDOMAIN is unset in the test profiles, so only
  # it shows up here. Switching nextcloud.env.j2 to default("") empties this
  # list.
  local known=("nextcloud/config/nextcloud.env.j2:HABIDAT_WIKI_SUBDOMAIN")

  local template found=() line n
  while IFS= read -r template; do
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"?None\"?$ ]]; then
        found+=("$template:${BASH_REMATCH[1]}")
      fi
    done < "$RENDER_CACHE/dev/$template"
  done < <(for_each_rendered dev '.env.j2')

  assert_equal "$(printf '%s\n' "${found[@]}")" "$(printf '%s\n' "${known[@]}")"
}

@test "no rendered secret is empty when the configuration supplies one" {
  # A password variable that renders empty means a service comes up with no
  # credentials rather than failing loudly.
  #
  # Checked against the prod profile: the dev profile deliberately leaves the
  # SMTP credentials blank because mailhog accepts unauthenticated mail.
  local template failures=() line

  while IFS= read -r template; do
    while IFS= read -r line; do
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*(PASSWORD|SECRET|API_KEY))=\"?\"?$ ]]; then
        failures+=("$template: ${BASH_REMATCH[1]} is empty")
      fi
    done < "$RENDER_CACHE/prod/$template"
  done < <(for_each_rendered prod '.env.j2')

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "secrets rendered empty:" "${failures[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Profile-specific behaviour
# ---------------------------------------------------------------------------

@test "nginx: the letsencrypt companion appears only in the prod profile" {
  refute grep -q "letsencrypt-nginx-proxy-companion" "$(rendered nginx/docker-compose.yml.j2 dev)"

  run cat "$(rendered nginx/docker-compose.yml.j2 prod)"
  assert_output --partial "letsencrypt-nginx-proxy-companion"
  assert_output --partial "DEFAULT_EMAIL=admin@example.com"
}

@test "auth: mailhog appears only when HABIDAT_MAILHOG is true" {
  run cat "$(rendered auth/docker-compose.yml.j2 dev)"
  assert_output --partial "mailhog/mailhog"

  refute grep -q "mailhog/mailhog" "$(rendered auth/docker-compose.yml.j2 prod)"
}

@test "auth: the backend network is declared external only when one is supplied" {
  run cat "$(rendered auth/docker-compose.yml.j2 dev)"
  assert_output --partial "driver: bridge"

  run cat "$(rendered auth/docker-compose.yml.j2 existing-net)"
  assert_output --partial "external:"
  refute_output --partial "driver: bridge"
}

@test "auth: the LDAP port mapping is passed through verbatim" {
  # auth/setup.sh computes "127.0.0.1:389:389" when HABIDAT_EXPOSE_LDAP is true
  # and a bare "389" otherwise; the 127.0.0.1 binding is the point of commit
  # c7406f7, so the template must not reinterpret it.
  run cat "$(rendered auth/docker-compose.yml.j2 dev)"
  assert_output --partial '- "389"'

  RUNTIME_VARS+=("HABIDAT_LDAP_PORT_MAPPING=127.0.0.1:389:389")
  render_template auth/docker-compose.yml.j2 dev
  assert_success
  assert_output --partial '- "127.0.0.1:389:389"'
}

@test "nginx: the CORS origin map escapes dots in the domain" {
  # An unescaped dot in the regex matches any character, letting
  # foo-example-org.attacker.test through as a permitted origin.
  run cat "$(rendered nginx/config/cors_map.conf.j2 prod)"
  assert_output --partial 'example\.org'
  refute_output --partial '.*\.example.org$'
}

@test "nginx: the CORS map keeps nginx's own variables literal" {
  run cat "$(rendered nginx/config/cors_map.conf.j2 dev)"
  assert_output --partial '$http_origin'
  assert_output --partial '$cors_header'
}

@test "auth: the memberOf overlay keeps LDAP_BACKEND for the container to expand" {
  # {% raw %} guards this. Without it, Jinja would fail on an undefined
  # LDAP_BACKEND instead of emitting the placeholder openldap substitutes.
  run cat "$(rendered auth/config/memberOf.ldif.j2 dev)"
  assert_output --partial '{{ LDAP_BACKEND }}'
}

@test "direktkredit: the LDAP search filter keeps its {{username}} placeholder" {
  run cat "$(rendered direktkredit/config/settings.env.j2 dev)"
  assert_output --partial '(|(mail={{username}})(uid={{username}}))'
}

@test "auth: the bootstrap LDIF places the admin under the configured LDAP base" {
  run cat "$(rendered auth/config/bootstrap.ldif.j2 prod)"
  assert_output --partial "dn: cn=admin,ou=users,dc=example,dc=org"
  assert_output --partial "dn: ou=groups,dc=example,dc=org"
  assert_output --partial "mail: admin@example.com"
}

@test "auth: the SAML app store points every entry at the configured domain" {
  run cat "$(rendered auth/config/appStore.json.j2 prod)"
  assert_output --partial "https://cloud.example.org/apps/user_saml/saml/metadata"
  refute_output --partial "habidat.localhost"

  # Must stay parseable -- the auth service reads it as JSON.
  run python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$(rendered auth/config/appStore.json.j2 prod)"
  assert_success
}

# ---------------------------------------------------------------------------
# Image tags must track module versions
# ---------------------------------------------------------------------------

@test "nextcloud: the compose image tag is a prefix of the module version" {
  # A habidat-only bump (34.0.4.1) keeps the Nextcloud image at 34.0.4. The
  # store marker may grow a suffix; the image tag must still be that version
  # or a prefix of it. Forgetting to bump the image on a real Nextcloud upgrade
  # still fails (34.0.5 vs image 34.0.4).
  local version tag
  version="$(repo_module_version nextcloud)"
  tag="$(repo_nextcloud_image_tag "$(rendered nextcloud/docker-compose.yml.j2 dev)")"
  version_covers_image_tag "$version" "$tag" \
    || fail "image tag $tag is not a prefix of module version $version"
}

@test "every nextcloud version snapshot tags its app image with a prefix of its version" {
  # The image *name* legitimately changed at 32.0.6, when commit ebd84a7 dropped
  # the custom habidat/nextcloud build for the official nextcloud image. Only the
  # tag has to track the version directory (or be a prefix of it). Config-only
  # snapshots have no compose file and inherit the previous image.
  local ver compose tag failures=()

  while IFS= read -r ver; do
    compose="$RENDER_CACHE/dev/nextcloud/versions/$ver/docker-compose.yml.j2"
    [[ -f "$compose" ]] || continue
    tag="$(repo_nextcloud_image_tag "$compose")" || tag=""
    version_covers_image_tag "$ver" "$tag" \
      || failures+=("versions/$ver: image tag '${tag:-<missing>}' is not a prefix of $ver")
  done < <(repo_version_dirs nextcloud)

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "nextcloud snapshots whose image tag is not their version:" "${failures[@]}"
  fi
}

@test "auth: nginx-proxy CERT_NAME is only set for the mkcert wildcard" {
  # Let's Encrypt stores user.example.org.crt. CERT_NAME=example.org makes
  # nginx-proxy look for the apex file instead, which is SSL unrecognized_name
  # on an existing nginx-proxy (HABIDAT_EXISTING_NGINX_GENERATOR_NETWORK).
  run cat "$(rendered auth/docker-compose.yml.j2 prod)"
  assert_output --partial "LETSENCRYPT_HOST=user.example.org"
  refute_output --partial "CERT_NAME="

  run cat "$(rendered auth/docker-compose.yml.j2 dev)"
  assert_output --partial "CERT_NAME=habidat.localhost"
  refute_output --partial "LETSENCRYPT_HOST="
}

@test "auth: the compose image tag is a prefix of the module version" {
  # A habidat-only bump (2.0.0.1) keeps habidat/auth:2.0.0; 2.0.1 ships
  # habidat/auth:2.0.1. The tag must still be a prefix of the module version.
  local version tag worker
  version="$(repo_module_version auth)"
  tag="$(repo_compose_image_tag "$(rendered auth/docker-compose.yml.j2 dev)" 'habidat/auth')"
  worker="$(repo_compose_image_tag "$(rendered auth/docker-compose.yml.j2 dev)" 'habidat/auth-worker')"
  version_covers_image_tag "$version" "$tag" \
    || fail "image tag $tag is not a prefix of module version $version"
  version_covers_image_tag "$version" "$worker" \
    || fail "worker image tag $worker is not a prefix of module version $version"
}

@test "every auth version snapshot tags its app image with a prefix of its version" {
  local ver compose tag failures=()

  while IFS= read -r ver; do
    compose="$RENDER_CACHE/dev/auth/versions/$ver/docker-compose.yml.j2"
    [[ -f "$compose" ]] || continue
    tag="$(repo_compose_image_tag "$compose" 'habidat/auth')" || tag=""
    version_covers_image_tag "$ver" "$tag" \
      || failures+=("versions/$ver: image tag '${tag:-<missing>}' is not a prefix of $ver")
  done < <(repo_version_dirs auth)

  if [[ ${#failures[@]} -gt 0 ]]; then
    fail_with_list "auth snapshots whose image tag is not their version:" "${failures[@]}"
  fi
}
