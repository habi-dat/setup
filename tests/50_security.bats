#!/usr/bin/env bats
# `habidat.sh security-check`: the analyser (lib/security/analyse.py) on a
# synthetic report tree, and the CLI wiring in a sandbox.
#
# No real scans and no network: the raw data, SBOMs, Grype results and the
# endoflife.date / Docker Hub responses all come from
# helpers/security_fixture.py, and the analyser runs with --offline. See that
# file for what the fixture installation contains.

load helpers/load

setup_file() {
  sandbox_setup_file
}

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  python3 "$BATS_TEST_DIRNAME/helpers/security_fixture.py" "$FX"
  ANALYSER="$REPO_ROOT/lib/security/analyse.py"
}

# inventory [args...]
inventory() {
  run python3 "$ANALYSER" inventory --raw "$FX/report/raw" --prefix hab "$@"
}

# analyse [args...]
#   Builds the inventory, then runs the analyser. Settings come from the
#   environment like in production; set SEC_ENV=(VAR=value ...) to add some.
analyse() {
  python3 "$ANALYSER" inventory --raw "$FX/report/raw" --prefix hab ${INV_ARGS:-} > /dev/null
  run env -i PATH="$PATH" HABIDAT_DOMAIN="${DOMAIN:-example.org}" "${SEC_ENV[@]+"${SEC_ENV[@]}"}" \
    python3 "$ANALYSER" analyse --report "$FX/report" --cache "$FX/cache" --accepted "$FX/accepted" \
    --data "$REPO_ROOT/lib/security/data" --base "$FX/base" --offline --today 2026-11-07 "$@"
}

# finding_ids: every finding id in report.json, one per line
finding_ids() {
  python3 -c 'import json,sys; [print(f["id"]) for f in json.load(open(sys.argv[1]))["findings"]]' \
    "$FX/report/report.json"
}

# finding <id> <field>: one field of one finding from report.json
finding() {
  python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["findings"]:
    if f["id"] == sys.argv[2]:
        print(json.dumps(f.get(sys.argv[3])) if not isinstance(f.get(sys.argv[3]), str) else f[sys.argv[3]])
' "$FX/report/report.json" "$1" "$2"
}

assert_finding() {
  run finding_ids
  assert_line "$1"
}

refute_finding() {
  run finding_ids
  refute_line "$1"
}

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

@test "inventory: compose projects, name prefixes, instances and foreign containers" {
  inventory
  assert_success
  assert_line $'container\thab-nginx\tnginx'
  assert_line $'container\thab-ldap\tauth'
  assert_line $'container\thab-mediawiki-wiki1\tmediawiki/wiki1'
  assert_line $'container\thab-discourse\tdiscourse'
  assert_line $'container\tportainer\tforeign/portainer'
  assert_line $'vhost\tuser.example.org\tauth'
  refute_output --partial "mongo"
}

@test "inventory: a module target keeps only that module's containers" {
  inventory --target auth
  assert_success
  assert_line $'container\thab-user\tauth'
  assert_line $'container\thab-ldap\tauth'
  refute_output --partial "portainer"
  refute_output --partial "hab-nextcloud"
}

@test "inventory: a module instance target keeps only that instance" {
  inventory --target mediawiki --instance wiki1
  assert_success
  assert_line $'container\thab-mediawiki-wiki1\tmediawiki/wiki1'
  [[ "${#lines[@]}" -eq 3 ]]  # image, vhost, container
}

@test "inventory: --all-images adds images no running container uses" {
  inventory --all-images
  assert_success
  assert_output --partial $'\tmongo:4.4'
}

# ---------------------------------------------------------------------------
# Vulnerabilities and exit codes
# ---------------------------------------------------------------------------

