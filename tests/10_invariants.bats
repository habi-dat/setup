#!/usr/bin/env bats
# Repository conventions.
#
# The CLI discovers everything from the filesystem: a directory is a module
# because it has a version file, a migration exists because versions/<v>/
# contains migrate.sh, a template belongs to a version because of where it
# sits. None of that is declared anywhere, so nothing enforces it -- a mistake
# surfaces as a failed install on a user's server. These tests are that
# enforcement.

load helpers/load

# ---------------------------------------------------------------------------
# Module layout
# ---------------------------------------------------------------------------

@test "the expected set of modules is present" {
  run bash -c "cd '$REPO_ROOT' && $(declare -f repo_modules); REPO_ROOT='$REPO_ROOT' repo_modules | sort"
  assert_success
  assert_output - <<'EOF'
auth
direktkredit
discourse
dokuwiki
mailtrain
mediawiki
nextcloud
nginx
EOF
}

@test "every module has an executable setup.sh" {
  local mod failures=()
  while IFS= read -r mod; do
    [[ -f "$REPO_ROOT/$mod/setup.sh" ]] || { failures+=("$mod: no setup.sh"); continue; }
    [[ -x "$REPO_ROOT/$mod/setup.sh" ]] || failures+=("$mod/setup.sh is not executable")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "setup.sh problems:" "${failures[@]}"
}

@test "every lifecycle script is executable" {
  # _run_lifecycle, remove_module and update_module invoke these as ./<action>.sh
  # from the module directory, so mode 644 means "Permission denied".
  #
  # Migration, export and import scripts are `source`d and do not need +x.
  local mod action failures=()
  while IFS= read -r mod; do
    for action in setup remove start stop restart up down pull build update; do
      [[ -f "$REPO_ROOT/$mod/$action.sh" ]] || continue
      [[ -x "$REPO_ROOT/$mod/$action.sh" ]] || failures+=("$mod/$action.sh")
    done
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] \
    || fail_with_list "lifecycle scripts missing the executable bit (git update-index --chmod=+x):" "${failures[@]}"
}

@test "git records the executable bit, not just the working tree" {
  # A chmod that never made it into the index looks fine locally and ships
  # broken. Check the mode git actually has.
  local mod action mode failures=()
  while IFS= read -r mod; do
    for action in setup remove start stop restart up down pull build update; do
      [[ -f "$REPO_ROOT/$mod/$action.sh" ]] || continue
      mode="$(git -C "$REPO_ROOT" ls-files -s "$mod/$action.sh" | awk '{print $1}')"
      # Untracked files have no recorded mode yet; the test above covers those.
      [[ -z "$mode" || "$mode" == "100755" ]] || failures+=("$mod/$action.sh is $mode in the index")
    done
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "wrong mode recorded in git:" "${failures[@]}"
}

