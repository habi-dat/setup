#!/usr/bin/env bats
# Backup, export and restore (ADR 0005-0008): the library pieces in isolation,
# and the CLI in a sandbox with the recording docker stub. Nothing here talks to
# a Docker daemon or a borg repository.

load helpers/load

# backup_eval <code> [base_dir]
#   Like lib_eval, with the export and backup libraries loaded as well.
backup_eval() {
  local code="$1" base_dir="${2:-$BATS_TEST_TMPDIR/base}"
  mkdir -p "$base_dir"
  run env -i PATH="$PATH" HOME="${HOME:-/tmp}" TERM=dumb BASE_DIR="$base_dir" bash -c "
    source '$REPO_ROOT/lib/common.sh'
    source '$REPO_ROOT/lib/template.sh'
    source '$REPO_ROOT/lib/version.sh'
    source '$REPO_ROOT/lib/modules.sh'
    source '$REPO_ROOT/lib/export.sh'
    source '$REPO_ROOT/lib/backup.sh'
    $code
  "
}

# make_export_file <file> <prefix> [with-manifest]
#   A dokuwiki export file in the snapshot layout, as export_unit_to_file
#   writes it.
make_export_file() {
  local file="$1" prefix="$2" manifest="${3:-yes}"
  local src="$BATS_TEST_TMPDIR/export-src"
  rm -rf "$src"
  mkdir -p "$src/dumps/dokuwiki" "$src/store/dokuwiki" "$src/volumes/$prefix-dokuwiki_data/pages"
  echo "0.0.1" > "$src/store/dokuwiki/version"
  echo "services: {}" > "$src/store/dokuwiki/docker-compose.yml"
  echo "from the export" > "$src/store/dokuwiki/marker"
  echo "page" > "$src/volumes/$prefix-dokuwiki_data/pages/start.txt"
  if [[ "$manifest" == yes ]]; then
    cat > "$src/manifest.json" <<EOF
{"format": 1, "kind": "export", "docker_prefix": "$prefix", "domain": "habidat.localhost",
 "units": [{"module": "dokuwiki", "instance": null, "version": "0.0.1", "status": "ok",
            "volumes": ["$prefix-dokuwiki_data", "$prefix-dokuwiki_config", "$prefix-dokuwiki_plugins", "$prefix-dokuwiki_templates"]}]}
EOF
    tar -czf "$file" -C "$src" manifest.json dumps store volumes
  else
    tar -czf "$file" -C "$src" store
  fi
}

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

@test "manifest: units round-trip, and an empty instance stays its own field" {
  local root="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$root"
  printf 'auth\t\t2.2.0\tok\tp-auth_user-uploads\n' > "$root/units.tsv"
  printf 'listmonk\tnews\t6.2.0\tfailed\t\n' >> "$root/units.tsv"

  backup_eval "HABIDAT_DOCKER_PREFIX=p HABIDAT_DOMAIN=example.org write_manifest '$root' snapshot && manifest_units '$root/manifest.json'"
  assert_success
  assert_line --index 0 "auth||2.2.0|ok|p-auth_user-uploads"
  assert_line --index 1 "listmonk|news|6.2.0|failed|"

  backup_eval "manifest_units '$root/manifest.json' listmonk news"
  assert_output "listmonk|news|6.2.0|failed|"

  backup_eval "manifest_get '$root/manifest.json' docker_prefix"
  assert_output "p"
}

@test "backup_repo_parts: splits an ssh URL and defaults the port to 22" {
  backup_eval "backup_repo_parts ssh://u1-sub2@u1.your-storagebox.de:23/./habidat"
  assert_output "u1-sub2 u1.your-storagebox.de 23 /./habidat"

  backup_eval "backup_repo_parts ssh://borg@backup.example.org/srv/borg/habidat"
  assert_output "borg backup.example.org 22 /srv/borg/habidat"

  backup_eval "backup_repo_parts /local/path"
  assert_failure
}

@test "module_units: one empty unit for a plain module, one per instance otherwise" {
  local base="$BATS_TEST_TMPDIR/base"
  mkdir -p "$base/listmonk" "$base/store/listmonk/a" "$base/store/listmonk/b" "$base/store/listmonk/broken"
  : > "$base/listmonk/multi-instance"
  : > "$base/store/listmonk/a/docker-compose.yml"
  : > "$base/store/listmonk/b/docker-compose.yml"

  backup_eval "module_units nextcloud | wc -l"
  assert_output "1"

  backup_eval "module_units listmonk"
  assert_output $'a\nb'

  backup_eval "module_units listmonk b"
  assert_output "b"

  backup_eval "module_units listmonk zzz"
  assert_failure
}

@test "join_words: joins with spaces despite common.sh's newline IFS" {
  backup_eval 'arr=(a b c); join_words "${arr[@]}"'
  assert_output "a b c"
}