@test "vulnerabilities: only urgent ones are listed, the rest is one count line" {
  analyse
  [[ "$status" -eq 1 ]]
  assert_output --partial "vuln:CVE-2026-0004"
  assert_output --partial "known to be exploited (CISA KEV)"
  assert_output --partial "vuln:CVE-2026-0005"
  assert_output --partial "exploitation likely (EPSS 40%)"
  assert_output --partial "vuln:CVE-2026-0008"
  refute_output --partial "GHSA-next-0001"
  refute_output --partial "CVE-2026-0002"
  refute_output --partial "CVE-2011-3389"
  refute_output --partial "GHSA-tar-0006"
  assert_output --partial "+ 4 further known vulnerabilities at HIGH or above (2 critical, 1 without a fix), none known or likely to be exploited"
  assert_finding "vuln:CVE-2026-0002@auth"
  assert_finding "vuln:CVE-2026-0003@auth"
}

@test "vulnerabilities: KEV, EPSS and tooling decide urgency, not severity" {
  analyse
  [[ "$(finding 'vuln:CVE-2026-0004@auth' urgent)" == "true" ]]
  [[ "$(finding 'vuln:CVE-2026-0005@auth' urgent)" == "true" ]]
  [[ "$(finding 'vuln:CVE-2026-0008@auth' urgent)" == "true" ]]
  [[ "$(finding 'vuln:CVE-2026-0002@auth' urgent)" == "false" ]]
  [[ "$(finding 'vuln:CVE-2011-3389@auth' urgent)" == "false" ]]
  [[ "$(finding 'vuln:GHSA-tar-0006@auth' urgent)" == "false" ]]
  [[ "$(finding 'vuln:GHSA-tar-0006@auth' tooling)" == "true" ]]
  [[ "$(finding 'vuln:GHSA-tar-0006@auth' kev)" == "true" ]]
  [[ "$(finding 'vuln:CVE-2026-0004@auth' epss)" == "0.88" ]]  # highest of both images
}

@test "vulnerabilities: OS packages are fixed by pulling, language packages by a newer release" {
  analyse
  [[ "$(finding 'vuln:CVE-2026-0004@auth' fix)" == "./habidat.sh fix auth" ]]
  [[ "$(finding 'vuln:GHSA-next-0001@auth' fix)" == "fixed upstream in 15.0.9; arrives with a newer auth release (./habidat.sh update auth)" ]]
  [[ -z "$(finding 'vuln:CVE-2026-0008@auth' fix)" ]]
  assert_output --partial "no fix released"
}

@test "vulnerabilities: each finding names the image and container it comes from" {
  analyse
  [[ "$(finding 'vuln:CVE-2026-0005@auth' images)" == '["habidat/auth:2.2 (container hab-user)"]' ]]
  [[ "$(finding 'vuln:CVE-2026-0009@auth' images)" == '["osixia/openldap:1.3.0 (container hab-ldap)"]' ]]
  assert_output --partial "           in: osixia/openldap:1.3.0 (container hab-ldap)"
}

@test "vulnerabilities: two images of one module sharing a vulnerability give one finding naming both" {
  analyse
  [[ "$(finding 'vuln:CVE-2026-0004@auth' images)" == '["habidat/auth:2.2 (container hab-user)", "osixia/openldap:1.3.0 (container hab-ldap)"]' ]]
  [[ "$(finding 'vuln:CVE-2026-0004@auth' packages)" == '["openssl 3.3.2-r0", "libssl1.1 1.1.1d-0+deb10u2"]' ]]
  [[ "$(finding 'vuln:CVE-2026-0004@auth' severity)" == "CRITICAL" ]]
  assert_output --partial "in: habidat/auth:2.2 (container hab-user); osixia/openldap:1.3.0 (container hab-ldap)"
}

@test "vulnerabilities: one finding per vulnerability lists every affected package" {
  analyse
  [[ "$(finding 'vuln:CVE-2026-0003@auth' packages)" == '["zlib 1.3.1-r0", "zlib-dev 1.3.1-r0"]' ]]
}

