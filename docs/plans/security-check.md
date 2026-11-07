# Plan: `habidat.sh security-check`

Status: **implemented** (2026-11-07), including the revision "urgent vulnerabilities". Vocabulary follows the *Security* section of [GLOSSARY.md](../../GLOSSARY.md); the scanner choice is recorded in [ADR 0009](../adr/0009-grype-syft-not-trivy.md). User documentation is in the README ("Security check").

## Changes made during implementation

The rest of this document is the reviewed plan; where the implementation differs, this list wins.

- **Shell collects, Python decides.** `lib/security.sh` only gathers raw data into `reports/<ts>/raw/` (docker inspect, Syft/Grype output, host tool output, TLS probes, hook output). All rules — inventory mapping, severities, end of life, Docker Hub lookups, accepted findings, summary, exit code — live in `lib/security/analyse.py` (standard library only; Python is already a prerequisite for `lib/render.py`). This makes every rule testable on recorded data. There are no `lib/security/{inventory,images,eol,…}.sh` files.
- **One finding per vulnerability, not per package.** ID `vuln:<CVE/GHSA>@<scope>`; the title and `packages` in report.json list every affected package (a CVE in openssl hits `openssl` and `libssl3` alike; one php CVE hit six `php8.1-*` packages in the smoke run).
- **Pending security updates come from `apt-get -s dist-upgrade`** (packages from a `*-security` origin), not from `debsecan` / `pro security-status`: no extra tool, identical on Debian, Ubuntu and derivatives. They are reported as **one** `host-updates@host` finding listing the packages (same for `host-restart` and `host-unsupported`). Package lists older than 7 days add `host-apt-stale` (MEDIUM).
- **Debian/Ubuntu derivatives** (`ID_LIKE`, e.g. Pop!_OS) get the host checks; host-OS end of life is only looked up for `ID=debian|ubuntu`.
- **New finding type `stale-tag`** (MEDIUM): the repository is maintained but the pinned tag has not been rebuilt for `HABIDAT_SECURITY_ABANDONED_MONTHS`. Without it `osixia/openldap:1.3.0` would not be reported (its repository is active again because of the v2 release candidates).
- **End-of-life versions also come from image environment variables** (`PHP_VERSION`, `NODE_VERSION`, `NEXTCLOUD_VERSION`, …), which official images set and which are more reliable than package names.
- **TLS**: an untrusted certificate (self-signed included) is `cert-untrusted`; testssl.sh runs with `-p -s -S -h -U` (protocols, cipher categories, certificate, headers, vulnerabilities) instead of a full run, which took 9½ minutes against a CDN host.
- **No mediawiki hook**: extensions ship in the `habidat/mediawiki` image, not in a volume, so the image scan already covers them. Only nextcloud has a hook in v1.
- **SBOMs are cached** per image ID and Syft version in `cache/sbom/`; only Grype re-runs when an image is unchanged.
- In a module-targeted run, container-level Docker checks (privileged, `docker.sock`) and that module's published ports are still reported; host, TLS and configuration checks are not.

## Revision: urgent vulnerabilities (implemented, 2026-11-07)

First real runs listed 100+ HIGH/CRITICAL lines for a freshly rebuilt Discourse image. Nearly all of them were npm/gem packages pinned by Discourse's lockfile, or build tooling. A scan of an older Discourse image found 187 fixed HIGH/CRITICAL advisories. The only two that were really being exploited (Ruby and brotli/nodejs, both on KEV with an EPSS of 65 % and 83 %) were buried among them. The decision is recorded in [ADR 0010](../adr/0010-prioritise-by-exploitation-not-severity.md); the terms *Urgent vulnerability* and *Tooling package* are in the glossary. This section overrides "Image vulnerabilities", "Severity and display" and "Exit codes" below wherever they differ.