@test "is_manual_install: only backup is left out of 'install all'" {
  local mod found=()
  while IFS= read -r mod; do
    [[ -f "$REPO_ROOT/$mod/manual-install" ]] && found+=("$mod")
  done < <(repo_modules)
  assert_equal "${found[*]}" "backup"
}

# ---------------------------------------------------------------------------
# Link step SQL (ADR 0007)
# ---------------------------------------------------------------------------

auth_app_sql_for() {
  run bash -c "source '$REPO_ROOT/lib/auth-app.sh'; auth_app_sql '$1'"
}

@test "auth app link: an existing app only gets its OIDC client settings" {
  local file="$BATS_TEST_TMPDIR/app.json"
  cat > "$file" <<'EOF'
[{"id": "news.lists", "label": "News", "url": "https://news.lists.example.org",
  "oidc": {"enabled": true, "clientId": "news.lists", "clientSecret": "it's-secret",
           "redirectUris": ["https://news.lists.example.org/auth/oidc"]},
  "groups": ["Newsletter"]}]
EOF
  auth_app_sql_for "$file"
  assert_success

  local update
  update="$(sed -n '/UPDATE "App" SET/,/RETURNING/p' <<< "$output")"
  [[ "$update" == *'"oidcClientSecret" = '"'it''s-secret'"* ]] || fail "secret not escaped/updated: $update"
  [[ "$update" == *'"oidcRedirectUris" = '* ]] || fail "redirect URIs not updated"
  [[ "$update" != *' name '* && "$update" != *'name ='* ]] || fail "UPDATE touches the name: $update"
  [[ "$update" != *'url ='* ]] || fail "UPDATE touches the URL: $update"

  # Groups are only granted to an app this statement inserted.
  assert_output --partial 'FROM inserted i'
  refute_output --partial 'FROM updated u'
  assert_output --partial "ARRAY['newsletter']::text[]"
}

@test "auth app link: a SAML app sets the SAML endpoints, not OIDC" {
  local file="$BATS_TEST_TMPDIR/app.json"
  cat > "$file" <<'EOF'
[{"id": "wiki.mediawiki", "label": "Wiki", "url": "https://wiki.example.org",
  "saml": {"samlEnabled": true, "entityId": "https://wiki.example.org",
           "acs": "https://wiki.example.org/acs", "slo": "https://wiki.example.org/slo"},
  "groups": []}]
EOF
  auth_app_sql_for "$file"
  assert_success
  assert_output --partial '"samlAcsUrl" = '"'https://wiki.example.org/acs'"
  refute_output --partial 'oidc'
  assert_output --partial 'ARRAY[]::text[]'
}