@test "vulnerabilities: --verbose lists every other vulnerability grouped by package" {
  analyse --verbose
  assert_output --partial "vuln:CVE-2026-0004"
  assert_output --partial "other vulnerabilities by package:"
  assert_output --partial "CRITICAL tar 6.2.1 (npm): 2 advisories, fixed in 7.5.21 (tooling) in habidat/auth:2.2 (container hab-user)"
  assert_output --partial "CRITICAL busybox 1.36.1-r0 (apk): 1 advisory, 1 without a fix"
  assert_output --partial "LOW      gnutls 3.8.5-r0 (apk): 1 advisory, 1 without a fix"
  refute_output --partial "+ 4 further"
  assert_output --partial "floating-tag:habidat/mediawiki"
}

@test "vulnerabilities: report.json groups advisories per package" {
  analyse
  run python3 -c '
import json, sys
for g in json.load(open(sys.argv[1]))["vulnerabilities"]:
    print(g["scope"], g["package"], g["severity"], len(g["advisories"]), ",".join(g["fixed_in"]), g["tooling"], g["urgent"])
' "$FX/report/report.json"
  assert_line "auth tar CRITICAL 2 7.5.21 True False"
  assert_line "auth openssl HIGH 1 3.3.3-r0 False True"
}

@test "vulnerabilities: the EPSS threshold is configurable" {
  SEC_ENV=(HABIDAT_SECURITY_EPSS_THRESHOLD=0.5)
  analyse
  refute_output --partial "vuln:CVE-2026-0005"
  [[ "$(finding 'vuln:CVE-2026-0005@auth' urgent)" == "false" ]]
  [[ "$(finding 'vuln:CVE-2026-0004@auth' urgent)" == "true" ]]
}

@test "vulnerabilities: an invalid EPSS threshold makes the check fail" {
  SEC_ENV=(HABIDAT_SECURITY_EPSS_THRESHOLD=high)
  analyse
  [[ "$status" -eq 2 ]]
  assert_output --partial "failed: config.epss (HABIDAT_SECURITY_EPSS_THRESHOLD=high is not a number between 0 and 1)"
}

@test "exit code: vulnerabilities that are not urgent never fail the check" {
  # Accept everything except the vulnerabilities that are not urgent.
  analyse
  python3 -c '
import json, sys
ids = [f["id"] for f in json.load(open(sys.argv[1]))["findings"] if f["type"] != "vuln" or f.get("urgent")]
open(sys.argv[2], "w").write("".join(i + " 2027-01-31 test\n" for i in ids))
' "$FX/report/report.json" "$FX/accepted"
  analyse
  assert_success
  assert_output --partial "+ 4 known vulnerabilities at HIGH or above"
  assert_output --partial "-> exit 0"
}

@test "exit code: an urgent vulnerability fails the check whatever its severity" {
  # Accept everything except the urgent MEDIUM.
  analyse
  python3 -c '
import json, sys
ids = [f["id"] for f in json.load(open(sys.argv[1]))["findings"] if f["id"] != "vuln:CVE-2026-0005@auth"]
open(sys.argv[2], "w").write("".join(i + " 2027-01-31 test\n" for i in ids))
' "$FX/report/report.json" "$FX/accepted"
  analyse --severity CRITICAL
  [[ "$status" -eq 1 ]]
  assert_output --partial "1 finding(s) to act on"
}

@test "exit code: --severity CRITICAL ignores HIGH findings" {
  echo "vuln:*@auth 2027-01-31 test" > "$FX/accepted"
  analyse --severity CRITICAL
  assert_success
}

@test "exit code: a check that could not run wins over findings" {
  printf 'images.sbom:x\tfailed\tSyft failed\n' >> "$FX/report/raw/checks.tsv"
  analyse
  [[ "$status" -eq 2 ]]
  assert_output --partial "failed: images.sbom:x (Syft failed)"
}