- **Urgent vulnerability.** A vulnerability is urgent if it is not in a tooling package and either:
  - Grype reports `knownExploited` for it, or
  - its highest `epss` value is ≥ `HABIDAT_SECURITY_EPSS_THRESHOLD` (default `0.1`) **and** its severity is at least MEDIUM. The severity floor keeps out ancient "negligible" CVEs with high EPSS, such as BEAST.

  Severity is still shown, but no longer decides on its own whether a finding is listed. KEV and EPSS come with Grype's database, so the check needs no extra network access and offline runs behave the same.
- **Finding fields.** Vulnerability findings get `urgent`, `kev`, `epss` and `tooling` in `report.json`. IDs stay `vuln:<CVE/GHSA>@<scope>`, so existing accepted findings keep matching.
- **Tooling packages** are recognised by the path where Syft found them (`artifact.locations[].path`). The patterns come from a new data file, `lib/security/data/tooling-paths`, which uses the same format as the other data files: one regular expression per line, `#` for comments. Initial patterns:
  - global installs of npm, pnpm, yarn and corepack (`/usr/lib/node_modules/{npm,pnpm,…}/`, `/usr/local/lib/node_modules/…`);
  - the pnpm store and pnpm's own tool dir (`/.local/share/pnpm/`);
  - executables shipped inside `node_modules/.pnpm/*/node_modules/*/bin/` (e.g. `lefthook`, a Go binary that brought in every Go stdlib CVE).

  A finding is tooling only if **all** affected locations match. Discourse's application `node_modules` is deliberately not tooling: what the running service loads from there cannot be told reliably.
- **Terminal summary.**
  - Only urgent vulnerabilities are listed one by one.
  - Every other vulnerability goes into one count line per scope, e.g. `+ 112 further known vulnerabilities (6 critical, 3 without a fix), none known or likely to be exploited (see report or --verbose)`. That line counts non-urgent vulnerabilities at or above `--severity`, fixed and unfixed alike.
  - The separate "unfixed" count line is gone.
  - `--verbose` lists everything, tagged `(tooling)` where it applies.
- **Fix hints by package type.**
  - OS packages (`deb`, `apk`, `rpm`) and runtime binaries keep today's hint (`build`/`fix`/`update`): rebuilding or pulling brings in patched packages.
  - Language packages (`npm`, `gem`, `go-module`, `python`, `php-composer`, `java-archive`, `rust-crate`) get `fixed upstream in <versions>; arrives with a newer <module> release (./habidat.sh update <module>)`. Rebuilding cannot help, because the application's lockfile pins those versions.
  - For volumes (the Nextcloud custom_apps scan) the hint stays as it is.
- **Grouped detailed view.** In `--verbose` and in a new `vulnerabilities` section of `report.json`, advisories are grouped per package and scope. Example: `tar 6.2.1, 7.5.2 (npm): 9 advisories, highest CRITICAL, all fixed in 7.5.21`. The flat findings list stays, so accepted findings keep matching per CVE.
- **Exit code.** A vulnerability makes the exit code 1 only if it is urgent and not accepted, fixed or not. Other finding types still count when they are at or above `--severity`. Exit code 2 is unchanged.
- **Configuration.** `HABIDAT_SECURITY_EPSS_THRESHOLD=0.1` is added to `setup.env.example` and the test profiles. Invalid values (not a number between 0 and 1) fail the check: exit 2, with a clear message.
- **Tests (tier 50).** The fixture gets matches covering:
  - a KEV match;
  - a high-EPSS MEDIUM match;
  - a high-EPSS NEGLIGIBLE match (not urgent);
  - a low-EPSS CRITICAL match (counted only);
  - a KEV match whose only location is under the pnpm store (tooling, not urgent);
  - an npm match (upstream fix hint).

  The tests also assert the exit code and the count line, and that the threshold and `--verbose` work.
- **Docs.** The README's "Security check" section is updated: what urgent means, the count line, exit codes and the new setting.

## Goal

