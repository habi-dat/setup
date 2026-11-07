<p align="center">
  <img width=100% src="habidatwide.png">
</p>

# habi\*DAT setup

habi\*DAT is a modular collaboration platform for small collective projects. It integrates an LDAP user backend, Nextcloud, Discourse, Mediawiki, Dokuwiki, Direktkredit, and Mailtrain behind a shared nginx reverse proxy with optional Let's Encrypt.

This repository provides a CLI tool (`habidat.sh`) for installing, updating, backing up and restoring all modules. It features a **versioned migration system** that allows reliable step-by-step updates from any installed version to the current one, and uses **Jinja2 templates** for configuration files.

## Prerequisites

### Software

- **Docker** with the **Compose plugin** (`docker compose`)
- **Python 3** with **Jinja2** (`apt install python3-jinja2`) for templating
- **git** (discourse and direktkredit clone their upstream repositories)
- **openssl** (password and SSO certificate generation)
- **curl** and **netcat** (`nc`) -- discourse installation only
- **tar** and **gzip** (reading export files on restore)
- **flock** (util-linux) and **systemd**, for the backup module's nightly timer
- **mkcert** + **libnss3-tools** (only for local development with self-signed certs)

`habidat.sh` only verifies Docker, the Compose plugin and the renderer on startup; the
rest fail at the point they are first used. If you have Nix, `nix develop`
provides all of them at pinned versions -- see
[Development environment](#development-environment).

#### A note on templating

Configuration files are rendered by `lib/render.py`, which ships with this
repository and needs nothing but Jinja2:

```bash
apt install python3-jinja2     # Debian / Ubuntu
./lib/render.py --help         # must print usage, not an import error
```

Earlier versions required [j2cli](https://github.com/kolypto/j2cli). That project
is unmaintained and no longer runs on a current Python -- it imports `imp`
(removed in Python 3.12) and `pkg_resources` (dropped from setuptools 81) -- so it
was replaced. If you are upgrading an existing installation you can uninstall it;
nothing calls `j2` any more.

### DNS

You need a domain with subdomains for each module you want to install. The subdomains are configured in `setup.env`:

| Module       | Default subdomain          |
| ------------ | -------------------------- |
| auth         | `user.<domain>`            |
| nextcloud    | `cloud.<domain>`           |
| discourse    | `discourse.<domain>`       |
| direktkredit | `direktkredit.<domain>`    |
| mediawiki    | `{project}.mediawiki.<domain>` |
| dokuwiki     | `dokuwiki.<domain>`        |
| listmonk     | `{project}.lists.<domain>` |
| mailtrain    | `mailtrain.<domain>`, `lists.<domain>`, `sandbox.mailtrain.<domain>` |

## Setup

1. Clone this repository
2. Copy `setup.env.example` to `setup.env` and fill in all parameters
3. Run `./habidat.sh install all` or install modules individually

### Configuration (`setup.env`)

Copy `setup.env.example` to `setup.env` and adjust the values. Key parameters:

| Parameter | Description |
| --------- | ----------- |
| `HABIDAT_DOMAIN` | Your main domain (e.g. `example.com`) |
| `HABIDAT_DOCKER_PREFIX` | Prefix for all Docker resources. Must be unique on the host. |
| `HABIDAT_ADMIN_EMAIL` | Admin email address |
| `HABIDAT_ADMIN_PASSWORD` | Admin password, or `generate` to auto-generate one |
| `HABIDAT_BACKUP_DIR` | Absolute path for export files (`export`, `restore --file`) |
| `HABIDAT_LDAP_DOMAIN` | Usually same as `HABIDAT_DOMAIN`. Use production value when importing production LDAP data. |
| `HABIDAT_LDAP_BASE` | Derived from domain, e.g. `example.com` becomes `dc=example,dc=com` |
| `HABIDAT_LETSENCRYPT` | `true` for production, `false` for development |
| `HABIDAT_CREATE_SELFSIGNED` | `true` for development (uses mkcert) |
| `HABIDAT_MAILHOG` | `true` to use a local mailhog instance for development emails |

Make sure SMTP settings are correct for production, or enable mailhog for development.

## CLI Usage

```
./habidat.sh [--verbose] [--dry-run] COMMAND
```

### Global flags

| Flag | Description |
| ---- | ----------- |
| `--verbose` | Enable detailed output |
| `--dry-run` | Show what would be done without executing |

### Commands

#### Install

```bash
./habidat.sh install <module>       # Install a single module
./habidat.sh install all            # Install all modules (respects dependency order)
./habidat.sh install <module> force # Reinstall a module
```

Modules are installed in dependency order: **nginx** -> **auth** -> **nextcloud** -> then direktkredit, discourse, dokuwiki, listmonk, mailtrain, mediawiki, vaultwarden.

**mediawiki** and **listmonk** are multi-instance modules. Each instance needs a
project id, a title and an LDAP / habidat-auth group. `install all` skips them;
add instances individually:

```bash
./habidat.sh install mediawiki <project-id> <project title> <ldap-group>
./habidat.sh install listmonk <project-id> <title> <ldap-group> [--from-mailtrain]
```

Listmonk is reached at `{project}.lists.{domain}` (admin UI, subscribe and
unsubscribe share that host). Sign-in is habidat-auth OIDC; people who are not
in the given group never finish login. Setup replaces Listmonk's sample visual
template with Standardvorlage (logo, greeting, two image-and-text blocks, and
the unsubscribe and view-in-browser links). Mailtrain can keep running at
`lists.{domain}` during a migration -- the hostnames do not collide. Pass
`--from-mailtrain` to copy lists, subscribers, SMTP send configurations, HTML templates, campaign content, and uploaded files into the new instance. Mailtrain's hourly throttling is copied too: Listmonk has one send pace for the whole instance, so the tightest mailbox cap is used and messages stay at or under that rate. Built-in ZoneMTA and Amazon SES stay behind; Listmonk then keeps the SMTP settings from `setup.env`. Finished Mailtrain campaigns become finished Listmonk campaigns and are not sent; unsent ones become drafts. Send history, open and click counts, automations, segments, and custom forms stay behind.
A Mailtrain that habidat-setup did not install can be named with `--database`, one Listmonk instance per database:

```bash
./habidat.sh install listmonk schlor "Schlör" schlor --from-mailtrain --database mailtrain_schlor
```

That reads the MariaDB root password from the running `<prefix>-mailtrain-db` container and does not print it. Files are taken from `<prefix>-mailtrain-<project-id>` when that container is running, otherwise from `<prefix>-mailtrain`. The same import for an instance that already exists is `listmonk/migrate-from-mailtrain.sh <project-id> [--database <name>]`.
Mailtrain is not removed. Per-list status is kept only for addresses that
still have an email. This platform's Mailtrain wipes the email one day after
an unsubscribe or complaint and deletes the row after 30 days; those rows are
counted and skipped, and those people can be subscribed again in Listmonk.
Bounced addresses keep their email and are imported as unsubscribed.

```bash
./habidat.sh start|stop|restart|up|down listmonk [project-id]
./habidat.sh remove listmonk [project-id]
./habidat.sh install listmonk force <project-id> <title> <ldap-group>
```

`force` on a multi-instance module tears down **that instance only**.

#### Remove

```bash
./habidat.sh remove <module>        # Remove a module (prompts for confirmation)
./habidat.sh remove <module> force  # Remove without confirmation
```

**Warning**: This removes all containers, volumes, and data for the module.

#### Update

```bash
./habidat.sh update <module>              # Update a single module to the latest repo version
./habidat.sh update all                   # Update all installed modules
./habidat.sh update <module> <version>    # Update up to a specific version (inclusive)
./habidat.sh update <module> force        # Bypass the up-to-date and downgrade checks
```

Updates run versioned migrations step by step from the installed version to the target version (or to `<version>` if given). Each migration uses the correct templates and scripts for that specific version transition.

Example: production is on Nextcloud 32 and the repo already contains 33 and 34:

```bash
./habidat.sh update nextcloud 33.0.0   # stop after 33
./habidat.sh update nextcloud          # continue to 34 (or whatever nextcloud/version says)
```

`force` lets an update proceed when the module is already at the target version
or when the installed version is newer than the target. It does **not** re-run
the migration for the version currently installed: migrations are selected
strictly above the installed version, so forcing an already-up-to-date module
finds no steps to run and only rewrites the version marker.

**discourse** ships its own `update.sh` instead of versioned migrations, so
`update discourse <version>` is rejected -- it always rebuilds to the version in
`discourse/version`.

#### Fix

```bash
./habidat.sh fix <module> [instance-id]   # Pull images and recreate containers, no migration
./habidat.sh fix all                      # The same for all installed modules
```

`fix` is for modules whose compose file uses a floating image tag (`habidat/auth:2.2`
for example): a new build of the same tag is picked up without releasing a new
module version. It does not render templates, run migrations or change
`store/<module>/version`.

By default it runs `pull` and then `up`. A module that needs more after the
containers are recreated ships a `fix.sh` instead: **auth** runs `user-init`
(Prisma migrate + seed) between pull and start, **nextcloud** reinstalls `jq` and
reruns the post-update configuration, **mediawiki** walks its instances,
**direktkredit** pulls its code and updates all projects, and **discourse**
rebuilds both containers (slow, and the forum is down meanwhile).

#### Start / Stop / Restart

```bash
./habidat.sh start   <module>|all
./habidat.sh stop    <module>|all
./habidat.sh restart <module>|all
./habidat.sh up      <module>|all   # Create and start containers
./habidat.sh down    <module>|all   # Stop and remove containers
```

#### Backup, snapshots and restore

The `backup` module pushes a nightly **snapshot** of the whole installation (every
module's dumps, store folder and Docker volumes, plus `setup.env`) over SSH to a
**backup repository** on another server, with borg 1.4. One repository holds the
snapshots of exactly one installation. The design and its trade-offs are in
[`docs/adr/0005`](docs/adr/0005-module-exports-name-data-borg-reads-in-place.md) to
[`0008`](docs/adr/0008-backup-tamper-protection-modes.md).

```bash
./habidat.sh install backup <ssh://user@host[:port]/path> <protection> [alert-email]
./habidat.sh configure backup       # connect, create or take over the repository, install timers
./habidat.sh backup                 # take a snapshot now (the timer runs at 03:00)
./habidat.sh backup status          # last snapshot, number of snapshots
./habidat.sh backup check [--full]  # check the repository (--full reads every chunk)
./habidat.sh snapshots [module [instance]]
./habidat.sh restore <module>|all [instance] <snapshot>|latest
```

`protection` is one of:

- `provider-snapshots` -- a Hetzner Storage Box, one **sub-account per
  installation**. Turn on the box's automatic snapshots in the Hetzner Console:
  they are read-only for SSH users and are what undoes an attack, for as many days
  as the box has snapshot slots. To recover one installation, copy its directory
  out of `.zfs/snapshot/<name>/` instead of rolling back the whole box.
- `append-only` -- your own SSH server. `install backup` prints the
  `authorized_keys` line that locks this server's key to
  `borg serve --append-only`. Pruned snapshots are only marked as deleted; free
  the space now and then from a trusted machine with `borg compact`, after
  checking the repository.

`install backup` creates this server's own SSH key; an admin allows it on the
repository host by hand, so the server never holds an admin login to the backup
storage. `configure backup` then creates the repository (`repokey-blake2`) and
shows its **passphrase and key once**: store both offline. Whoever holds them can
read every snapshot, including every password in `store/`.

Snapshots are kept 7 daily, 4 weekly and 6 monthly. A failed snapshot, a module
that failed to export, no successful snapshot for 36 hours and a sharp drop in
the number of snapshots are mailed to the alert address through the SMTP server
from `setup.env`.

**Restore** puts a module (or one instance, or `all`) back at the version recorded
in the snapshot, starts it, runs the **link steps** that rewrite what modules add
to each other (login apps in auth, lines in `auth.env`, `nextcloud.env`,
`networks.env`), and then runs the normal `update` to the repository's version.
It never runs `setup.sh`, whose new secrets would not match the restored data.

On a **new server**, `install backup`, `configure backup` (which takes over the
existing repository and asks for its passphrase), `snapshots` and `restore` work
without `setup.env`; `restore all <snapshot>` puts `setup.env` back first, then
restores every module in dependency order. The Docker prefix comes from the
snapshot and must match; restoring under another domain is not supported. Take
the old server's timer down first (`./habidat.sh stop backup` there): configure
warns when the newest snapshot is less than 24 hours old.

#### Export files

```bash
./habidat.sh export <module>|all [instance]       # write module data to a file
./habidat.sh restore <module> [instance] --file <file>
./habidat.sh import <module> list                 # list export files of a module
```

An export file is one module or instance in the same layout as a snapshot, packed
as `.tar.gz` into `$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/<module>/`
(`exports/` in the repository when `HABIDAT_BACKUP_DIR` is unset). `import
<module> <file>` still works for one release: for a file in the new layout it
is an alias for `restore --file`, and a file written before snapshots (e.g. the
exports the `UPDATE` notes ask for, or auth 1.x data for auth 2) is imported
with the previous release's import script from `<module>/legacy-import/`. Both
go away in the next release.
The `nodata` option of the nextcloud export is gone: an export always holds the
whole module.

Export/restore scripts are versioned: an export uses the script for the installed
module version, a restore the script for the version that wrote the data.

Modules with export/restore support: **auth**, **nextcloud**, **discourse**, **vaultwarden**, **listmonk**, **mediawiki**, **website**, **dokuwiki**, **nginx**.

#### Other

```bash
./habidat.sh modules                # List all modules and their status
./habidat.sh pull <module>|all      # Pull Docker images
./habidat.sh build <module>|all     # Build Docker images
./habidat.sh configure <module>     # Post-install configuration that needs operator input (vaultwarden, backup)
./habidat.sh link <module>|all      # Rewrite what a module contributes to other modules (repair)
./habidat.sh help                   # Show help
```

#### Security check

```bash
./habidat.sh security-check                     # the whole server: host, all modules, foreign containers, TLS
sudo ./habidat.sh security-check                # same, including the host checks that need root
./habidat.sh security-check nextcloud           # one module only (its containers, code and app checks)
./habidat.sh security-check mediawiki <id>      # one module instance
./habidat.sh security-check --all-images        # also images no running container uses
./habidat.sh security-check --host-audit        # also a Lynis hardening audit (needs `apt install lynis`)
./habidat.sh security-check --tls-full          # testssl.sh against every module host name, not only auth's
./habidat.sh security-check --severity MEDIUM   # lower the bar for the exit code and the summary
./habidat.sh --dry-run security-check           # list what would be scanned, scan nothing
```

The security check is read-only: it reports, it never changes anything. Each
finding comes with a suggested fix, usually `./habidat.sh fix <module>`
(pull newer images) or `./habidat.sh update <module>`. Terms are defined in the
*Security* section of [GLOSSARY.md](GLOSSARY.md); the design is in
[docs/plans/security-check.md](docs/plans/security-check.md).

| What | How |
| ---- | --- |
| Image vulnerabilities, incl. PHP, Node.js, database binaries, composer/npm/gem/Go packages | [Syft](https://github.com/anchore/syft) + [Grype](https://github.com/anchore/grype) as pinned containers ([ADR 0009](docs/adr/0009-grype-syft-not-trivy.md)) |
| End of life (OS, PHP, Node.js, Next.js, databases, Nextcloud, Docker Engine, ...) | [endoflife.date](https://endoflife.date) API, map in `lib/security/data/eol-products` |
| Abandoned, moved and floating-tag images | Docker Hub API, map in `lib/security/data/moved-images` |
| Outdated modules | installed vs. repository version |
| Host (Debian, Ubuntu and derivatives) | pending security updates (`apt-get -s`), `needrestart`, `check-support-status`, unattended-upgrades |
| Docker daemon | user namespaces, live-restore, icc, no-new-privileges, log rotation, privileged containers, `docker.sock` mounts |
| Exposure | listening sockets and published ports outside `HABIDAT_SECURITY_EXPECTED_PORTS`; ports Docker publishes past ufw |
| TLS (public domains only) | certificate expiry / name / trust for every module host; [testssl.sh](https://testssl.sh) |
| `setup.env` | file mode; mailhog, self-signed certificates or no Let's Encrypt on a public domain |
| Module checks | `<module>/security-check.sh` (Nextcloud: app and server updates, setup warnings, apps in `custom_apps`) |

All other running containers on the server are scanned too and reported as
*foreign containers*.

**Exit code**: `0` nothing at or above the severity (default `HIGH`), `1`
findings, `2` a check could not run (no network for the vulnerability database
or endoflife.date, a scanner failed, ...). Vulnerabilities without a released
fix are counted but never make the check fail.

**Network**: Docker Hub and ghcr.io (scanner images), Grype's database host,
endoflife.date, hub.docker.com, and updates.nextcloud.com (via `occ`). No
accounts. The first run downloads the vulnerability database (~1 minute) into
the volume `<prefix>-security-check-grype-db`; SBOMs are cached per image, so
later runs only re-match vulnerabilities.

**Reports** go to `store/.security-check/reports/<timestamp>/` (`latest` points
to the newest): `summary.txt`, `report.json` with every finding, and the SBOM
and Grype output per image. They are never pruned automatically; delete old ones
with `rm -rf`.

**Accepted findings**: to live with a finding for a while, add a line to
`store/.security-check/accepted` with its id (as printed, `@<scope>` included),
an expiry date at most 183 days away, and a reason. `*` matches anything, for
example in the scope. When the date passes, the finding is reported again.

```
# <finding id>                     <expires>   <reason>
ufw-bypass:tcp/389@auth            2027-03-01  LDAP is restricted to the office IP at the hoster firewall
vuln:CVE-2026-9999@nextcloud       2027-01-15  not reachable: no XML upload path
floating-tag:mongo@*               2027-02-01  pinned in the next module update
```

## Modules

| Module | Description | Dependencies |
| ------ | ----------- | ------------ |
| **nginx** | Reverse proxy with optional Let's Encrypt | none |
| **auth** | LDAP user backend, SSO, user management app | nginx |
| **nextcloud** | File sharing, calendar, collaboration | nginx, auth |
| **discourse** | Discussion forum | nginx, auth, nextcloud |
| **direktkredit** | Direct loan management | nginx, auth, nextcloud |
| **mediawiki** | Wiki (supports multiple instances) | nginx, auth, nextcloud |
| **dokuwiki** | Lightweight wiki | nginx, auth, nextcloud |
| **listmonk** | Newsletter / mailing list manager (multiple instances) | nginx, auth, nextcloud |
| **mailtrain** | Newsletter / mailing list manager (legacy) | nginx, auth, nextcloud |
| **vaultwarden** | Password manager, shared with auth groups | nginx, auth |
| **website** | Website editor with auth login (multiple instances) | nginx, auth |
| **backup** | Nightly snapshots to a borg repository, restore (not part of `install all`) | none |

### Vaultwarden

A password manager at `{HABIDAT_VAULTWARDEN_SUBDOMAIN}.{domain}`. Everyone with an
auth account logs in through auth (and still sets a Vaultwarden master
password, which never leaves their device). All shared passwords live in one
organization:

- Every auth group appears as a Vaultwarden group with the same members,
  including members of its sub-groups (group owners count only if they are also
  members).
- Every group gets a **group collection** named after it, which its members can
  manage: store passwords in it and share it with any other group. Personal
  passwords stay in each user's own vault and are never visible to anyone else.
- A new collection for a subset of people: create an auth sub-group. Ask the
  super admin for anything else.

A sync container (`<prefix>-vaultwarden-sync`) reads auth's LDAP every five
minutes and applies groups, memberships, group collections, removals and
renames. Deleting an auth group keeps its collection, reachable only by the
super admin.

**Security trade-off.** New members get access without anyone approving them:
a bot account confirms them automatically, and Vaultwarden runs without SMTP so
invitations are accepted on the first login. Whoever controls the server (or
can change group membership in auth) can therefore read every shared password.
Personal vaults are not affected. See [ADR 0003](docs/adr/0003-automatic-member-confirmation.md).
Groups that need protection against that can get a separate organization
without the bot, created and confirmed by hand.

**One-time setup** after `./habidat.sh install vaultwarden` (the organization's
keys are created in the browser):

1. In auth, create the super admin user (email `HABIDAT_VAULTWARDEN_ADMIN_EMAIL`)
   and a bot user (e.g. `vaultwarden-bot`). Neither needs to be an auth admin.
2. As the super admin, log in to Vaultwarden through auth, set a master password
   and create the organization.
3. As the bot, log in once, set a master password and copy its personal API key
   (Account settings > Security > Keys).
4. As the super admin, invite the bot as **Admin** and confirm it, then create
   the organization API key (Organization settings).
5. `./habidat.sh configure vaultwarden` asks for both keys and the bot's master
   password, shows a dry run of the first sync and starts the sync.

Users whose email is not verified in auth cannot log in to Vaultwarden.

### Admin account

After installation, log in to all services with username `admin`. The password is printed at the end of installation and stored in `store/auth/passwords.env`.

## Architecture

### Directory structure

```
habidat-setup/
  habidat.sh              # CLI entry point
  setup.env               # User configuration (not in git)
  setup.env.example       # Configuration template
  flake.nix               # Pinned development and test environment
  lib/                    # Shared bash libraries
    common.sh             #   Logging, error handling, prerequisites
    template.sh           #   Template resolution and rendering
    render.py             #   Jinja2 renderer (replaces j2cli)
    version.sh            #   Version comparison, migration runner
    modules.sh            #   Module discovery, lifecycle, dependency management
    security.sh           #   security-check: collects raw data
    security/             #   security-check: pinned scanners, analyser (analyse.py), data maps
  tests/                  # Test suite (see tests/README.md)
    run.sh                #   Local entry point
    *.bats                #   Test tiers
    helpers/              #   Sandbox harness, docker stub, setup.env profiles
    fixtures/             #   Synthetic module tree for unit tests
  store/                  # Runtime state (not in git)
    <module>/             #   Per-module: compose files, configs, volumes, version
    .security-check/      #   security-check reports, caches and accepted findings
  <module>/               # Module definition
    version               #   Target version
    dependencies          #   Module dependencies (one per line)
    setup.sh              #   Fresh install script
    security-check.sh     #   Optional module part of security-check
    docker-compose.yml.j2 #   Latest compose template
    config/               #   Latest config templates
    assets/               #   Static files (scripts, icons, images) if needed
    versions/             #   Versioned snapshots
      <ver>/
        migrate.sh        #   Migration script for this version
        docker-compose.yml.j2  # Compose template as of this version
        config/           #   Config templates as of this version
    export/               #   Versioned export scripts (dumps + names of volumes)
      <ver>.sh
    restore/              #   Versioned restore scripts, one per export script
      <ver>.sh
    link.sh               #   Link step: rewrites what the module adds to other modules
```

### Versioned migration system

Each module has a `version` file with the target version. The `store/<module>/version` file tracks the currently installed version. When updating, the system:

1. Compares installed vs. target version (`<module>/version`, or the version passed to `update`)
2. Finds all migration directories between them (`versions/<ver>/migrate.sh`)
3. Runs each migration step by step, using the correct templates for each version
4. Updates `store/<module>/version` after each successful step

This means a user 3 versions behind will run 3 sequential migrations, each using the correct configuration templates for that transition. Pass a version to `update` to stop after a given step instead of going all the way to the repo target.

If a migration fails, the update stops at that step and leaves
`store/<module>/version` at the last version that completed, so fixing the issue
and re-running resumes from there. This holds for both `update <module>` and
`update all`; on `update all` the remaining modules are still attempted and the
command reports a non-zero exit at the end.

Each migration runs in its own shell process so that its `set -euo pipefail`
takes effect reliably -- see the note on `run_module_script` in `lib/common.sh`
for why a subshell is not sufficient.

### Template resolution

Templates are resolved per-version using a fallback strategy: if a template doesn't exist in `versions/<ver>/`, the system walks backwards through earlier versions to find the most recent one. This means you only need to add a template to a version directory when it actually changes.

### Jinja2 templating

Configuration and compose files are Jinja2 templates rendered by `lib/render.py`. This supports conditionals, defaults, loops and filters -- replacing the limited `envsubst` approach. Every environment variable exported by `setup.env`, plus the values a module's `setup.sh` generates at run time, is available in a template.

Two things to know when editing a template:

- **Rendering uses `StrictUndefined`.** A variable that nothing exports is a
  hard error, not an empty string -- and inside a migration that means aborting
  partway through an upgrade. Give optional variables a `default(...)`, and make
  sure anything mandatory is either in `setup.env.example` or exported by the
  module's `setup.sh` before the `j2` call.
- **Use `default("")`, not `default(none)`.** Jinja renders `none` as the literal
  four characters `None`, so an unset subdomain becomes the string `None` and
  gets interpolated into URLs.

`tests/30_render.bats` renders every template under three configuration profiles
and checks both of these, and `tests/23_render_py.bats` pins the renderer's own
behaviour -- so a mistake here fails in CI rather than on a server.

## Development

### Development environment

A Nix flake pins every tool the project and its tests need -- bats, shellcheck,
Python with Jinja2, the Docker CLI, mkcert, openssl:

```bash
nix develop        # everything, including the runtime tools for a real install
nix develop .#ci   # test tooling only
```

Without Nix, install the prerequisites from the list above yourself and run
`npm install` to get bats.

### Tests

```bash
./tests/run.sh              # whole suite, ~100 seconds
./tests/run.sh 20_version   # one tier
./tests/run.sh --list       # show the tiers
npm test                    # same thing
```

The suite covers static analysis, the filesystem conventions the CLI infers
modules and versions from, the version-comparison and template-resolution
libraries, rendering every Jinja2 template under three configuration profiles,
and the CLI end to end against a recording `docker` stub. Nothing in it contacts
a Docker daemon or touches your `store/` or `setup.env`.

Integration tests against real containers live in the `integration` job of
`.github/workflows/ci.yml`. They install nginx, auth and nextcloud against a real
Docker daemon and run nightly or on demand, not on every pull request.

See [tests/README.md](tests/README.md) for how the harness works and how to add
cases.

### Adding a new module

1. Create a directory with the module name
2. Add a `version` file with the initial version (e.g. `0.0.1`)
3. Add a `dependencies` file listing required modules (one per line)
4. Create `setup.sh` for fresh installation, and **make it executable**
5. Create `docker-compose.yml.j2` and config templates in `config/`
6. Create `versions/<ver>/` with `migrate.sh` and versioned templates
7. Add `export/<ver>.sh` and `restore/<ver>.sh` (the contract is described at the
   top of `lib/export.sh`), and a `link.sh` if `setup.sh` writes into another
   module's store or into auth's database

The module is automatically discovered by the CLI -- no changes to `habidat.sh` needed.

Conventions every script in the repository follows, each enforced by
`tests/10_invariants.bats`:

- **`#!/usr/bin/env bash`**, not `#!/bin/bash`. The latter fails on hosts without
  bash at that path, including NixOS.
- **Lifecycle scripts must be executable.** `remove.sh`, `start.sh`, `stop.sh`,
  `restart.sh`, `up.sh`, `down.sh`, `pull.sh`, `build.sh`, `fix.sh`, `update.sh`, `configure.sh` and `link.sh` are
  invoked as `./<action>.sh`, so mode 644 means "Permission denied". Use
  `git update-index --chmod=+x <file>` if the mode did not make it into the
  index. Migration, export and restore scripts are `source`d instead and do not
  need the bit.
- **`set -euo pipefail`** at the top. Lifecycle scripts run as child processes and
  migrations run via `run_module_script`, so a failure mid-script aborts it and is
  reported with the module name and exit code.

### Creating a new version

1. Bump the version in `<module>/version`
2. Create `versions/<new-ver>/migrate.sh` with the migration logic
3. If templates changed, add them to `versions/<new-ver>/` (unchanged templates are inherited from earlier versions)
4. If what the module stores changed, add new scripts to `export/` and `restore/`.
   Never delete old ones, or old `versions/<ver>/` directories: a snapshot is
   restored at the version that wrote it (ADR 0006)
5. Update the root `docker-compose.yml.j2` and `config/` to match the latest version

Step 5 matters more than it looks: the root templates are what a **fresh install**
renders, while `versions/<newest>/` is what an **upgrade** renders. If they drift,
new and upgraded installations end up differently configured and the difference
only shows up in production. `tests/10_invariants.bats` asserts they stay
byte-identical for every template the newest version directory contains.

Anything you render from `migrate.sh` should therefore have a snapshot under
`versions/<new-ver>/`. Templates rendered only by `setup.sh` never reach existing
installations at all -- there are several such files today, listed in the ratchet
in `tests/10_invariants.bats`.

### Useful helpers in migration scripts

```bash
# Render a versioned template (resolves correct version automatically)
render_versioned_template <module> "$HABIDAT_MIGRATE_VERSION" \
  <template-path> <output-path>

# Copy a versioned file without rendering
copy_versioned_file <module> "$HABIDAT_MIGRATE_VERSION" \
  <source-path> <dest-path>

# Remove a file from store
remove_store_file <path>
```

Migration scripts have access to these environment variables:

| Variable | Description |
| -------- | ----------- |
| `HABIDAT_MIGRATE_VERSION` | The version being migrated to |
| `HABIDAT_MIGRATE_FROM` | The version being migrated from |
| `HABIDAT_MIGRATE_MODULE` | The module being migrated |