@test "exit code: missing end-of-life data without network is a failed check" {
  rm "$FX/cache/eol/php.json"
  analyse
  [[ "$status" -eq 2 ]]
  assert_output --partial "failed: eol.fetch"
  assert_output --partial "php"
}

# ---------------------------------------------------------------------------
# End of life, abandoned images, outdated modules
# ---------------------------------------------------------------------------

@test "end of life: reached is HIGH, within 90 days is MEDIUM, far away is nothing" {
  analyse
  [[ "$(finding 'eol:alpine-linux-3.20@auth' severity)" == "HIGH" ]]
  [[ "$(finding 'eol:nextjs-15@auth' severity)" == "MEDIUM" ]]
  [[ "$(finding 'eol:php-8.2@nextcloud' severity)" == "MEDIUM" ]]
  [[ "$(finding 'eol:nextcloud-32@nextcloud' severity)" == "HIGH" ]]
  [[ "$(finding 'eol:docker-engine-26.1@host' severity)" == "HIGH" ]]
  refute_finding "eol:nodejs-24@auth"
  [[ "$(finding 'eol:php-8.2@nextcloud' images)" == '["habidat/nextcloud:32.0.5 (container hab-nextcloud)"]' ]]
}

@test "images: moved, abandoned, stale tag and floating tag" {
  analyse
  assert_finding "moved:jwilder/nginx-proxy@nginx"
  refute_finding "abandoned:jwilder/nginx-proxy@nginx"
  assert_finding "abandoned:habidat/mediawiki@mediawiki/wiki1"
  assert_finding "stale-tag:osixia/openldap:1.3.0@auth"
  [[ "$(finding 'floating-tag:portainer/portainer-ce@foreign/portainer' severity)" == "LOW" ]]
  refute_finding "abandoned:habidat/auth@auth"
  # Built locally: nothing on Docker Hub to compare with.
  run finding_ids
  refute_output --partial "local_discourse"
}

@test "images: a description saying 'no longer maintained' marks an image abandoned" {
  printf '{"last_updated": "2026-10-01T00:00:00Z", "description": "NO LONGER MAINTAINED!!"}' \
    > "$FX/cache/hub/portainer_portainer-ce.json"
  analyse
  assert_finding "abandoned:portainer/portainer-ce@foreign/portainer"
}

@test "modules: an installed version older than the repo's is an outdated module" {
  analyse
  [[ "$(finding 'outdated-module:auth@auth' severity)" == "MEDIUM" ]]
  refute_finding "outdated-module:nextcloud@nextcloud"
}

# ---------------------------------------------------------------------------
# Host, Docker, exposure, TLS, configuration, hooks
# ---------------------------------------------------------------------------

@test "host: security updates, reboot, restarts and automatic updates" {
  analyse
  assert_output --partial "1 security update(s) pending: openssl"
  refute_output --partial "tzdata"
  assert_finding "host-reboot@host"
  assert_finding "host-restart@host"
  assert_finding "host-no-auto-updates@host"
}

@test "docker: daemon defaults are LOW; privileged and docker.sock are HIGH except expected mounts" {
  analyse
  [[ "$(finding 'docker:userns-remap@host' severity)" == "LOW" ]]
  [[ "$(finding 'docker:icc@host' severity)" == "LOW" ]]
  refute_finding "docker:log-rotation@host"
  [[ "$(finding 'privileged:portainer@foreign/portainer' severity)" == "HIGH" ]]
  assert_finding "docker-sock:portainer@foreign/portainer"
  refute_finding "docker-sock:hab-nginx@nginx"
}

@test "exposure: Docker-published ports bypass an active ufw; expected and loopback ports are fine" {
  analyse
  assert_finding "ufw-bypass:tcp/389@auth"
  assert_finding "exposed:tcp/5432@host"
  refute_finding "ufw-bypass:tcp/443@nginx"
  refute_finding "ufw-bypass:tcp/636@auth"
  refute_finding "exposed:tcp/3306@host"
  refute_finding "exposed:tcp/22@host"
  # The IPv6 docker-proxy socket of a published port is reported once, by container.
  refute_finding "exposed:tcp/389@host"
}