One read-only command that tells an admin what on this server is vulnerable, at end of life, abandoned upstream or exposed, and what to run to fix it. Built for running by hand now, but safe to run unattended (no prompts, meaningful exit codes, report on disk) so scheduling and alerting can be added later together with the backup module's alert channel.

## Decisions

| # | Decision |
|---|---|
| Q1 | Run by hand in v1; unattended-safe; scheduling + alerts later (shared with backup alerts). |
| Q2 | Strictly read-only. Exit `0` = nothing at/above threshold, `1` = findings, `2` = a check could not run. Each finding carries a suggested fix (`./habidat.sh fix <module>`, `apt upgrade`, …). |
| Q3/Q8 | Default run scans every **running** container. Installation containers are grouped by module and get module extras; **foreign containers** are grouped as "foreign containers" and get the generic image checks. `--all-images` adds images no running container uses (incl. stopped containers) as "unused images". Exposure checks cover foreign containers too. |
| Q4 | Runs without sudo; root-only host checks print "skipped, re-run with sudo". |
| Q5 | Scanners run as containers pinned by version **and digest**; host-side tools only where unavoidable (distro tools, Lynis). |
| Q6 | v1 categories: host, Docker daemon, exposure, TLS, image vulnerabilities, end of life, abandoned images, outdated modules, habidat config, app-level (via hooks). Lynis behind `--host-audit`. No secret scanning, no backup health. |
| Q7/Q21 | Terminal summary grouped by host / module / foreign containers / unused images. Full results in `store/.security-check/` (dot-dir so `validate_store` ignores it). No HTML report. |
| Q9 | Optional `<module>/security-check.sh` hook declares code volumes and runs app-level checks. v1 hook: nextcloud (mediawiki dropped, see above). Modules without a hook still get every generic check. |
| Q10/Q23 | Fixed severity per non-CVE finding type (table below). Unfixed CVEs are only counted. `--severity` moves the bars. |
| Q11 | Accepted findings live per installation, need a reason and an expiry (≤ 6 months), nothing shipped by default. |
| Q12 | Exposure is decided by local inspection only; expected public ports configurable, default 22/80/443. |
| Q13 | bats tests run on recorded scanner JSON fixtures and stubbed `docker`/`ss`; no real scans in the suite. |
| Q15 | Grype + Syft only (ADR 0009). |
| Q16/Q24 | End of life from endoflife.date v1 API, versions from Syft SBOM and `/etc/os-release`, via a product map kept in the repo. |
| Q17 | Host checks for Debian and Ubuntu only; distro-native tools; missing tool = skipped with install hint. |
| Q18 | Docker daemon checks hand-written; docker-bench-security not used (unmaintained, CIS 1.6). |
| Q19 | testssl.sh once against the main domain; cheap certificate check on every module hostname; `--tls-full` for all. |
| Q20 | Abandoned-image rules below; replacing abandoned images is out of scope. |
| Q22 | Own branch in `habidat.sh`, not `dispatch()`; logic in `lib/security.sh` + `lib/security/*.sh`. |

## Command

```
./habidat.sh [--verbose] [--dry-run] security-check [all | <module> [<instance>]]
        [--all-images] [--host-audit] [--tls-full] [--severity LOW|MEDIUM|HIGH|CRITICAL]
```

| Target | Host | Installation modules | Foreign containers | TLS | Unused images |
|---|---|---|---|---|---|
| *(none)* / `all` | ✅ | ✅ all installed | ✅ | ✅ main domain + cert check | with `--all-images` |
| `<module> [<instance>]` | – | ✅ that one | – | – | – |

