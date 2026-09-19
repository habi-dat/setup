# Test suite

```bash
nix develop              # bats, shellcheck, python+jinja2, docker CLI, ...
./tests/run.sh           # everything (~100s)
./tests/run.sh 20        # one tier
./tests/run.sh --filter 'resolve_' 21
./tests/run.sh --list
```

Without Nix: `npm install && npm test`, plus `apt install python3-jinja2` for the
renderer. The static tier then skips (no shellcheck) and so does compose
validation if the docker CLI is absent.

Nothing in tiers 0-4 contacts a Docker daemon, writes to the repository, or
touches your real `store/` or `setup.env`.

## Tiers

| File | What it covers |
| ---- | -------------- |
| `00_static.bats` | `bash -n` on every script; shellcheck at error severity repo-wide and at warning severity for `habidat.sh` and `lib/`; hygiene (no committed credentials, no hardcoded home directories) |
| `10_invariants.bats` | The filesystem conventions the CLI infers everything from: module layout, executable bits, version-string shapes, the dependency graph, root-vs-snapshot template parity, export/import naming, and that the README matches the tree |
| `20_version.bats` | `lib/version.sh` — version comparison and `resolve_versioned_script` |
| `21_template.bats` | `lib/template.sh` — version-aware template resolution and rendering |
| `22_modules.bats` | `lib/modules.sh` — module discovery and the topological install order |
| `23_render_py.bats` | `lib/render.py` — StrictUndefined, `{% raw %}` passthrough, no HTML escaping, error reporting |
| `30_render.bats` | Every `.j2` rendered under three configuration profiles, each rendered compose file validated by `docker compose config` |
| `40_cli.bats` | The CLI end to end in a throwaway copy of the repository, with a recording `docker` stub |

Integration testing against real containers lives in the `integration` job of
`.github/workflows/ci.yml`. It installs nginx, auth and nextcloud for real and
round-trips an auth export, and runs nightly (03:17 UTC) or on demand rather than
gating pull requests. Discourse is out of scope there: `launcher rebuild` takes
tens of minutes and several GB.

Both of its triggers only fire for a workflow on the default branch, so to
exercise it from a feature branch add `|| github.ref_name == '<branch>'` to the
job's `if:` temporarily.

## How the harness works

**`helpers/sandbox.bash`** — `habidat.sh` derives `BASE_DIR` from its own
location, so a throwaway copy of the tree is a complete isolated installation.
`new_sandbox` clones a prepared copy, drops in one of
`helpers/profiles/*.env` as `setup.env`, and puts `helpers/stub/docker` first on
`PATH`. The stub logs every invocation, so tests assert on the exact commands
the CLI emits.

Module directories are copied, never symlinked: the CLI does
`cd "$BASE_DIR/$module" && ./setup.sh`, and a child process inherits the
*physical* cwd — through a symlink, a script's own `../store/...` writes would
land in the real repository.

**`helpers/lib.bash`** — `lib/common.sh` sets `set -euo pipefail`, rewrites
`IFS` and installs an EXIT trap, so it must never be sourced into the test
shell. `lib_eval` runs each call in a fresh `bash` with `BASE_DIR` pointed at a
fixture tree, which also means every case runs under the exact shell options
production code uses. (`BASE_DIR` honours a pre-set value; that one-line change
in `lib/common.sh` exists for this.)

**`helpers/render.bash`** — `lib/render.py` renders with `StrictUndefined`, so a
template reading an unprovided variable is a hard failure at install time,
possibly halfway through a migration. `render_setup_file` renders all templates ×
3 profiles once per `.bats` file (in parallel, via `helpers/render_all.sh`) and
the tests read that cache.

A render needs two things: a `setup.env` (one of the profiles) and the variables
the install generates at run time — passwords, network names, per-instance
arguments. The latter live in `RUNTIME_VARS` in `helpers/render.bash`, annotated
with which script sets each one. When a template starts reading something new,
either `setup.env.example` gains a key or `RUNTIME_VARS` does, and
`10_invariants.bats` fails until one of them happens.

## Profiles

| Profile | Represents |
| ------- | ---------- |
| `dev` | Local development: `habidat.localhost`, mkcert self-signed certs, mailhog, LDAP unexposed |
| `prod` | Production: `example.org`, Let's Encrypt, authenticated SMTP, LDAP bound to `127.0.0.1` |
| `existing-net` | Attaching to an externally managed nginx proxy and backend network |

An invariant test asserts all three define exactly the key set of
`setup.env.example`, so they cannot drift from the configuration users write.

## Ratchets

Several tests assert that a set of known problems is *exactly* what it is today,
rather than asserting the problem is absent. Each is marked `RATCHET` with the
reason and what to change. They keep CI green on the current tree while making
any new instance fail, and they shrink as the underlying issues are fixed.

Current ratchets:

- `00_static.bats` — warning-level shellcheck findings in module scripts, held
  at `baseline/shellcheck-warnings.txt`. Regenerate with
  `./tests/run.sh --update-baseline`.
- `10_invariants.bats` — config templates that only a fresh install renders;
  modules whose newest version has no `migrate.sh`; `discourse/version` having no
  matching snapshot; template variables nothing ever sets; the mediawiki SSO
  certificate path.
- `30_render.bats` — compose templates still using `external: {name: …}`; env
  values rendering as the literal string `None`.

Two ratchets have since been retired, and the tests that replaced them are
regression tests for the fixes. Keep them:

- A failing migration used to be reported as a success by `update all`, which
  advanced `store/<module>/version` over a half-applied migration. Fixed by
  `run_module_script`, which runs each migration in its own process so its
  `set -euo pipefail` cannot be suppressed by the caller's errexit-ignored
  context. Covered in `40_cli.bats`.
- Lifecycle scripts for discourse and mediawiki were committed mode 644 and
  `_run_lifecycle` never checked the exit status, so `start all` truncated at the
  first broken module. Fixed by the file modes, an executability guard, an exit
  code check, and continue-on-error in `dispatch`. Covered in `10_invariants.bats`
  and `40_cli.bats`.

## Adding tests

Start every `.bats` file with `load helpers/load`; it resolves the bats helper
libraries from Nix or npm and pulls in the habidat helpers.

For a new CLI case, add `setup_file() { sandbox_setup_file; }` and
`setup() { new_sandbox dev; }`, then use `habidat <args>` (which wraps bats'
`run`, strips the log prefix, and points the CLI at the sandbox) plus
`seed_module <module> <version>` to fake an installation.

For a unit test of a `lib/` function, use `lib_eval '<code>' [base_dir]`. The
default base directory is `fixtures/modules`, a synthetic tree built to exercise
template resolution: `alpha` has snapshots at 1.0.0-4.0.0 where 2.0.0 carries
only a migration (so templates are inherited), 4.0.0 is above the target (so it
must never be selected), and `beta`/`gamma`/`delta` form the dependency graph.