@test "exposure: without ufw a published port is plainly exposed; expected ports are configurable" {
  rm "$FX/report/raw/host/ufw.conf"
  SEC_ENV=(HABIDAT_SECURITY_EXPECTED_PORTS=22,80,443,389)
  analyse
  refute_finding "ufw-bypass:tcp/389@auth"
  refute_finding "exposed:tcp/389@auth"
  assert_finding "exposed:tcp/9000@foreign/portainer"
}

@test "tls: certificate expiring within 14 days and testssl findings" {
  analyse
  assert_finding "cert-expiry:user.example.org@host"
  refute_finding "cert-expiry:cloud.example.org@host"
  [[ "$(finding 'tls:TLS1@host' severity)" == "HIGH" ]]
  refute_finding "tls:TLS1_3@host"
  refute_finding "tls:scanProblem@host"
}

@test "config: setup.env readable by others, mailhog on a public domain" {
  chmod 644 "$FX/base/setup.env"
  SEC_ENV=(HABIDAT_MAILHOG=true HABIDAT_LETSENCRYPT=true)
  analyse
  assert_finding "config:setup-env-mode@host"
  assert_finding "config:mailhog@host"
  refute_finding "config:no-letsencrypt@host"
}

@test "config: development settings are fine on a .localhost domain" {
  DOMAIN=habidat.localhost
  SEC_ENV=(HABIDAT_MAILHOG=true HABIDAT_CREATE_SELFSIGNED=true HABIDAT_LETSENCRYPT=false)
  analyse
  run finding_ids
  refute_output --partial "config:"
}

@test "hooks: module findings get the module's scope" {
  analyse
  [[ "$(finding 'outdated-app:calendar@nextcloud' severity)" == "MEDIUM" ]]
}

@test "host target: host, Docker, exposure, TLS and config findings, nothing from images or modules" {
  analyse --host-only
  run finding_ids
  assert_line "host-updates@host"
  assert_line "eol:debian-12@host"
  assert_line "ufw-bypass:tcp/389@auth"
  assert_line "tls:TLS1@host"
  refute_output --partial "vuln:"
  refute_output --partial "eol:php"
  refute_output --partial "eol:node"
  refute_output --partial "abandoned:"
  refute_output --partial "floating-tag:"
  refute_output --partial "outdated-module:"
  refute_output --partial "outdated-app:"
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"])' "$FX/report/report.json")" == "host" ]]
}

@test "module target: no host, TLS or configuration findings" {
  INV_ARGS="--target auth"
  analyse --target auth --module-only
  run finding_ids
  refute_output --partial "@host"
  refute_output --partial "@nextcloud"
  assert_line "ufw-bypass:tcp/389@auth"
}

# ---------------------------------------------------------------------------
# Accepted findings
# ---------------------------------------------------------------------------

@test "accepted: a valid line hides the finding but keeps it in the report" {
  echo "ufw-bypass:tcp/389@auth  2027-03-01  LDAP is IP-restricted at the hoster firewall" > "$FX/accepted"
  analyse
  refute_output --partial "ufw-bypass:tcp/389"
  assert_output --partial "accepted"
  [[ "$(finding 'ufw-bypass:tcp/389@auth' accepted)" == *"IP-restricted"* ]]
}

@test "accepted: '*' as scope accepts a finding everywhere" {
  echo "ufw-bypass:tcp/*@*  2027-03-01  reviewed every published port" > "$FX/accepted"
  analyse
  refute_output --partial "ufw-bypass:"
}