- `--dry-run`: list the checks, the containers/images that would be scanned and the scanner images that would be pulled; run nothing.
- `--verbose`: list every finding, including unfixed CVEs and those below the display bar.
- Run as root (sudo) for full host coverage; otherwise root-only checks are listed as skipped.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | No finding at or above the exit threshold (default HIGH), apart from accepted and unfixed-CVE findings. |
| 1 | At least one such finding. |
| 2 | At least one check could not run (no network for the Grype DB or endoflife.date, scanner pull failed, …). Takes precedence over 1 so a broken check is never mistaken for "only findings". |

## Files

```
habidat.sh                         new `security-check` case + usage line
lib/security.sh                    orchestration, argument parsing, grouping, summary, exit code
lib/security/inventory.sh          which containers/images, mapped to module / instance / foreign / unused
lib/security/scanners.sh           pinned scanner images + digests, run helpers, Grype DB volume
lib/security/images.sh             Syft SBOM + Grype per unique image (and per declared code volume)
lib/security/eol.sh                endoflife.date cache + product map lookup
lib/security/abandoned.sh          Docker Hub lookups, moved-image map, floating tags
lib/security/host.sh               OS detection, debsecan / pro, check-support-status, needrestart, unattended-upgrades, optional Lynis
lib/security/docker.sh             daemon config, privileged, docker.sock mounts, engine EOL
lib/security/exposure.sh           ss + docker port bindings vs. expected ports and ufw/nftables
lib/security/tls.sh                testssl.sh (pinned image) + openssl certificate check per hostname
lib/security/config.sh             setup.env mode, mailhog / self-signed / no Let's Encrypt on public domain, outdated modules
lib/security/findings.sh           finding record, severity table, accepted findings, merge to report.json
lib/security/data/eol-products     Syft package name → endoflife.date product
lib/security/data/moved-images     old image → new image
lib/security/data/expected-mounts  image patterns allowed to mount docker.sock (nginx-proxy, acme-companion)
nextcloud/security-check.sh        hook (v1)
(mediawiki hook dropped: extensions are in the image)
docs/adr/0009-grype-syft-not-trivy.md   ✅ written
GLOSSARY.md                        ✅ Security section written
README.md                          new "Security check" section
tests/50_security_*.bats + tests/fixtures/security/   fixture-driven tests
```

`setup.env.example` gets two optional settings:

```
HABIDAT_SECURITY_EXPECTED_PORTS=22,80,443   # public ports that are not a finding
HABIDAT_SECURITY_ABANDONED_MONTHS=12        # image not updated for longer = abandoned
```

### Store layout

```
store/.security-check/
  accepted                       accepted findings (admin-edited, survives updates)
  cache/eol/<product>.json       endoflife.date responses, refreshed when older than 24 h
  cache/hub/<repo>.json          Docker Hub repo metadata, refreshed when older than 24 h
  reports/<UTC timestamp>/
    report.json                  merged findings (schema below)
    summary.txt                  the terminal summary without colours
    sbom/<image-slug>.syft.json
    grype/<image-slug>.json
    testssl/<host>.json
    host/{debsecan,needrestart,support-status,lynis}.txt
  reports/latest -> <timestamp>
```

Grype's database lives in the named volume `<prefix>-security-check-grype-db` so it is not downloaded in full every run. Reports are never pruned automatically in v1 (each is a few MB; mention `rm -rf` in README).

## How the inventory is built

1. `docker ps` / `docker inspect` all running containers.
2. A container belongs to the installation when its compose project label is `<prefix>-<module>` (or `<prefix>-<module>-<instance>` for multi-instance modules), or — for modules not run by compose (discourse launcher, direktkredit) — its name starts with `<prefix>-<module>`. The module must be installed (`store/<module>` exists). Everything else is a **foreign container**.
3. With `--all-images`, every image ID not used by a running container is added as "unused".
4. Images are de-duplicated by image ID; each is scanned once and its findings are attached to every module/container that uses it.
5. Module hooks may add **code volumes** (see Hook contract); each is scanned as a directory with Syft/Grype.

## Checks

