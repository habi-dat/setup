#!/usr/bin/env bats
# Static analysis of every shell script in the repository.
#
# Two gates:
#   - bash -n on everything: a syntax error in a migrate.sh is only otherwise
#     discovered partway through a user's upgrade.
#   - shellcheck at error severity on everything, and at warning severity on the
#     CLI and lib/ where correctness matters most. Module scripts still carry
#     warning-level findings, so those are held at a recorded baseline that can
#     shrink but not grow.

load helpers/load

# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------

@test "every shell script parses" {
  local script failures=()

  while IFS= read -r script; do
    run bash -n "$REPO_ROOT/$script"
    [[ "$status" -eq 0 ]] || failures+=("$script: $output")
  done < <(repo_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "scripts with syntax errors:" "${failures[@]}"
}

@test "every test helper parses" {
  local script failures=()

  while IFS= read -r script; do
    run bash -n "$REPO_ROOT/$script"
    [[ "$status" -eq 0 ]] || failures+=("$script: $output")
  done < <(repo_test_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "test helpers with syntax errors:" "${failures[@]}"
}

@test "shellcheck reports no warning-level findings in the test helpers" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  # SC2154 is expected throughout: `output`, `status`, `lines` and `stderr` are
  # set by bats' own `run`, which shellcheck cannot see.
  run bash -c "cd '$REPO_ROOT' && shellcheck -x -s bash -S warning -e SC2154 -f gcc \$(
    find tests -type f \\( -name '*.sh' -o -name '*.bash' \\) | sort
  ) 2>&1"

  if [[ "$status" -ne 0 ]]; then
    { echo "shellcheck findings in the test helpers:"; printf '%s\n' "$output"; } | fail
  fi
}

# ---------------------------------------------------------------------------
# shellcheck
# ---------------------------------------------------------------------------

@test "shellcheck reports no error-level findings anywhere" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  run bash -c "cd '$REPO_ROOT' && shellcheck -x -s bash -S error -f gcc \$(
    find . -name '*.sh' -type f -not -path './node_modules/*' -not -path './store/*'
  ) 2>&1"

  if [[ "$status" -ne 0 ]]; then
    { echo "shellcheck error-level findings:"; printf '%s\n' "$output"; } | fail
  fi
}

@test "shellcheck reports no warning-level findings in habidat.sh or lib/" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  run bash -c "cd '$REPO_ROOT' && shellcheck -x -s bash -S warning -f gcc habidat.sh lib/*.sh 2>&1"

  if [[ "$status" -ne 0 ]]; then
    { echo "shellcheck findings in the CLI core:"; printf '%s\n' "$output"; } | fail
  fi
}

@test "warning-level findings in module scripts have not grown" {
  # A ratchet rather than a wall: the existing findings are almost entirely
  # SC2155 (declare-and-assign) in the password-generation blocks, which is not
  # worth churning production scripts over right now. New ones should still be
  # caught.
  #
  # Regenerate with: ./tests/run.sh --update-baseline
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  local baseline="$BATS_TEST_DIRNAME/baseline/shellcheck-warnings.txt"
  assert [ -f "$baseline" ]

  run bash -c "cd '$REPO_ROOT' && '$BATS_TEST_DIRNAME/helpers/shellcheck_warnings.sh'"
  assert_success

  local current="$BATS_TEST_TMPDIR/current.txt"
  printf '%s\n' "$output" > "$current"

  run diff -u "$baseline" "$current"
  if [[ "$status" -ne 0 ]]; then
    {
      echo "shellcheck warning set changed (- baseline, + current)."
      echo "New findings must be fixed; if you fixed some, run:"
      echo "  ./tests/run.sh --update-baseline"
      printf '%s\n' "$output"
    } | fail
  fi
}

# ---------------------------------------------------------------------------
# Hygiene
# ---------------------------------------------------------------------------