@test "every link step that writes an auth app goes through auth_app_link" {
  local f failures=()
  for f in "$REPO_ROOT"/*/link.sh; do
    grep -q 'user-import' "$f" || continue
    grep -q 'auth_app_link' "$f" || failures+=("${f#"$REPO_ROOT"/}")
  done
  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "link steps writing auth apps without auth_app_link:" "${failures[@]}"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

setup_file() {
  sandbox_setup_file
}

setup() {
  new_sandbox dev
}

@test "snapshots: works without setup.env and says the backup module is missing" {
  rm "$SANDBOX/setup.env"
  habidat snapshots
  assert_failure
  refute_output --partial "setup.env not found"
  assert_output --partial "backup module is not installed"
}

@test "snapshots: an installed but unconfigured backup asks for configure" {
  mkdir -p "$SANDBOX/store/backup"
  echo "HABIDAT_BACKUP_REPOSITORY=ssh://u@h/./r" > "$SANDBOX/store/backup/backup.env"
  echo "1.0.0" > "$SANDBOX/store/backup/version"
  habidat snapshots
  assert_failure
  assert_output --partial "./habidat.sh configure backup"
}

@test "backup run: needs setup.env" {
  rm "$SANDBOX/setup.env"
  habidat backup
  assert_failure
  assert_output --partial "setup.env not found"
}

@test "backup: rejects an unknown subcommand" {
  habidat backup frobnicate
  assert_failure
  assert_output --partial "Usage: habidat.sh backup"
}

@test "install backup: rejects a repository that is not an ssh URL, and writes nothing" {
  habidat install backup /mnt/backup provider-snapshots
  assert_failure
  assert_output --partial "must look like ssh://"
  assert [ ! -e "$SANDBOX/store/backup/backup.env" ]
}

@test "install backup: rejects an unknown protection mode" {
  habidat install backup ssh://u@h:23/./r snapshots-please
  assert_failure
  assert_output --partial "Unknown protection 'snapshots-please'"
  assert [ ! -e "$SANDBOX/store/backup/backup.env" ]
}

@test "restore: usage errors" {
  habidat restore
  assert_failure
  assert_output --partial "Usage: habidat.sh restore"

  habidat restore all --file /tmp/x.tar.gz
  assert_failure
  assert_output --partial "only be restored from a snapshot"

  habidat restore backup latest
  assert_failure
  assert_output --partial "never restored"

  habidat restore nextcloud someinstance latest
  assert_failure
  assert_output --partial "has no instances"
}

@test "restore --file: refuses a file from the old export format" {
  make_export_file "$BATS_TEST_TMPDIR/old.tar.gz" habidattest no
  habidat restore dokuwiki --file "$BATS_TEST_TMPDIR/old.tar.gz" --yes
  assert_failure
  assert_output --partial "export format before snapshots"
  assert_output --partial "./habidat.sh import dokuwiki old.tar.gz"
}

@test "import: a file in the old format goes through the previous release's import script" {
  seed_module vaultwarden "$(repo_module_version vaultwarden)"
  local dir=/tmp/habidat-test-backup/habidattest/vaultwarden
  mkdir -p "$dir"
  make_export_file "$dir/bats-old-$$.tar.gz" habidattest no

  habidat import vaultwarden "bats-old-$$.tar.gz"
  rm -f "$dir/bats-old-$$.tar.gz"
  assert_success
  assert_output --partial "vaultwarden/legacy-import/1.37.4.sh"
  assert_output --partial "Import of vaultwarden complete."
  assert_docker_called "-p habidattest-vaultwarden stop sync vaultwarden"
  assert_docker_called "tar xzf '/backup/bats-old-$$.tar.gz' -C /data"
}

@test "import: an old-format file for a module without a legacy importer is refused" {
  seed_module dokuwiki "$(repo_module_version dokuwiki)"
  local dir=/tmp/habidat-test-backup/habidattest/dokuwiki
  mkdir -p "$dir"
  make_export_file "$dir/bats-old-$$.tar.gz" habidattest no

  habidat import dokuwiki "bats-old-$$.tar.gz"
  rm -f "$dir/bats-old-$$.tar.gz"
  assert_failure
  assert_output --partial "no import script for it"
}

@test "restore --file: refuses a file taken with another Docker prefix" {
  for mod in nginx auth nextcloud; do seed_module "$mod" "$(repo_module_version "$mod")"; done
  make_export_file "$BATS_TEST_TMPDIR/other.tar.gz" otherprefix
  habidat restore dokuwiki --file "$BATS_TEST_TMPDIR/other.tar.gz" --yes
  assert_failure
  assert_output --partial "Docker prefix 'otherprefix'"
}

@test "restore --file: without a terminal it needs --yes" {
  for mod in nginx auth nextcloud; do seed_module "$mod" "$(repo_module_version "$mod")"; done
  make_export_file "$BATS_TEST_TMPDIR/doku.tar.gz" habidattest
  habidat restore dokuwiki --file "$BATS_TEST_TMPDIR/doku.tar.gz" < /dev/null
  assert_failure
  assert_output --partial "Pass --yes"
  refute_docker_called "-p habidattest-dokuwiki"
}

@test "restore --file: refuses a module whose dependencies are not installed" {
  make_export_file "$BATS_TEST_TMPDIR/doku.tar.gz" habidattest
  habidat restore dokuwiki --file "$BATS_TEST_TMPDIR/doku.tar.gz" --yes
  assert_failure
  assert_output --partial "dokuwiki needs nginx"
}

@test "restore --file: replaces the store folder, refills volumes, links and updates" {
  for mod in nginx auth nextcloud; do seed_module "$mod" "$(repo_module_version "$mod")"; done
  seed_module dokuwiki "$(repo_module_version dokuwiki)"
  echo "local only" > "$SANDBOX/store/dokuwiki/local-marker"
  make_export_file "$BATS_TEST_TMPDIR/doku.tar.gz" habidattest

  habidat restore dokuwiki --file "$BATS_TEST_TMPDIR/doku.tar.gz" --yes
  assert_success

  # store/dokuwiki is the one from the file, nothing of the old one survives.
  assert [ -f "$SANDBOX/store/dokuwiki/marker" ]
  assert [ ! -e "$SANDBOX/store/dokuwiki/local-marker" ]
  assert [ -z "$(ls -A "$SANDBOX/store/.restore" 2>/dev/null)" ]

  # Containers are removed but never taken down with their volumes.
  assert_docker_called "-p habidattest-dokuwiki rm --stop --force"
  assert_no_destructive_docker
  local volume
  for volume in data config plugins templates; do
    assert_docker_called "-v habidattest-dokuwiki_$volume:/v"
  done
  assert_docker_called "-p habidattest-dokuwiki up -d"

  # Link step: dokuwiki tells nextcloud its subdomain, once.
  run grep -c '^HABIDAT_DOKUWIKI_SUBDOMAIN=' "$SANDBOX/store/nextcloud/nextcloud.env"
  assert_output "1"
  habidat restore dokuwiki --file "$BATS_TEST_TMPDIR/doku.tar.gz" --yes
  assert_success
  run grep -c '^HABIDAT_DOKUWIKI_SUBDOMAIN=' "$SANDBOX/store/nextcloud/nextcloud.env"
  assert_output "1"
}

@test "import: is an alias for restore --file on a file in the export directory" {
  for mod in nginx auth nextcloud; do seed_module "$mod" "$(repo_module_version "$mod")"; done
  local dir=/tmp/habidat-test-backup/habidattest/dokuwiki
  mkdir -p "$dir"
  make_export_file "$dir/bats-$$.tar.gz" habidattest

  habidat import dokuwiki "bats-$$.tar.gz" --yes
  rm -f "$dir/bats-$$.tar.gz"
  assert_success
  assert_output --partial "deprecated"
  assert_output --partial "Restore of dokuwiki"
}

@test "export: auth dumps LDAP and the database through compose exec, uncompressed" {
  seed_module auth "$(repo_module_version auth)"
  habidat export auth
  assert_success
  assert_docker_called "-p habidattest-auth exec -T ldap slapcat"
  assert_docker_called "-p habidattest-auth exec -T user-db pg_dump -U postgres --clean --if-exists --create habidat_auth"
  assert_docker_called "-v habidattest-auth_user-uploads:/x/volumes/habidattest-auth_user-uploads:ro"
  assert_output --partial "Export of auth written to"
}

@test "export: listmonk dumps each instance as the listmonk role" {
  seed_module listmonk "$(repo_module_version listmonk)"
  mkdir -p "$SANDBOX/store/listmonk/news"
  : > "$SANDBOX/store/listmonk/news/docker-compose.yml"
  habidat export listmonk
  assert_success
  assert_docker_called "-p habidattest-listmonk-news exec -T db pg_dump -U listmonk"
  assert_output --partial "listmonk-news-"
}

@test "export: every instance is exported, although compose exec reads stdin" {
  seed_module listmonk "$(repo_module_version listmonk)"
  for id in one two three; do
    mkdir -p "$SANDBOX/store/listmonk/$id"
    : > "$SANDBOX/store/listmonk/$id/docker-compose.yml"
  done
  export HABIDAT_TEST_DOCKER_EXEC_READS_STDIN=1
  habidat export listmonk
  assert_success
  for id in one two three; do
    assert_docker_called "-p habidattest-listmonk-$id exec -T db pg_dump"
  done
}

@test "export: the old nextcloud 'nodata' option is rejected" {
  seed_module nextcloud "$(repo_module_version nextcloud)"
  habidat export nextcloud nodata
  assert_failure
  assert_output --partial "'nodata' is no longer supported"
}

@test "link: auth writes its backend network into networks.env exactly once" {
  seed_networks_env
  seed_module auth "$(repo_module_version auth)"
  habidat link auth
  assert_success
  habidat link auth
  run grep -c 'HABIDAT_BACKEND_NETWORK=' "$SANDBOX/store/nginx/networks.env"
  assert_output "1"
}

@test "link: nextcloud rewrites its auth.env lines and restarts only the app containers" {
  seed_module auth "$(repo_module_version auth)"
  seed_module nextcloud "$(repo_module_version nextcloud)"
  printf 'export HABIDAT_NEXTCLOUD_DB_PASSWORD=dbpw\nexport HABIDAT_DISCOURSE_SSO_SECRET=sso\n' > "$SANDBOX/store/nextcloud/passwords.env"
  echo "export HABIDAT_ADMIN_PASSWORD=admin" > "$SANDBOX/store/auth/passwords.env"
  printf 'POSTGRES_PASSWORD=keep\nNEXTCLOUD_DB_PASSWORD=stale\n' > "$SANDBOX/store/auth/auth.env"

  habidat link nextcloud
  assert_success
  habidat link nextcloud
  assert_success

  run cat "$SANDBOX/store/auth/auth.env"
  assert_line "POSTGRES_PASSWORD=keep"
  assert_line "NEXTCLOUD_DB_PASSWORD=dbpw"
  refute_line "NEXTCLOUD_DB_PASSWORD=stale"
  run grep -c '^NEXTCLOUD_API_URL=' "$SANDBOX/store/auth/auth.env"
  assert_output "1"
  assert_docker_called "-p habidattest-auth up -d user user-worker"
}

@test "link: a module without a link step says so" {
  seed_module nginx "$(repo_module_version nginx)"
  habidat link nginx
  assert_success
  assert_output --partial "writes nothing into other modules"
}