Every finding has a stable **ID** used in the report and the accepted-findings file:
`<type>:<subject>@<scope>`, where scope is `host`, `<module>`, `<module>/<instance>`, `foreign/<container-name>` or `unused/<image>`.

### Image vulnerabilities (all scopes)

- `syft <image> -o syft-json` → `grype sbom:<file> -o json`, both from pinned images; the Docker socket is mounted read-only into the Syft container to read local images (needed for locally built discourse, direktkredit, website, vaultwarden-sync).
- Covers distro packages, composer (`installed.json`), npm (incl. pnpm layout), gems, Go and cargo-auditable Rust binaries, and runtime/server binaries (PHP, Node, MariaDB, PostgreSQL, Redis, MongoDB, nginx, OpenLDAP).
- ID: `vuln:<CVE/GHSA>@<scope>` (one finding per vulnerability, listing all affected packages). Severity from Grype. Listed when ≥ display bar **and** a fixed version exists; otherwise only counted per scope ("12 unfixed HIGH").
- Suggested fix: `./habidat.sh fix <module>` if the module's tag is floating or a newer image with the fix exists; otherwise `./habidat.sh update <module>`; foreign: "update the image".

### End of life (all scopes)

- Versions from the Syft SBOM (via `lib/security/data/eol-products`) and from `/etc/os-release` of the image.
- Map v1: `php`, `node→nodejs`, `next→nextjs`, `ruby`, `rails`, `mariadb`, `postgresql`, `redis`, `mongodb`, `nginx`, `alpine→alpine-linux`, `debian`, `ubuntu`, `nextcloud`, `discourse`, `mediawiki`, `docker-engine`.
- endoflife.date `GET /api/v1/products/<product>/`, cached 24 h, honours `429 Retry-After`, treats an HTML 404 as "unknown product".
- `eol:<product>-<cycle>@<scope>`: HIGH when `eol` date has passed, MEDIUM when within 90 days.
- Unreachable endoflife.date → this check reports "could not run" (exit 2); other checks continue.
- Products not on endoflife.date (dokuwiki, vaultwarden, listmonk, openldap) are covered only by the abandoned-image check.

### Abandoned images (all scopes)

- For each image from Docker Hub: `GET hub.docker.com/v2/repositories/<ns>/<repo>/` (cached 24 h).
- `abandoned:<image>@<scope>` HIGH when `last_updated` older than `HABIDAT_SECURITY_ABANDONED_MONTHS` (12), or the description contains *deprecated / no longer maintained / legacy*, or the repo is archived.
- `moved:<image>@<scope>` MEDIUM from `lib/security/data/moved-images` (v1: `jwilder/nginx-proxy → nginxproxy/nginx-proxy`, `jrcs/letsencrypt-nginx-proxy-companion → nginxproxy/acme-companion`).
- `floating-tag:<image>@<scope>` LOW for `latest` or no tag.
- Locally built images (no registry) are skipped; images on other registries (ghcr, quay) are skipped in v1 with a verbose note.

### Outdated modules (installation scopes)

- `outdated-module:<module>@<module>` MEDIUM when `get_installed_version` < the latest version in the repo (`lib/version.sh`). Fix: `./habidat.sh update <module>`.

### Host (default run only; Debian/Ubuntu)

| Check | Tool | Finding |
|---|---|---|
| Pending security updates | Debian: `debsecan --suite <codename> --only-fixed`; Ubuntu: `pro security-status --format json` | `host-updates:<package>@host` HIGH, fix `apt upgrade` |
| Packages without security support | `check-support-status` (debian-security-support) | `host-unsupported:<package>@host` MEDIUM |
| Reboot / restart needed | `needrestart -b` (≥ 3.8) | `host-reboot@host` MEDIUM, `host-restart:<service>@host` MEDIUM |
| Automatic security updates | `unattended-upgrades` installed + `APT::Periodic::Unattended-Upgrade "1"` | `host-no-auto-updates@host` MEDIUM |
| Host OS end of life | endoflife.date `debian`/`ubuntu` | `eol:debian-<n>@host` |
| Hardening audit (`--host-audit`) | Lynis if installed (`lynis audit system --quick --no-colors`, parse `/var/log/lynis-report.dat`) | warnings → `lynis:<test-id>@host` MEDIUM; hardening index printed |