@test "no script hardcodes a developer's absolute path" {
  local script failures=() hits

  while IFS= read -r script; do
    hits="$(grep -nE '(/home/[a-z]+/|/Users/[a-z]+/)' "$REPO_ROOT/$script" || true)"
    [[ -n "$hits" ]] && failures+=("$script: $hits")
  done < <(repo_scripts)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "hardcoded absolute paths:" "${failures[@]}"
}

@test "setup.env.example carries no credential values" {
  # setup.env is gitignored, but the example ships in the repository. The only
  # permitted values for a secret are empty or the literal "generate" sentinel.
  local line key value
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]*(PASSWORD|SECRET|API_KEY|TOKEN))=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[3]}"
    # Drop a trailing inline comment and surrounding whitespace/quotes.
    value="${value%%#*}"
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/')"

    [[ -z "$value" || "$value" == "generate" ]] \
      || fail "setup.env.example sets $key to a literal value: '$value'"
  done < "$REPO_ROOT/setup.env.example"
}

@test "setup.env is not tracked by git" {
  run git -C "$REPO_ROOT" ls-files --error-unmatch setup.env
  assert_failure
}

@test ".gitignore covers the runtime state directories" {
  # Asserted through git itself rather than by grepping the file, so the rules
  # can be rewritten as long as the intent holds.
  local path
  for path in store backup setup.env; do
    run git -C "$REPO_ROOT" check-ignore -q "$path"
    assert_success
  done

  # ...and the example config must stay shippable.
  run git -C "$REPO_ROOT" check-ignore -q setup.env.example
  assert_failure
}

# ---------------------------------------------------------------------------
# GitHub Actions workflows
# ---------------------------------------------------------------------------

@test "every workflow file is valid YAML" {
  # A broken workflow is only reported by GitHub after a push, and the error it
  # gives is a bare line number. Catch it here instead.
  #
  # The trap that produced this test: a `run:` written as an unquoted multi-line
  # scalar containing ": ", which YAML reads as a mapping key. Use a block
  # scalar (`run: |`) for anything multi-line.
  command -v yq >/dev/null || skip "yq not installed"

  local workflow failures=()
  while IFS= read -r workflow; do
    run yq -e 'true' "$workflow"
    [[ "$status" -eq 0 ]] || failures+=("$workflow: $(printf '%s' "$output" | head -2 | tr '\n' ' ')")
  done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "invalid workflow YAML:" "${failures[@]}"
}

@test "the CI workflow runs the test suite the same way a developer does" {
  # Guards against CI drifting from tests/run.sh, which would let the suite pass
  # locally and be skipped or invoked differently in CI.
  command -v yq >/dev/null || skip "yq not installed"

  run yq -e '.jobs.test.steps[] | select(.name == "Run the test suite") | .run' \
    "$REPO_ROOT/.github/workflows/ci.yml"
  assert_success
  assert_output --partial "./tests/run.sh"

  run yq -e '.jobs["test-npm"].steps[] | select(.name == "Run the test suite") | .run' \
    "$REPO_ROOT/.github/workflows/ci.yml"
  assert_success
  assert_output --partial "./tests/run.sh"
}

