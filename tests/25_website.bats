#!/usr/bin/env bats
# Website install host and image selection.

load helpers/load

# shellcheck source=website/lib/common.sh
source "$REPO_ROOT/website/lib/common.sh"

@test "a website hostname is a DNS name without a scheme, path, or port" {
  run website_hostname 'Schlor.ORG'
  assert_success
  assert_output 'schlor.org'

  run website_hostname 'https://schlor.org'
  assert_failure

  run website_hostname 'schlor.org/edit'
  assert_failure

  run website_hostname 'schlor.org:443'
  assert_failure
}

@test "a website install renders the given host for nginx, letsencrypt, and the app" {
  local env=(
    HABIDAT_WEBSITE_SESSION_SECRET=secret
    HABIDAT_PROTOCOL=https
    HABIDAT_USER_SUBDOMAIN=user
    HABIDAT_DOMAIN=habidat.localhost
    HABIDAT_WEBSITE_OIDC_CLIENT_ID=schlor
    HABIDAT_WEBSITE_OIDC_CLIENT_SECRET=oidc
    HABIDAT_WEBSITE_HOST=schlor.org
    HABIDAT_ADMIN_EMAIL=admin@example.org
    HABIDAT_WEBSITE_PROJECTID=schlor
    HABIDAT_WEBSITE_TITLE=SchloR
    HABIDAT_WEBSITE_LDAP_GROUP=editors
    HABIDAT_WEBSITE_SRC=
    HABIDAT_WEBSITE_IMAGE=
    HABIDAT_DOCKER_PREFIX=habidat
    HABIDAT_PROXY_NETWORK=habidat-proxy
    HABIDAT_CREATE_SELFSIGNED=false
  )
  run env -i PATH="$PATH" HOME="${HOME:-/tmp}" "${env[@]}" \
    "$REPO_ROOT/lib/render.py" "$REPO_ROOT/website/config/website.env.j2"
  assert_success
  assert_output --partial 'VIRTUAL_HOST=schlor.org'
  assert_output --partial 'LETSENCRYPT_HOST=schlor.org'
  assert_output --partial 'OIDC_REDIRECT_URI=https://schlor.org/auth/callback'
  assert_output --partial 'OIDC_ISSUER=https://user.habidat.localhost/oidc'
  assert_output --partial 'OIDC_CLIENT_ID=schlor'
  assert_output --partial 'WEBSITE_ALLOW_PUBLISH=1'

  run env -i PATH="$PATH" HOME="${HOME:-/tmp}" "${env[@]}" \
    "$REPO_ROOT/lib/render.py" "$REPO_ROOT/website/docker-compose.yml.j2"
  assert_success
  assert_output --partial 'image: soudis/draftpunk:latest'
  refute_output --partial 'habidat-website:0.1.0'

  env[11]=HABIDAT_WEBSITE_SRC=/code/sources/draftpunk
  run env -i PATH="$PATH" HOME="${HOME:-/tmp}" "${env[@]}" \
    "$REPO_ROOT/lib/render.py" "$REPO_ROOT/website/docker-compose.yml.j2"
  assert_success
  assert_output --partial 'image: habidat-website:0.1.0'
  assert_output --partial 'context: /code/sources/draftpunk'
}