Missing tool → `skipped: install debsecan` (not exit 2). Needs root → `skipped: re-run with sudo`. Unsupported OS → all host checks skipped with a note.

### Docker daemon (default run only)

- `/etc/docker/daemon.json` + `docker info`: `userns-remap`, `live-restore`, `icc=false`, `no-new-privileges`, log rotation (`log-opts max-size`) → `docker:<setting>@host` LOW each.
- Privileged containers → `privileged:<container>@<scope>` HIGH.
- Containers mounting `docker.sock` → `docker-sock:<container>@<scope>` HIGH, unless the image matches `lib/security/data/expected-mounts`.
- Docker Engine end of life via `docker-engine` on endoflife.date.

### Exposure (default run only)

- `ss -tlnpu` for sockets on non-loopback addresses; `docker inspect` port bindings on `0.0.0.0`/`::`.
- `exposed:<proto>/<port>@<scope>` HIGH when not in `HABIDAT_SECURITY_EXPECTED_PORTS`.
- `ufw-bypass:<proto>/<port>@<scope>` HIGH when the port is published by Docker and ufw (or nftables) is active with no explicit allow for it — Docker-published ports are not filtered by ufw. Covers e.g. `HABIDAT_EXPOSE_LDAP=true`, mailhog.
- No scanning from outside.

### TLS (default run only)

- `ghcr.io/testssl/testssl.sh:<pinned>` against `HABIDAT_DOMAIN`'s main module host with `--jsonfile`; findings `tls:<testssl-id>@host` with testssl's severity.
- For every module hostname from `setup.env`: `openssl s_client` → `cert-expiry:<host>@host` HIGH (< 14 days), `cert-mismatch:<host>@host` HIGH, `cert-selfsigned:<host>@host` HIGH on a public domain.
- `--tls-full`: testssl on every hostname (≈ 1–2 min each).
- Skipped automatically for `.localhost` / `.test` domains.

### habidat config (default run only)

- `setup.env` not mode `600` (or not owned by the running user/root) → HIGH.
- Public domain (not `.localhost`/`.test`) with `HABIDAT_MAILHOG=true`, `HABIDAT_CREATE_SELFSIGNED=true` or `HABIDAT_LETSENCRYPT=false` → HIGH each.

## Severity and display

| Finding type | Severity |
|---|---|
| `vuln` | from Grype |
| `eol` (passed), `abandoned`, `host-updates`, `exposed`, `ufw-bypass`, `privileged`, `docker-sock` (unexpected), config findings, `cert-*` | HIGH |
| `eol` (≤ 90 days), `moved`, `outdated-module`, `host-reboot`, `host-restart`, `host-unsupported`, `host-no-auto-updates`, `lynis`, Nextcloud setup checks | MEDIUM |
| `floating-tag`, `docker:<setting>` | LOW |
| `tls` | testssl's severity |

- **Exit threshold**: HIGH (`--severity` changes it). Unfixed CVEs never count.
- **Display**: non-CVE findings ≥ one level below the exit threshold (default MEDIUM); CVEs ≥ exit threshold with a fix. `--verbose` shows all.

### Terminal summary (sketch)