@test "no workflow step uses a multi-line plain scalar for run:" {
  # The specific syntax error this suite was taught by: `run:` followed by more
  # lines without a block scalar marker. Anything multi-line must use `run: |`.
  local workflow failures=()
  while IFS= read -r workflow; do
    # A run: whose value starts on the same line and is not a block scalar,
    # followed by a more-indented continuation line, is the broken shape.
    local n=0 prev_run_indent=-1 line indent
    while IFS= read -r line; do
      n=$((n + 1))
      if [[ "$line" =~ ^([[:space:]]*)run:[[:space:]]+[^|\>] ]]; then
        prev_run_indent=${#BASH_REMATCH[1]}
        continue
      fi
      if [[ "$prev_run_indent" -ge 0 ]]; then
        if [[ "$line" =~ ^([[:space:]]*)[^[:space:]] ]]; then
          indent=${#BASH_REMATCH[1]}
          [[ "$indent" -gt "$prev_run_indent" ]] \
            && failures+=("${workflow#"$REPO_ROOT/"} line $n: continuation of a plain 'run:' scalar")
        fi
        prev_run_indent=-1
      fi
    done < "$workflow"
  done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "multi-line plain 'run:' scalars (use 'run: |'):" "${failures[@]}"
}

@test "every file the suite needs is tracked by git" {
  # The bug this exists for: tests/fixtures/modules/store/alpha/version was
  # matched by an unanchored `store` rule in .gitignore, so it lived on disk,
  # passed locally, and was never committed -- five tests then failed only in CI.
  #
  # Anything under tests/ that git does not track is either an oversight or a
  # .gitignore rule reaching further than intended.
  local file untracked=()

  while IFS= read -r file; do
    git -C "$REPO_ROOT" ls-files --error-unmatch "$file" >/dev/null 2>&1 \
      || untracked+=("$file $(git -C "$REPO_ROOT" check-ignore -v "$file" 2>/dev/null || echo '(untracked)')")
  done < <(cd "$REPO_ROOT" && find tests -type f | sort)

  [[ ${#untracked[@]} -eq 0 ]] \
    || fail_with_list "files under tests/ that git will not ship:" "${untracked[@]}"
}

@test "gitignore rules for runtime state are anchored to the repository root" {
  # `store` without a leading slash matches a directory of that name at any
  # depth. Anchoring keeps it meaning "the runtime state directory here".
  local rule failures=()
  while IFS= read -r rule; do
    [[ -z "$rule" || "$rule" == \#* ]] && continue
    case "$rule" in
      store | backup | setup.env | setup.env.*)
        failures+=("$rule should be anchored as /$rule")
        ;;
    esac
  done < "$REPO_ROOT/.gitignore"

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "unanchored .gitignore rules:" "${failures[@]}"
}

@test "every workflow action is pinned to a version, not a moving branch" {
  # `uses: owner/action@main` runs whatever that branch holds at the time, which
  # is both unreproducible and a supply-chain risk. Require a tag or a SHA.
  local workflow failures=() ref
  while IFS= read -r workflow; do
    while IFS= read -r ref; do
      [[ "$ref" =~ @(v[0-9]+([.0-9]*)?|[0-9a-f]{40})$ ]] \
        || failures+=("${workflow#"$REPO_ROOT/"}: $ref")
    done < <(grep -oE 'uses:[[:space:]]*[^[:space:]]+' "$workflow" | sed 's/uses:[[:space:]]*//')
  done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null)

  [[ ${#failures[@]} -eq 0 ]] || fail_with_list "unpinned workflow actions:" "${failures[@]}"
}

@test "Mailtrain importer maps subscription statuses without re-subscribing" {
  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.map_status("1", None) == "confirmed"
assert mod.map_status("1", "0") == "unconfirmed"
assert mod.map_status("2", None) == "unsubscribed"
assert mod.map_status("3", None) == "unsubscribed"
assert mod.map_status("4", None) == "unsubscribed"
for raw in ("0", "5", "99"):
    try:
        mod.map_status(raw, None)
    except mod.ImportError:
        pass
    else:
        raise SystemExit(f"status {raw} must abort")
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "Mailtrain SMTP send configurations map onto Listmonk servers" {
  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

rows = [
    {
        "id": 1,
        "name": "System",
        "mailer_type": "zone_mta",
        "from_email": "admin@example.com",
        "settings": {"zoneMtaType": 3, "hostname": "127.0.0.1", "port": 25},
    },
    {
        "id": 2,
        "name": "SES",
        "mailer_type": "aws_ses",
        "from_email": "ses@example.com",
        "settings": {"key": "k", "secret": "s", "region": "eu-central-1"},
    },
    {
        "id": 3,
        "name": "Office",
        "mailer_type": "generic_smtp",
        "from_email": "news@example.org",
        "settings": {
            "hostname": "smtp.example.org",
            "port": "587",
            "encryption": "STARTTLS",
            "useAuth": True,
            "user": "mailer",
            "password": "secret",
            "allowSelfSigned": False,
            "maxConnections": 4,
        },
    },
    {
        "id": 4,
        "name": "Relay",
        "mailer_type": "zone_mta",
        "from_email": "relay@example.org",
        "settings": {
            "zoneMtaType": 0,
            "hostname": "relay.example.org",
            "port": 465,
            "encryption": "tls",
            "useAuth": False,
            "allowSelfSigned": True,
        },
    },
]
servers = mod.usable_smtp_servers(rows, {4: 3, 3: 1})
assert [item["name"] for item in servers] == ["Relay", "Office"], servers
relay, office = servers
assert relay["host"] == "relay.example.org"
assert relay["port"] == 465
assert relay["tls_type"] == "TLS"
assert relay["auth_protocol"] == "none"
assert relay["username"] == "" and relay["password"] == ""
assert relay["tls_skip_verify"] is True
assert relay["list_count"] == 3
assert office["tls_type"] == "STARTTLS"
assert office["auth_protocol"] == "plain"
assert office["username"] == "mailer" and office["password"] == "secret"
assert office["max_conns"] == 4
assert office["hourly_limit"] == 0
entry = mod.listmonk_smtp_entry(office)
assert entry["msg_retry_delay"] == "10ms"
assert entry["from_addresses"] == ["news@example.org"]
assert mod.mailtrain_config_to_smtp({"id": 9, "mailer_type": "generic_smtp", "settings": {}}) is None
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "Mailtrain hourly throttling becomes a Listmonk send pace" {
  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

slow = mod.listmonk_throttle_settings(100)
assert slow["app.message_sliding_window"] is True
assert slow["app.message_sliding_window_duration"] == "36s"
assert slow["app.message_sliding_window_rate"] == 1
assert slow["app.concurrency"] == 1 and slow["app.message_rate"] == 1

fast = mod.listmonk_throttle_settings(10000)
assert fast["app.message_sliding_window_duration"] == "1h"
assert fast["app.message_sliding_window_rate"] == 10000
assert fast["app.concurrency"] == 1 and fast["app.message_rate"] == 2

now = datetime(2026, 10, 2, tzinfo=timezone.utc)
start = int(datetime(2026, 9, 27, tzinfo=timezone.utc).timestamp() * 1000)
configured, current = mod.mailtrain_hourly_limit(
    {"throttling": "200", "throttlingWarmUpDays": "10", "throttlingWarmUpFrom": start},
    now,
)
assert (configured, current) == (200, 100), (configured, current)
done, full = mod.mailtrain_hourly_limit(
    {"throttling": 200, "throttlingWarmUpDays": 10, "throttlingWarmUpFrom": start},
    datetime(2026, 10, 20, tzinfo=timezone.utc),
)
assert (done, full) == (200, 200)
assert mod.mailtrain_hourly_limit({"throttling": ""}) == (0, 0)
assert mod.mailtrain_hourly_limit({"throttling": 0}) == (0, 0)

row = {
    "id": 3,
    "name": "Office",
    "mailer_type": "generic_smtp",
    "from_email": "news@example.org",
    "settings": {
        "hostname": "smtp.example.org",
        "port": 587,
        "encryption": "STARTTLS",
        "throttling": 100,
        "enableSenderOnDaySun": False,
        "enableSenderOnDaySat": False,
    },
}
server = mod.mailtrain_config_to_smtp(row)
assert server["hourly_limit"] == 100
assert server["weekdays_limited"] is True
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "Mailtrain importer counts GDPR-wiped unsubscribes instead of importing them" {
  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
from collections import Counter
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
rows = [
    ("", "2", None),
    ("NULL", "4", None),
    ("a@b.c", "2", None),
    ("a@b.c", "3", None),
    ("", "3", None),
    ("a@b.c", "1", None),
    ("a@b.c", "1", "0"),
]
counts = Counter(mod.bucket_subscription(email, status, flag) for email, status, flag in rows)
assert counts["wiped"] == 2, counts
assert counts["unsubscribed"] == 2, counts
assert counts["skip"] == 1, counts
assert counts["confirmed"] == 1, counts
assert counts["unconfirmed"] == 1, counts
for raw in ("0", "5"):
    try:
        mod.bucket_subscription("a@b.c", raw, None)
    except mod.ImportError:
        pass
    else:
        raise SystemExit(f"status {raw} must abort")
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "Listmonk import wait accepts only a finished job" {
  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

try:
    mod.require_import_started("none")
except mod.ImportError:
    pass
else:
    raise SystemExit("none after POST must fail")
mod.require_import_started("importing")
mod.require_import_started("finished")

clock = {"t": 0}
def time_fn():
    return clock["t"]
def sleep_fn(_n):
    clock["t"] += 1
seen = iter([{"status": "importing"}, {"status": "finished"}])
got = mod.wait_import(lambda: next(seen), sleep_fn=sleep_fn, time_fn=time_fn, timeout=10)
assert got["status"] == "finished"

try:
    mod.wait_import(lambda: {"status": "none"}, sleep_fn=lambda _n: None, time_fn=lambda: 0, timeout=10)
except mod.ImportError:
    pass
else:
    raise SystemExit("none during wait must fail")
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "unsubscribe lookup URL is safe for curl" {
  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
from urllib.parse import parse_qs, urlsplit
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def query_of(email):
    path = mod.subscriber_query_path(email)
    if any(c in path for c in " '\"#"):
        raise SystemExit(f"raw reserved character in {path}")
    got = parse_qs(urlsplit("http://listmonk" + path).query)
    return got["query"][0]

assert query_of("a@b.c") == "subscribers.email = 'a@b.c'"
assert query_of("a+b@c.com") == "subscribers.email = 'a+b@c.com'"
assert query_of("o'reilly@b.c") == "subscribers.email = 'o''reilly@b.c'"
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "Mailtrain campaign content maps status and rewrites tags" {
  grep -q -- '--database' "$REPO_ROOT/listmonk/setup.sh"
  grep -q -- '--database' "$REPO_ROOT/listmonk/migrate-from-mailtrain.sh"
  grep -q -- '--database' "$REPO_ROOT/README.md"

  run python3 - "$REPO_ROOT/listmonk/lib/import_mailtrain.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("import_mailtrain", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

assert mod.campaign_import_action(1, 3) == "finished"
assert mod.campaign_import_action(3, 3) == "finished"
for status in (1, 2, 4, 7, 8):
    assert mod.campaign_import_action(1, status) == "draft", status
assert mod.campaign_import_action(2, 6) is None
assert mod.campaign_import_action(4, 6) is None

html = (
    'Hi {{link:unsubscribe}} [LINK_BROWSER] [LINK_PREFERENCES] '
    '[MERGE_FIRST_NAME] {{last_name}} {{CITY}} [MERGE_CITY] '
    'https://lists.example.org/files/template/file/4/abc.png'
)
rewritten, leftovers = mod.rewrite_mailtrain_html(html)
assert "{{ UnsubscribeURL }}" in rewritten
assert "{{ MessageURL }}" in rewritten
assert rewritten.count("{{ .Subscriber.Name }}") == 2
assert "{{CITY}}" in leftovers
assert "[MERGE_CITY]" in leftovers
assert "{{link:unsubscribe}}" not in leftovers
assert '{{ "{{" }}' in rewritten

rewritten = mod.apply_file_rewrites(
    rewritten,
    "https://lists.example.org",
    {("template", "file", "4", "abc.png"): "https://schlor.lists.example.org/uploads/abc.png"},
)
assert "https://schlor.lists.example.org/uploads/abc.png" in rewritten
assert "/files/template/file/4/abc.png" not in rewritten

assert mod.mailtrain_import_name("News", "abc", shared=False) == "News"
assert mod.mailtrain_import_name("News", "abc", shared=True) == "News (abc)"
assert mod.restore_html("61210A62") == "a!\nb"
assert "HEX" in mod.sql_html("html")

import subprocess
clock = {"t": 0}
def time_fn():
    return clock["t"]
def sleep_fn(seconds):
    clock["t"] += seconds
tries = {"n": 0}
def flaky(cmd, input_text=None, check=False):
    tries["n"] += 1
    if tries["n"] < 3:
        return subprocess.CompletedProcess(cmd, 7, "", "connect")
    return subprocess.CompletedProcess(cmd, 0, "ok", "")
got = mod.run_listmonk_http(["curl"], runner=flaky, sleep_fn=sleep_fn, time_fn=time_fn)
assert got.stdout == "ok"
assert tries["n"] == 3
clock["t"] = 0
restarts = {"n": 0}
def restarting(cmd, input_text=None, check=False):
    restarts["n"] += 1
    if restarts["n"] < 2:
        return subprocess.CompletedProcess(
            cmd, 125, "", "Container abc is restarting, wait until the container is running"
        )
    return subprocess.CompletedProcess(cmd, 0, "ok", "")
got = mod.run_listmonk_http(["curl"], runner=restarting, sleep_fn=sleep_fn, time_fn=time_fn)
assert got.stdout == "ok"
assert restarts["n"] == 2
assert mod.listmonk_http_down(subprocess.CompletedProcess(["curl"], 125, "", "is restarting"))
def refused(cmd, input_text=None, check=False):
    return subprocess.CompletedProcess(cmd, 22, "", "http")
try:
    mod.run_listmonk_http(["curl"], runner=refused, sleep_fn=sleep_fn, time_fn=time_fn)
except subprocess.CalledProcessError as exc:
    assert exc.returncode == 22
else:
    raise SystemExit("HTTP errors must not be retried")
print("ok")
PY
  assert_success
  assert_line "ok"
}

@test "listmonk API auth uses the install-time API token" {
  grep -q 'LISTMONK_ADMIN_API_USER=habidat-api' "$REPO_ROOT/listmonk/config/listmonk.env.j2"
  grep -q 'LISTMONK_ADMIN_API_USER=habidat-api' "$REPO_ROOT/listmonk/versions/6.2.0/config/listmonk.env.j2"
  grep -q 'HABIDAT_LISTMONK_API_TOKEN' "$REPO_ROOT/listmonk/lib/api.sh"
  grep -q 'LISTMONK_ADMIN_API_TOKEN' "$REPO_ROOT/listmonk/setup.sh"
  grep -q 'HABIDAT_LISTMONK_API_TOKEN' "$REPO_ROOT/listmonk/lib/import_mailtrain.py"
  run grep -n 'HABIDAT_LISTMONK_ADMIN_PASSWORD' \
    "$REPO_ROOT/listmonk/lib/api.sh" \
    "$REPO_ROOT/listmonk/lib/import_mailtrain.py"
  assert_failure
}

@test "the standard visual template keeps Listmonk placeholders" {
  run python3 - <<PY
import json
asset = json.load(open("$REPO_ROOT/listmonk/assets/standard-visual-template.json", encoding="utf-8"))
assert asset["name"] == "Standardvorlage"
assert asset["type"] == "campaign_visual"
body = asset["body"]
for needle in (
    "Hallo {{ .Subscriber.Name }}!",
    "{{ UnsubscribeURL }}",
    "{{ MessageURL }}",
    '{{ L.T "email.unsub" }}',
    '{{ L.T "email.viewInBrowser" }}',
):
    assert needle in body, needle
design = json.loads(asset["body_source"])
assert design["root"]["type"] == "EmailLayout"
print("ok")
PY
  assert_success
  assert_output "ok"
  grep -q 'standard-visual-template.json' "$REPO_ROOT/listmonk/lib/configure-instance.sh"
  grep -q 'Sample visual template' "$REPO_ROOT/listmonk/lib/configure-instance.sh"
}

@test "self-signed certificate names cover nested module hostnames" {
  run bash -c "source '$REPO_ROOT/lib/selfsigned-cert.sh'; HABIDAT_DOMAIN=habidat.localhost habidat_selfsigned_hostnames"
  assert_success
  assert_line '*.habidat.localhost'
  assert_line '*.lists.habidat.localhost'
  assert_line '*.mediawiki.habidat.localhost'
  assert_line '*.mailtrain.habidat.localhost'
}