@test "accepted: lines without reason, with a bad date or too far out are ignored" {
  cat > "$FX/accepted" <<'EOF'
# comment
ufw-bypass:tcp/389@auth  2027-03-01
ufw-bypass:tcp/389@auth  someday  reason
ufw-bypass:tcp/389@auth  2027-12-31  reason
EOF
  analyse
  assert_output --partial "accepted line 2: needs"
  assert_output --partial "accepted line 3: 'someday' is not a YYYY-MM-DD date"
  assert_output --partial "accepted line 4: expiry 2027-12-31 is more than 183 days away"
  assert_output --partial "ufw-bypass:tcp/389"
}

@test "accepted: an expired acceptance brings the finding back" {
  echo "ufw-bypass:tcp/389@auth  2026-10-01  was temporary" > "$FX/accepted"
  analyse
  assert_output --partial "acceptance expired: ufw-bypass:tcp/389@auth"
  assert_output --partial "ufw-bypass:tcp/389"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

@test "cli: help lists security-check" {
  new_sandbox dev
  habidat help
  assert_success
  assert_output --partial "security-check"
}

@test "cli: --dry-run lists what would run and runs no scanner" {
  new_sandbox dev
  seed_module nginx "$(cat "$REPO_ROOT/nginx/version")"
  habidat --dry-run security-check
  assert_success
  assert_output --partial "[dry-run] host checks"
  run grep -E '^docker run' "$DOCKER_LOG"
  assert_failure
  [[ ! -e "$SANDBOX/store/.security-check" ]]
}

@test "cli: --dry-run host lists only the host checks" {
  new_sandbox dev
  seed_module nginx "$(cat "$REPO_ROOT/nginx/version")"
  habidat --dry-run security-check host
  assert_success
  assert_output --partial "Security check of the host only (no images)"
  assert_output --partial "[dry-run] host checks"
  refute_output --partial "images to scan"
  run grep -E '^docker run' "$DOCKER_LOG"
  assert_failure
}

@test "cli: host takes no instance and no --all-images" {
  new_sandbox dev
  habidat security-check host x
  assert_failure
  assert_output --partial "security-check host takes no further arguments"
  habidat security-check host --all-images
  assert_failure
  assert_output --partial "--all-images does not apply to security-check host"
}

@test "cli: unknown and uninstalled modules are rejected" {
  new_sandbox dev
  habidat security-check frobnicate
  assert_failure
  assert_output --partial "Unknown module: frobnicate"
  habidat security-check nextcloud
  assert_failure
  assert_output --partial "Module nextcloud is not installed"
}

@test "cli: an invalid --severity is rejected" {
  new_sandbox dev
  habidat security-check --severity SEVERE
  assert_failure
  assert_output --partial "--severity needs LOW, MEDIUM, HIGH or CRITICAL"
}

@test "cli: the report directory is not mistaken for a module" {
  new_sandbox dev
  seed_module nginx "$(cat "$REPO_ROOT/nginx/version")"
  mkdir -p "$SANDBOX/store/.security-check/reports"
  habidat modules
  assert_success
  refute_output --partial "security-check"
  refute_output --partial "Store warning"
}

# ---------------------------------------------------------------------------
# Static
# ---------------------------------------------------------------------------

@test "static: every scanner image is pinned by version and digest" {
  local line failures=()
  while IFS= read -r line; do
    [[ "$line" =~ :[^@:]+@sha256:[0-9a-f]{64}\"$ ]] || failures+=("$line")
  done < <(grep -E '^SECURITY_[A-Z]+_IMAGE=' "$REPO_ROOT/lib/security/scanners.sh")
  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "unpinned scanner images:" "${failures[@]}"
  run grep -cE '^SECURITY_[A-Z]+_IMAGE=' "$REPO_ROOT/lib/security/scanners.sh"
  [[ "$output" -eq 3 ]]
}

@test "static: every module security-check hook is executable" {
  local hook failures=()
  for hook in "$REPO_ROOT"/*/security-check.sh; do
    [[ -e "$hook" ]] || continue
    [[ -x "$hook" ]] || failures+=("${hook#"$REPO_ROOT"/}")
  done
  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "hooks without the executable bit:" "${failures[@]}"
}