@test "every shell script uses the portable env shebang" {
  # `#!/bin/bash` fails on any host without bash at that path -- NixOS, and some
  # minimal images. `#!/usr/bin/env bash` resolves bash through PATH.
  local script failures=() first
  while IFS= read -r script; do
    first="$(head -n1 "$REPO_ROOT/$script")"
    [[ "$first" == "#!/usr/bin/env bash" ]] || failures+=("$script: $first")
  done < <(repo_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "scripts without '#!/usr/bin/env bash':" "${failures[@]}"
}

@test "no script carries a second shebang line" {
  # A stray '#!/bin/bash' further down a file is dead but misleading, and hides
  # the real interpreter from a reader.
  local script failures=() extra
  while IFS= read -r script; do
    extra="$(tail -n +2 "$REPO_ROOT/$script" | grep -n '^#!' || true)"
    [[ -z "$extra" ]] || failures+=("$script: line $((${extra%%:*} + 1)): ${extra#*:}")
  done < <(repo_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "duplicate shebang lines:" "${failures[@]}"
}

@test "every module version is a valid version string" {
  # run_migrations rejects anything that does not match this pattern when it is
  # passed on the command line; the version files must satisfy it too.
  local mod version failures=()
  while IFS= read -r mod; do
    version="$(repo_module_version "$mod")"
    [[ "$version" =~ ^[0-9]+(\.[0-9A-Za-z_-]+)*$ ]] || failures+=("$mod: '$version'")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "invalid version strings:" "${failures[@]}"
}

@test "every module's version file is a single line with no trailing content" {
  local mod failures=()
  while IFS= read -r mod; do
    [[ "$(wc -l < "$REPO_ROOT/$mod/version")" -le 1 ]] || failures+=("$mod/version has multiple lines")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "malformed version files:" "${failures[@]}"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

@test "every declared dependency names an existing module" {
  local mod dep modules failures=()
  modules="$(repo_modules)"

  while IFS= read -r mod; do
    [[ -f "$REPO_ROOT/$mod/dependencies" ]] || continue
    while IFS= read -r dep; do
      dep="$(printf '%s' "$dep" | tr -d '[:space:]')"
      [[ -z "$dep" ]] && continue
      grep -qx "$dep" <<< "$modules" || failures+=("$mod depends on unknown module '$dep'")
    done < "$REPO_ROOT/$mod/dependencies"
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "dangling dependencies:" "${failures[@]}"
}

@test "no module depends on itself" {
  local mod failures=()
  while IFS= read -r mod; do
    [[ -f "$REPO_ROOT/$mod/dependencies" ]] || continue
    grep -qx "$mod" "$REPO_ROOT/$mod/dependencies" && failures+=("$mod")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "self-dependencies:" "${failures[@]}"
}

@test "the dependency graph is acyclic" {
  # get_ordered_modules() has no cycle detection: _topo_visit marks a module
  # visited on entry, so a cycle silently produces a wrong order rather than an
  # error. Detect it here instead.
  run python3 - "$REPO_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
mods = [d for d in os.listdir(root)
        if os.path.isfile(os.path.join(root, d, "version"))
        and d not in {"lib", "store", "scripts", "tests", "node_modules"}]
deps = {}
for m in mods:
    p = os.path.join(root, m, "dependencies")
    deps[m] = [l.strip() for l in open(p)] if os.path.exists(p) else []
    deps[m] = [d for d in deps[m] if d in mods]

state = {}
def visit(m, path):
    if state.get(m) == "done":
        return
    if state.get(m) == "open":
        print("cycle: " + " -> ".join(path + [m]))
        sys.exit(1)
    state[m] = "open"
    for d in deps[m]:
        visit(d, path + [m])
    state[m] = "done"

for m in sorted(mods):
    visit(m, [])
print("acyclic")
PY
  assert_success
  assert_output "acyclic"
}

@test "the README module table matches the dependencies on disk" {
  local mod declared documented failures=()

  while IFS= read -r mod; do
    declared="$(tr '\n' ' ' < "$REPO_ROOT/$mod/dependencies" 2>/dev/null | sed 's/ *$//')"
    # README rows look like: | **nginx** | Reverse proxy ... | none |
    documented="$(grep -E "^\| \*\*$mod\*\* \|" "$REPO_ROOT/README.md" \
      | awk -F'|' '{print $4}' | tr -d ' ' | tr ',' ' ' | sed 's/ *$//')"

    [[ -n "$documented" ]] || { failures+=("$mod: no row in the README module table"); continue; }
    [[ "$documented" == "none" ]] && documented=""

    local declared_sorted documented_sorted
    declared_sorted="$(tr ' ' '\n' <<< "$declared" | grep -v '^$' | sort | tr '\n' ' ')"
    documented_sorted="$(tr ' ' '\n' <<< "$documented" | grep -v '^$' | sort | tr '\n' ' ')"

    [[ "$declared_sorted" == "$documented_sorted" ]] \
      || failures+=("$mod: README says '$documented_sorted', dependencies file says '$declared_sorted'")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "README/dependencies mismatch:" "${failures[@]}"
}

# ---------------------------------------------------------------------------
# Versioned snapshots
# ---------------------------------------------------------------------------

@test "every version directory name is a valid version string" {
  local mod ver failures=()
  while IFS= read -r mod; do
    while IFS= read -r ver; do
      [[ "$ver" =~ ^[0-9]+(\.[0-9A-Za-z_-]+)*$ ]] || failures+=("$mod/versions/$ver")
    done < <(repo_version_dirs "$mod")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "invalid version directory names:" "${failures[@]}"
}

@test "no version directory is newer than its module's target version" {
  # resolve_template only considers versions <= the target, so a snapshot above
  # <module>/version is unreachable dead weight -- usually a forgotten bump.
  local mod ver target failures=()
  while IFS= read -r mod; do
    target="$(repo_module_version "$mod")"
    while IFS= read -r ver; do
      if [[ "$(printf '%s\n%s' "$ver" "$target" | sort -V | tail -n1)" != "$target" ]]; then
        failures+=("$mod: versions/$ver > version $target")
      fi
    done < <(repo_version_dirs "$mod")
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "unreachable version snapshots:" "${failures[@]}"
}

@test "each module's root templates match its newest versioned snapshot" {
  # <module>/*.j2 is what a fresh install renders; versions/<newest>/*.j2 is what
  # an upgrade to the current version renders. If they drift, a fresh install and
  # an upgraded install end up differently configured -- and the difference only
  # shows up in production.
  local mod newest rel root_tpl snap_tpl failures=()

  while IFS= read -r mod; do
    newest="$(repo_newest_version_dir "$mod")"
    [[ -n "$newest" ]] || continue

    while IFS= read -r snap_tpl; do
      rel="${snap_tpl#"$REPO_ROOT/$mod/versions/$newest/"}"
      root_tpl="$REPO_ROOT/$mod/$rel"

      if [[ ! -f "$root_tpl" ]]; then
        failures+=("$mod: versions/$newest/$rel has no counterpart at $mod/$rel")
      elif ! cmp -s "$root_tpl" "$snap_tpl"; then
        failures+=("$mod: $mod/$rel differs from versions/$newest/$rel")
      fi
    done < <(find "$REPO_ROOT/$mod/versions/$newest" -name '*.j2' -type f | sort)
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "root templates out of sync with the newest snapshot:" "${failures[@]}"
}

@test "known template drift between root and versioned snapshots is exactly as recorded" {
  # The mirror image of the test above: a root template with no counterpart in
  # any version snapshot is never used by an upgrade, so changes to it reach only
  # fresh installs.
  #
  # RATCHET. Each entry is a config template that only a fresh install ever
  # renders, because no migrate.sh renders it and the newest version directory
  # has no snapshot of it. Editing one of these files therefore changes new
  # installations but leaves every upgraded installation untouched.
  #
  # Two flavours:
  #   - nextcloud: versions/32.0.5/config/ snapshots exist but have since
  #     diverged from the root copies (notably default("") there vs
  #     default(none) at the root), and no later version re-snapshotted them.
  #   - direktkredit, discourse, mailtrain, mediawiki, auth's appStore: no
  #     versioned config snapshot has ever been taken.
  #
  # Adding the templates to the newest version directory and rendering them from
  # that module's migrate.sh removes entries from this list.
  local known=(
    "auth/config/appStore.json.j2"
    "direktkredit/config/settings.env.j2"
    "discourse/config/discourse-settings.yml.j2"
    "discourse/templates/discourse-data.yml.j2"
    "discourse/templates/discourse.yml.j2"
    "mailtrain/config/db.env.j2"
    "mailtrain/config/local-production.yaml.j2"
    "mailtrain/config/mailtrain.env.j2"
    "mailtrain/config/public.env.j2"
    "mailtrain/config/sandbox.env.j2"
    "mediawiki/config/db.env.j2"
    "mediawiki/config/web.env.j2"
    "nextcloud/config/db.env.j2"
    "nextcloud/config/nextcloud.env.j2"
  )

  local mod newest rel found=()
  while IFS= read -r mod; do
    newest="$(repo_newest_version_dir "$mod")"
    [[ -n "$newest" ]] || continue

    while IFS= read -r root_tpl; do
      rel="${root_tpl#"$REPO_ROOT/$mod/"}"
      [[ "$rel" == versions/* ]] && continue
      [[ -f "$REPO_ROOT/$mod/versions/$newest/$rel" ]] || found+=("$mod/$rel")
    done < <(find "$REPO_ROOT/$mod" -name '*.j2' -type f -not -path '*/versions/*' | sort)
  done < <(repo_modules)

  assert_equal "$(printf '%s\n' "${found[@]}" | sort)" "$(printf '%s\n' "${known[@]}" | sort)"
}

@test "modules without a migrate.sh for their current version are exactly the known ones" {
  # A module whose newest version directory has no migrate.sh cannot be updated:
  # `update` finds no step, bumps store/<module>/version and re-renders nothing.
  #
  # RATCHET. discourse is legitimate -- it ships a custom update.sh instead.
  # dokuwiki is not: versions/0.0.1/ holds templates but no migration, so
  # `update dokuwiki` silently does nothing but move the marker.
  local known=(
    discourse
    dokuwiki
  )

  local mod newest found=()
  while IFS= read -r mod; do
    newest="$(repo_newest_version_dir "$mod")"
    if [[ -z "$newest" ]] || [[ ! -f "$REPO_ROOT/$mod/versions/$newest/migrate.sh" ]]; then
      found+=("$mod")
    fi
  done < <(repo_modules)

  assert_equal "$(printf '%s\n' "${found[@]}")" "$(printf '%s\n' "${known[@]}")"
}

@test "modules whose version has no matching snapshot directory are exactly the known ones" {
  # RATCHET. discourse/version is 3.3.3 but versions/ only holds 3.3.2, so
  # resolve_template silently serves 3.3.2 templates for 3.3.3.
  local known=(discourse)

  local mod newest found=()
  while IFS= read -r mod; do
    newest="$(repo_newest_version_dir "$mod")"
    [[ "$newest" == "$(repo_module_version "$mod")" ]] || found+=("$mod: version $(repo_module_version "$mod"), newest snapshot ${newest:-none}")
  done < <(repo_modules)

  assert_equal "$(printf '%s\n' "${found[@]}" | cut -d: -f1)" "$(printf '%s\n' "${known[@]}")"
}

# ---------------------------------------------------------------------------
# Export / import scripts
# ---------------------------------------------------------------------------

@test "every export/import script is named after a valid version" {
  local mod kind f ver failures=()
  while IFS= read -r mod; do
    for kind in export import; do
      [[ -d "$REPO_ROOT/$mod/$kind" ]] || continue
      for f in "$REPO_ROOT/$mod/$kind"/*.sh; do
        [[ -f "$f" ]] || continue
        ver="$(basename "$f" .sh)"
        [[ "$ver" =~ ^[0-9]+(\.[0-9A-Za-z_-]+)*$ ]] || failures+=("$mod/$kind/$(basename "$f")")
      done
    done
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "export/import scripts not named after a version:" "${failures[@]}"
}

@test "no export/import script is newer than its module's version" {
  # resolve_versioned_script picks the highest script <= the installed version,
  # so a script above <module>/version can never be selected.
  local mod kind f ver target failures=()
  while IFS= read -r mod; do
    target="$(repo_module_version "$mod")"
    for kind in export import; do
      [[ -d "$REPO_ROOT/$mod/$kind" ]] || continue
      for f in "$REPO_ROOT/$mod/$kind"/*.sh; do
        [[ -f "$f" ]] || continue
        ver="$(basename "$f" .sh)"
        if [[ "$(printf '%s\n%s' "$ver" "$target" | sort -V | tail -n1)" != "$target" ]]; then
          failures+=("$mod/$kind/$ver.sh > version $target")
        fi
      done
    done
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "unreachable export/import scripts:" "${failures[@]}"
}

@test "every module with an export script has a matching import script" {
  local mod f ver failures=()
  while IFS= read -r mod; do
    [[ -d "$REPO_ROOT/$mod/export" ]] || continue
    for f in "$REPO_ROOT/$mod/export"/*.sh; do
      [[ -f "$f" ]] || continue
      ver="$(basename "$f" .sh)"
      [[ -f "$REPO_ROOT/$mod/import/$ver.sh" ]] \
        || failures+=("$mod/export/$ver.sh has no import/$ver.sh")
    done
  done < <(repo_modules)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "export scripts without an import counterpart:" "${failures[@]}"
}

@test "the README lists exactly the modules that support export and import" {
  local mod supported=()
  while IFS= read -r mod; do
    [[ -d "$REPO_ROOT/$mod/export" ]] && supported+=("$mod")
  done < <(repo_modules)

  local documented
  documented="$(grep -oE 'Modules with export/import support: .*' "$REPO_ROOT/README.md" \
    | sed 's/.*support: //' | tr -d '*.' | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort)"

  assert_equal "$documented" "$(printf '%s\n' "${supported[@]}" | sort)"
}

# ---------------------------------------------------------------------------
# Configuration surface
# ---------------------------------------------------------------------------

@test "setup.env.example defines every key the test profiles define, and vice versa" {
  # The profiles stand in for a user's setup.env. If they drift from the example,
  # the render tier stops testing the configuration users actually write.
  local profile
  for profile in dev prod existing-net; do
    run bash -c "
      diff <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' '$REPO_ROOT/setup.env.example' | sort -u) \
           <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' '$BATS_TEST_DIRNAME/helpers/profiles/$profile.env' | sort -u)
    "
    if [[ "$status" -ne 0 ]]; then
      {
        echo "profile $profile has a different key set than setup.env.example"
        echo "(< only in setup.env.example, > only in the profile)"
        printf '%s\n' "$output"
      } | fail
    fi
  done
}

@test "every variable a template reads is either configured, generated or defaulted" {
  # Rendering uses StrictUndefined, so an unprovided variable aborts the install.
  # This catches a misspelled name at review time instead.
  run python3 - "$REPO_ROOT" "$BATS_TEST_DIRNAME/helpers/render.bash" <<'PY'
import re, sys, pathlib

repo = pathlib.Path(sys.argv[1])
render_helper = pathlib.Path(sys.argv[2]).read_text()

# Variables the test suite declares as generated at install time.
runtime = set(re.findall(r'"(HABIDAT_[A-Z0-9_]+)=', render_helper))
# Variables a user sets in setup.env.
configured = set(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*)=',
                            (repo / "setup.env.example").read_text(), re.M))

expr = re.compile(r'\{\{(.*?)\}\}|\{%(.*?)%\}', re.S)
raw = re.compile(r'\{%\s*raw\s*%\}.*?\{%\s*endraw\s*%\}', re.S)
ident = re.compile(r'\b(HABIDAT_[A-Z0-9_]+)\b')

problems = []
for path in sorted(repo.rglob("*.j2")):
    if "node_modules" in path.parts or "tests" in path.parts:
        continue
    text = raw.sub("", path.read_text())
    for match in expr.finditer(text):
        fragment = match.group(1) or match.group(2) or ""
        # A default() anywhere in the expression makes it safe.
        if "default(" in fragment:
            continue
        for name in ident.findall(fragment):
            if name not in runtime and name not in configured:
                problems.append(f"{path.relative_to(repo)}: {name}")

for p in sorted(set(problems)):
    print(p)
PY
  assert_success
  assert_output ""
}

@test "no template reads a variable that nothing in the repository ever sets" {
  # Complements the test above by catching the opposite drift: a variable that is
  # only ever read, never written -- dead configuration surface that looks live.
  #
  # RATCHET.
  #   HABIDAT_EMAIL         read by discourse/config/discourse-settings.yml.j2,
  #                         which falls back to HABIDAT_ADMIN_EMAIL. Either
  #                         document it in setup.env.example or drop it.
  #   HABIDAT_WIKI_SUBDOMAIN predates HABIDAT_MEDIAWIKI_SUBDOMAIN and is read by
  #                         nextcloud/config/nextcloud.env.j2 but set by nothing,
  #                         so it always renders as its default -- which is
  #                         default(none), i.e. the string "None".
  local known=(
    HABIDAT_EMAIL
    HABIDAT_WIKI_SUBDOMAIN
  )

  run python3 - "$REPO_ROOT" "$BATS_TEST_DIRNAME/helpers/render.bash" <<'PY'
import re, sys, pathlib

repo = pathlib.Path(sys.argv[1])
render_helper = pathlib.Path(sys.argv[2]).read_text()

runtime = set(re.findall(r'"(HABIDAT_[A-Z0-9_]+)=', render_helper))
configured = set(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*)=',
                            (repo / "setup.env.example").read_text(), re.M))

# Anything assigned or exported by a shell script in the repository.
assigned = set()
for path in repo.rglob("*.sh"):
    if "node_modules" in path.parts or "tests" in path.parts:
        continue
    text = path.read_text(errors="replace")
    assigned |= set(re.findall(r'^\s*(?:export\s+)?(HABIDAT_[A-Z0-9_]+)=', text, re.M))
    assigned |= set(re.findall(r'^\s*export\s+(HABIDAT_[A-Z0-9_]+)\b', text, re.M))

expr = re.compile(r'\{\{(.*?)\}\}|\{%(.*?)%\}', re.S)
raw = re.compile(r'\{%\s*raw\s*%\}.*?\{%\s*endraw\s*%\}', re.S)
ident = re.compile(r'\b(HABIDAT_[A-Z0-9_]+)\b')

read = set()
for path in sorted(repo.rglob("*.j2")):
    if "node_modules" in path.parts or "tests" in path.parts:
        continue
    text = raw.sub("", path.read_text())
    for match in expr.finditer(text):
        read |= set(ident.findall(match.group(1) or match.group(2) or ""))

for name in sorted(read - configured - assigned - runtime):
    print(name)
PY
  assert_success
  assert_equal "$output" "$(printf '%s\n' "${known[@]}")"
}

# ---------------------------------------------------------------------------
# Cross-module file references
# ---------------------------------------------------------------------------

@test "the SSO certificate path modules read is the one auth/setup.sh writes" {
  # auth/setup.sh generates the SAML certificate at store/auth/cert/saml/cert.cer
  # and every consumer must agree on that path.
  #
  # RATCHET. mediawiki/setup.sh reads ../store/auth/cert/server.cert instead,
  # inside its `if [[ "${HABIDAT_SSO:-false}" == "true" ]]` branch. The branch is
  # unreachable today only because nothing sets HABIDAT_SSO in the shell -- it is
  # set exclusively inside container env files (nextcloud.env, web.env) -- so
  # turning SSO on would fail at that line.
  local known=("mediawiki/setup.sh: ../store/auth/cert/server.cert")

  run grep -q 'store/auth/cert/saml/cert.cer' "$REPO_ROOT/auth/setup.sh"
  assert_success

  local script found=()
  while IFS= read -r script; do
    [[ "$script" == auth/setup.sh ]] && continue
    local bad
    bad="$(grep -oE '\.\./store/auth/cert/[A-Za-z0-9_./-]+' "$REPO_ROOT/$script" \
      | grep -v '^\.\./store/auth/cert/saml/' | sort -u)"
    [[ -n "$bad" ]] && found+=("$script: $bad")
  done < <(repo_scripts)

  assert_equal "$(printf '%s\n' "${found[@]}")" "$(printf '%s\n' "${known[@]}")"
}
