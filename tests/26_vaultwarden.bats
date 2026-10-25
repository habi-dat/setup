#!/usr/bin/env bats
# Vaultwarden: SSO wiring, self-signed mode, configure.sh input checks, and the
# sync container's own unit tests.

load helpers/load

vw_env() {
  local selfsigned="${1:-false}"
  VW_ENV=(
    HABIDAT_PROTOCOL=https
    HABIDAT_DOMAIN=habidat.localhost
    HABIDAT_USER_SUBDOMAIN=user
    HABIDAT_VAULTWARDEN_SUBDOMAIN=vault
    HABIDAT_VAULTWARDEN_ADMIN_EMAIL=vault-admin@example.org
    HABIDAT_VAULTWARDEN_OIDC_CLIENT_SECRET=oidc-secret
    HABIDAT_VAULTWARDEN_ADMIN_TOKEN=admin-token
    HABIDAT_ADMIN_EMAIL=admin@example.org
    HABIDAT_DOCKER_PREFIX=habidat
    HABIDAT_PROXY_NETWORK=habidat-proxy
    HABIDAT_BACKEND_NETWORK=habidat-backend
    HABIDAT_LDAP_BASE=dc=habidat,dc=localhost
    HABIDAT_LDAP_ADMIN_PASSWORD=ldap-pw
    HABIDAT_CREATE_SELFSIGNED="$selfsigned"
  )
}

render_vw() {
  run env -i PATH="$PATH" HOME="${HOME:-/tmp}" "${VW_ENV[@]}" "$REPO_ROOT/lib/render.py" "$REPO_ROOT/vaultwarden/$1"
}

@test "vaultwarden: logs in only through auth's OIDC issuer" {
  vw_env
  render_vw config/vaultwarden.env.j2
  assert_success
  assert_line 'DOMAIN=https://vault.habidat.localhost'
  assert_line 'SSO_ENABLED=true'
  assert_line 'SSO_ONLY=true'
  assert_line 'SSO_AUTHORITY=https://user.habidat.localhost/oidc'
  assert_line 'SSO_CLIENT_ID=vaultwarden'
  assert_line 'SSO_CLIENT_SECRET=oidc-secret'
  assert_line 'SSO_AUTH_ONLY_NOT_SESSION=true'
  assert_line 'SIGNUPS_ALLOWED=false'
}

@test "vaultwarden: one organization with groups, created only by the super admin, and no SMTP" {
  vw_env
  render_vw config/vaultwarden.env.j2
  assert_success
  assert_line 'ORG_GROUPS_ENABLED=true'
  assert_line 'ORG_CREATION_USERS=vault-admin@example.org'
  # Without SMTP, invitations are accepted on the first login (ADR 0003).
  refute_output --partial 'SMTP_'
}

@test "vaultwarden: the auth app is open to every user and redirects to Vaultwarden's SSO callback" {
  vw_env
  render_vw config/auth-app.json.j2
  assert_success
  run python3 -c 'import json,sys; a=json.load(sys.stdin)[0]; print(a["id"], a["oidc"]["clientId"], a["oidc"]["redirectUris"][0], len(a["groups"]))' <<<"$output"
  assert_success
  assert_output 'vaultwarden vaultwarden https://vault.habidat.localhost/identity/connect/oidc-signin 0'
}

@test "vaultwarden: the sync reads auth's LDAP and talks to Vaultwarden on the backend network" {
  vw_env
  render_vw config/sync.env.j2
  assert_success
  assert_line 'LDAP_URL=ldap://habidat-ldap:389'
  assert_line 'LDAP_BIND_DN=cn=admin,dc=habidat,dc=localhost'
  assert_line 'LDAP_GROUPS_DN=ou=groups,dc=habidat,dc=localhost'
  assert_line 'VW_URL=http://habidat-vaultwarden'
  assert_line 'VW_OWNER_EMAIL=vault-admin@example.org'
  assert_line 'SYNC_INTERVAL_SECONDS=300'
}

@test "vaultwarden: only self-signed mode trusts the mkcert root and routes auth to the host" {
  vw_env false
  render_vw docker-compose.yml.j2
  assert_success
  refute_output --partial 'mkcert'
  refute_output --partial 'host-gateway'

  vw_env true
  render_vw docker-compose.yml.j2
  assert_success
  assert_output --partial './mkcert-root.crt:/usr/local/share/ca-certificates/habidat-mkcert.crt:ro'
  assert_output --partial 'update-ca-certificates && exec /start.sh'
  assert_output --partial '"user.habidat.localhost:host-gateway"'
}

@test "vaultwarden configure: rejects an organization key that is not organization.<uuid>" {
  run env -i PATH="$PATH" HABIDAT_DOCKER_PREFIX=habidat \
    VW_ORG_CLIENT_ID=user.0b9e3c6e-58a4-4d0e-9a6b-2f0a3b1c4d5e VW_ORG_CLIENT_SECRET=s \
    VW_BOT_CLIENT_ID=user.0b9e3c6e-58a4-4d0e-9a6b-2f0a3b1c4d5e VW_BOT_CLIENT_SECRET=s VW_BOT_MASTER_PASSWORD=pw \
    bash -c "cd '$REPO_ROOT/vaultwarden' && ./configure.sh"
  assert_failure
  assert_output --partial 'organization.<uuid>'
}

@test "vaultwarden configure: rejects the organization key in place of the bot's personal key" {
  run env -i PATH="$PATH" HABIDAT_DOCKER_PREFIX=habidat \
    VW_ORG_CLIENT_ID=organization.0b9e3c6e-58a4-4d0e-9a6b-2f0a3b1c4d5e VW_ORG_CLIENT_SECRET=s \
    VW_BOT_CLIENT_ID=organization.0b9e3c6e-58a4-4d0e-9a6b-2f0a3b1c4d5e VW_BOT_CLIENT_SECRET=s VW_BOT_MASTER_PASSWORD=pw \
    bash -c "cd '$REPO_ROOT/vaultwarden' && ./configure.sh"
  assert_failure
  assert_output --partial 'user.<uuid>'
}

@test "vaultwarden configure: rejects a single quote, which the compose env file cannot carry" {
  run env -i PATH="$PATH" HABIDAT_DOCKER_PREFIX=habidat \
    VW_ORG_CLIENT_ID=organization.0b9e3c6e-58a4-4d0e-9a6b-2f0a3b1c4d5e VW_ORG_CLIENT_SECRET=s \
    VW_BOT_CLIENT_ID=user.0b9e3c6e-58a4-4d0e-9a6b-2f0a3b1c4d5e VW_BOT_CLIENT_SECRET=s VW_BOT_MASTER_PASSWORD="it's" \
    bash -c "cd '$REPO_ROOT/vaultwarden' && ./configure.sh"
  assert_failure
  assert_output --partial 'VW_BOT_MASTER_PASSWORD must not contain a single quote'
}

@test "vaultwarden sync: unit tests pass" {
  [[ -f "$REPO_ROOT/vaultwarden/sync/package.json" ]] || skip "vaultwarden/sync not present"
  command -v node >/dev/null || skip "node not installed"
  [[ -d "$REPO_ROOT/vaultwarden/sync/node_modules" ]] || skip "run npm ci in vaultwarden/sync first"
  run bash -c "cd '$REPO_ROOT/vaultwarden/sync' && node --test"
  assert_success
}