```
SECURITY    | host
SECURITY    |   HIGH    host-updates:openssl          apt upgrade
SECURITY    |   MEDIUM  host-reboot                   reboot (kernel 6.1.0-28 → 6.1.0-31)
SECURITY    | nextcloud
SECURITY    |   HIGH    eol:php-8.2                   ./habidat.sh update nextcloud
SECURITY    |   HIGH    abandoned:dinkel/clamavd      replace image (no upstream updates since 2018-11)
SECURITY    |   HIGH    vuln:CVE-2026-1234            ./habidat.sh fix nextcloud
SECURITY    |           + 9 unfixed HIGH/CRITICAL vulnerabilities (see report)
SECURITY    | foreign containers
SECURITY    |   HIGH    exposed:tcp/8080@foreign/portainer
SECURITY    | skipped: lynis (use --host-audit), needrestart (re-run with sudo)
SECURITY    | 6 findings at HIGH or above, 2 accepted, 1 check could not run → exit 2
SECURITY    | report: store/.security-check/reports/20261107T101500Z/
```

### `report.json` (one object)

```json
{
  "started": "2026-11-07T10:15:00Z", "habidat_version": "…", "target": "all",
  "options": {"all_images": false, "host_audit": false, "tls_full": false, "severity": "HIGH"},
  "scanners": {"syft": "1.57.0@sha256:…", "grype": "0.121.2@sha256:…", "grype_db": "2026-11-07"},
  "checks": [{"name": "host.needrestart", "status": "ok|skipped|failed", "note": "…"}],
  "findings": [{
    "id": "vuln:CVE-2026-1234@nextcloud", "type": "vuln", "severity": "HIGH",
    "scope": "nextcloud", "container": "habidat-nextcloud", "image": "habidat/nextcloud:32.0.5",
    "title": "…", "fixed_in": "8.11.1", "fix": "./habidat.sh fix nextcloud",
    "accepted": null
  }],
  "exit_code": 1
}
```

## Accepted findings

`store/.security-check/accepted`, one per line, `#` comments allowed:

```
# <finding id>                         <expires YYYY-MM-DD>  <reason>
exposed:tcp/389@auth                   2027-03-01  LDAP exposed for the office NAS sync, IP-restricted at the hoster firewall
vuln:CVE-2026-9999@nextcloud           2027-01-15  not reachable: no XML upload path, recheck after NC 36
```

- ID may use `*` as the scope to accept across scopes (e.g. `floating-tag:mongo@*`).
- Missing reason, missing/invalid date, or expiry more than 183 days after the run date → the line is rejected with a warning and the finding stays active.
- Expired lines are reported once as "acceptance expired" and the finding is active again.
- Accepted findings are kept in `report.json` with `"accepted": {"until": …, "reason": …}`, but excluded from the summary and the exit code.

## Module hook contract

`<module>/security-check.sh`, executable, run via the existing `run_module_executable` (same environment as `fix.sh`), once per module (multi-instance: once per instance, instance id as `$1`). It is optional; without it the module gets all generic checks.

Output on stdout, one record per line, tab-separated:

```
volume	<container>	<path in container>          → scanned with Syft/Grype as a directory
finding	<type>	<subject>	<severity>	<title>	<fix>
skip	<reason>
```

Exit 0 = ran; non-zero = "check could not run" for that module (exit 2 overall). The hook must not change anything.

v1 hooks:

- **nextcloud**: `volume habidat-nextcloud /var/www/html/custom_apps` (and `/var/www/html/apps` only if it differs from the image); `occ update:check` → `outdated-app:<app>` MEDIUM and server update MEDIUM; `occ setupchecks --output=json` → each warning/error as `nextcloud-setup:<check>` MEDIUM; `occ status` major version is already covered by the `nextcloud` EOL product.
- **mediawiki** (per instance): `volume <container> /var/www/html/extensions` (only extensions not shipped in the image).

## Scanner pinning

`lib/security/scanners.sh` holds one line per scanner image: name, version, digest — e.g.

```
SYFT_IMAGE="anchore/syft:v1.57.0@sha256:…"
GRYPE_IMAGE="anchore/grype:v0.121.2@sha256:…"
TESTSSL_IMAGE="ghcr.io/testssl/testssl.sh:3.2.5@sha256:…"
```

