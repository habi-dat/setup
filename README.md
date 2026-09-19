<p align="center">
  <img width=100% src="habidatwide.png">
</p>

# habi\*DAT setup

habi\*DAT is a modular collaboration platform for small collective projects. It integrates an LDAP user backend, Nextcloud, Discourse, Mediawiki, Dokuwiki, Direktkredit, and Mailtrain behind a shared nginx reverse proxy with optional Let's Encrypt.

This repository provides a CLI tool (`habidat.sh`) for installing, updating, exporting, and importing all modules. It features a **versioned migration system** that allows reliable step-by-step updates from any installed version to the current one, and uses **Jinja2 templates** for configuration files.

## Prerequisites

### Software

- **Docker** with the **Compose plugin** (`docker compose`)
- **Python 3** with **Jinja2** (`apt install python3-jinja2`) for templating
- **git** (discourse and direktkredit clone their upstream repositories)
- **openssl** (password and SSO certificate generation)
- **curl** and **netcat** (`nc`) -- discourse installation only
- **tar** and **gzip** (export and import)
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
| mediawiki    | `mediawiki.<domain>`       |
| dokuwiki     | `dokuwiki.<domain>`        |
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
| `HABIDAT_BACKUP_DIR` | Absolute path for export/import data |
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

Modules are installed in dependency order: **nginx** -> **auth** -> **nextcloud** -> then direktkredit, discourse, dokuwiki, mailtrain, mediawiki.

**mediawiki is an exception.** It supports multiple independent instances, so each
one needs a project id, a title and an LDAP group:

```bash
./habidat.sh install mediawiki <project-id> <project title> <ldap-group>
```

`install all` therefore cannot install mediawiki -- it reaches mediawiki last and
stops there with mediawiki's usage message. Install every other module with
`install all`, then add each wiki instance individually.

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

#### Start / Stop / Restart

```bash
./habidat.sh start   <module>|all
./habidat.sh stop    <module>|all
./habidat.sh restart <module>|all
./habidat.sh up      <module>|all   # Create and start containers
./habidat.sh down    <module>|all   # Stop and remove containers
```

#### Export / Import

```bash
./habidat.sh export <module>        # Export module data
./habidat.sh export all             # Export all modules that support it
./habidat.sh import <module> list   # List the available backup files for a module
./habidat.sh import <module> <file> # Import module data from file
```

Exports are written to `$HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/<module>/`, and
`import` looks for `<file>` in that same directory.

Export/import scripts are versioned -- they use the behavior matching the currently installed module version, not the latest version in the repository.

Modules with export/import support: **auth**, **nextcloud**, **discourse**.

Nextcloud export supports a `nodata` option to exclude user files:

```bash
./habidat.sh export nextcloud nodata
```

#### Other

```bash
./habidat.sh modules                # List all modules and their status
./habidat.sh pull <module>|all      # Pull Docker images
./habidat.sh build <module>|all     # Build Docker images
./habidat.sh help                   # Show help
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
| **mailtrain** | Newsletter / mailing list manager | nginx, auth, nextcloud |

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
  tests/                  # Test suite (see tests/README.md)
    run.sh                #   Local entry point
    *.bats                #   Test tiers
    helpers/              #   Sandbox harness, docker stub, setup.env profiles
    fixtures/             #   Synthetic module tree for unit tests
  store/                  # Runtime state (not in git)
    <module>/             #   Per-module: compose files, configs, volumes, version
  <module>/               # Module definition
    version               #   Target version
    dependencies          #   Module dependencies (one per line)
    setup.sh              #   Fresh install script
    docker-compose.yml.j2 #   Latest compose template
    config/               #   Latest config templates
    assets/               #   Static files (scripts, icons, images) if needed
    versions/             #   Versioned snapshots
      <ver>/
        migrate.sh        #   Migration script for this version
        docker-compose.yml.j2  # Compose template as of this version
        config/           #   Config templates as of this version
    export/               #   Versioned export scripts
      <ver>.sh
    import/               #   Versioned import scripts
      <ver>.sh
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
`.github/workflows/ci.yml` and run on manual dispatch only.

See [tests/README.md](tests/README.md) for how the harness works and how to add
cases.

### Adding a new module

1. Create a directory with the module name
2. Add a `version` file with the initial version (e.g. `0.0.1`)
3. Add a `dependencies` file listing required modules (one per line)
4. Create `setup.sh` for fresh installation, and **make it executable**
5. Create `docker-compose.yml.j2` and config templates in `config/`
6. Create `versions/<ver>/` with `migrate.sh` and versioned templates
7. Optionally add `export/<ver>.sh` and `import/<ver>.sh`

The module is automatically discovered by the CLI -- no changes to `habidat.sh` needed.

Conventions every script in the repository follows, each enforced by
`tests/10_invariants.bats`:

- **`#!/usr/bin/env bash`**, not `#!/bin/bash`. The latter fails on hosts without
  bash at that path, including NixOS.
- **Lifecycle scripts must be executable.** `remove.sh`, `start.sh`, `stop.sh`,
  `restart.sh`, `up.sh`, `down.sh`, `pull.sh`, `build.sh` and `update.sh` are
  invoked as `./<action>.sh`, so mode 644 means "Permission denied". Use
  `git update-index --chmod=+x <file>` if the mode did not make it into the
  index. Migration, export and import scripts are `source`d instead and do not
  need the bit.
- **`set -euo pipefail`** at the top. Lifecycle scripts run as child processes and
  migrations run via `run_module_script`, so a failure mid-script aborts it and is
  reported with the module name and exit code.

### Creating a new version

1. Bump the version in `<module>/version`
2. Create `versions/<new-ver>/migrate.sh` with the migration logic
3. If templates changed, add them to `versions/<new-ver>/` (unchanged templates are inherited from earlier versions)
4. If export/import behavior changed, add new scripts to `export/` and `import/`
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
