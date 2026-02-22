<p align="center">
  <img width=100% src="habidatwide.png">
</p>

# habi\*DAT setup

habi\*DAT is a modular collaboration platform for small collective projects. It integrates an LDAP user backend, Nextcloud, Discourse, Mediawiki, Dokuwiki, Direktkredit, and Mailtrain behind a shared nginx reverse proxy with optional Let's Encrypt.

This repository provides a CLI tool (`habidat.sh`) for installing, updating, exporting, and importing all modules. It features a **versioned migration system** that allows reliable step-by-step updates from any installed version to the current one, and uses **Jinja2 templates** for configuration files.

## Prerequisites

### Software

- **Docker** with the **Compose plugin** (`docker compose`)
- **j2cli** for Jinja2 templating: `pip install j2cli`
- **mkcert** + **libnss3-tools** (only for local development with self-signed certs)

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

Modules are installed in dependency order: **nginx** -> **auth** -> **nextcloud** -> then discourse, direktkredit, mediawiki, dokuwiki, mailtrain (in any order).

#### Remove

```bash
./habidat.sh remove <module>        # Remove a module (prompts for confirmation)
./habidat.sh remove <module> force  # Remove without confirmation
```

**Warning**: This removes all containers, volumes, and data for the module.

#### Update

```bash
./habidat.sh update <module>        # Update a single module
./habidat.sh update all             # Update all installed modules
./habidat.sh update <module> force  # Force re-run migrations even if up to date
```

Updates run versioned migrations step by step from the installed version to the target version. Each migration uses the correct templates and scripts for that specific version transition.

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
./habidat.sh import <module> <file> # Import module data from file
```

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
  lib/                    # Shared bash libraries
    common.sh             #   Logging, error handling, prerequisites
    template.sh           #   Jinja2/envsubst rendering, template resolution
    version.sh            #   Version comparison, migration runner
    modules.sh            #   Module discovery, lifecycle, dependency management
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

1. Compares installed vs. target version
2. Finds all migration directories between them (`versions/<ver>/migrate.sh`)
3. Runs each migration step by step, using the correct templates for each version
4. Updates `store/<module>/version` after each successful step

This means a user 3 versions behind will run 3 sequential migrations, each using the correct configuration templates for that transition. If a migration fails, the user can fix the issue and retry -- it will resume from where it left off.

### Template resolution

Templates are resolved per-version using a fallback strategy: if a template doesn't exist in `versions/<ver>/`, the system walks backwards through earlier versions to find the most recent one. This means you only need to add a template to a version directory when it actually changes.

### Jinja2 templating

Configuration and compose files use [j2cli](https://github.com/kolypto/j2cli) for Jinja2 templating. This supports conditionals, defaults, loops, and filters -- replacing the limited `envsubst` approach. All environment variables from `setup.env` are automatically available in templates.

## Development

### Adding a new module

1. Create a directory with the module name
2. Add a `version` file with the initial version (e.g. `0.0.1`)
3. Add a `dependencies` file listing required modules (one per line)
4. Create `setup.sh` for fresh installation
5. Create `docker-compose.yml.j2` and config templates in `config/`
6. Create `versions/<ver>/` with `migrate.sh` and versioned templates
7. Optionally add `export/<ver>.sh` and `import/<ver>.sh`

The module is automatically discovered by the CLI -- no changes to `habidat.sh` needed.

### Creating a new version

1. Bump the version in `<module>/version`
2. Create `versions/<new-ver>/migrate.sh` with the migration logic
3. If templates changed, add them to `versions/<new-ver>/` (unchanged templates are inherited from earlier versions)
4. If export/import behavior changed, add new scripts to `export/` and `import/`
5. Update the root `docker-compose.yml.j2` and `config/` to match the latest version

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