Digests are filled in at implementation time from the registries. Updating a scanner is a normal commit. A static-tier test asserts every scanner reference contains `@sha256:`.

## Tests

- `tests/fixtures/security/`: recorded Syft and Grype JSON for two small images (one Alpine/Node with `next`, one Debian/PHP), a debsecan output, a `needrestart -b` output, a testssl JSON, Docker Hub and endoflife.date responses, `docker ps`/`inspect` and `ss` outputs.
- `tests/helpers/stub` gets stubs for `docker` (ps/inspect/run of scanner images return fixtures), `ss`, `curl`, `needrestart`, `debsecan`.
- Test files (tier 5, no Docker daemon):
  - inventory: compose-label and name-prefix mapping, multi-instance, foreign, `--all-images`.
  - findings: severity table, thresholds, unfixed-CVE counting, exit codes 0/1/2 incl. "2 wins over 1".
  - accepted: valid line, missing reason, expiry too far, expired, `*` scope.
  - eol: product map, cycle matching, 90-day window, unknown product, 429 handling.
  - abandoned: age, description keywords, moved map, floating tag, non-Docker-Hub skip.
  - exposure: expected ports, `0.0.0.0` vs `127.0.0.1` bindings, ufw active/inactive.
  - hook: record parsing, volume declaration, hook failure → exit 2.
  - CLI: usage line, `--dry-run` runs no scanner, unknown module.
- Static tier: shellcheck on new files (already global), digest-pinning assertion.
- A manual smoke run against the dev installation before merging; its report summary goes into the PR description.

## Implementation order

Each step is a reviewable commit and leaves the command working.

1. **Skeleton**: `habidat.sh` case + usage, `lib/security.sh` argument parsing, findings record, severity table, summary, `report.json`, exit codes, accepted findings — with a single trivial check (config: `setup.env` mode). Tests for findings/accepted/exit codes.
2. **Inventory + image vulnerabilities**: inventory mapping, pinned Syft/Grype, Grype DB volume, per-image scans, unfixed-CVE counting.
3. **End of life**: product map, endoflife.date cache, image + host OS + Docker Engine.
4. **Abandoned images**: Docker Hub cache, moved map, floating tags. Outdated modules.
5. **Host checks**: OS detection, debsecan / pro, check-support-status, needrestart, unattended-upgrades, sudo-skip handling, `--host-audit` Lynis.
6. **Docker daemon + exposure**.
7. **TLS**: testssl main domain, per-host certificate check, `--tls-full`.
8. **Module hooks**: contract, nextcloud, mediawiki.
9. **Docs**: README section (usage, sudo, network needs, accepted-findings format, where reports go, how to update scanner pins), `setup.env.example` settings.

## Network access needed

Registries for the pinned scanner images (Docker Hub, ghcr.io), Grype's DB host, `endoflife.date`, `hub.docker.com`, the installation's own public hostnames (TLS), `updates.nextcloud.com` (via `occ update:check`), and the Debian security tracker (debsecan). No accounts or API keys.

## Out of scope / follow-ups

- **Replacing abandoned images** — the first run will report: `dinkel/clamavd`, `mprasil/dokuwiki`, `mailtrain/mailtrain`, `mailhog/mailhog`, `osixia/openldap` 1.x (v2 rewrite at RC, breaking), and the moved `jwilder/nginx-proxy` / `jrcs/letsencrypt-nginx-proxy-companion`. Each is its own module update.
- Scheduling (systemd timer / cron) and alerting — together with the backup module's alerts.
- Hooks for discourse (`/admin/version_check.json`), direktkredit, vaultwarden, listmonk.
- Scanning images from registries other than Docker Hub for abandonment (ghcr, quay).
- External port scan from another host; Nextcloud's public scan.nextcloud.com.
- Secret scanning in images; backup health (backup module).
- Automatic pruning of old reports; comparing two reports ("new since last run").
