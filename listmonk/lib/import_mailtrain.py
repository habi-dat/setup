#!/usr/bin/env python3
"""Copy one Mailtrain database into one Listmonk instance.

Unsubscribe status is per-list. Each Mailtrain subscription__* table is dumped
in full (no WHERE status=1) and imported in separate Listmonk passes per
target status so an unsubscribed row can never become confirmed.
"""

from __future__ import annotations

import csv
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

# Mailtrain v2 SubscriptionStatus (shared/lists.js): 1 subscribed, 2 unsubscribed,
# 3 bounced, 4 complained. 0 and 5 are not statuses (MIN/MAX bounds only).
STATUS_SUBSCRIBED = {1}
STATUS_UNSUBSCRIBED = {2, 3, 4}  # unsubscribed, bounced, complained
# GDPR wipe (deleteDataAfterUnsubscribe) nulls email on 2 and 4, not on bounces.
STATUS_WIPED_WHEN_BLANK = {2, 4}
KNOWN_STATUSES = STATUS_SUBSCRIBED | STATUS_UNSUBSCRIBED

LISTMONK_STATUS = {
    "confirmed": "confirmed",
    "unconfirmed": "unconfirmed",
    "unsubscribed": "unsubscribed",
}


class ImportError(RuntimeError):
    pass


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ImportError(f"missing required environment variable {name}")
    return value


def run(cmd: list[str], *, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
    )


def mysql(query: str) -> str:
    container = env("MAILTRAIN_DB_CONTAINER")
    password = env("MAILTRAIN_DB_PASSWORD")
    database = env("MAILTRAIN_DB_NAME")
    result = run(
        [
            "docker",
            "exec",
            "-e",
            f"MYSQL_PWD={password}",
            container,
            "mysql",
            "-u",
            "root",
            "-N",
            "-B",
            "--default-character-set=utf8mb4",
            database,
            "-e",
            query,
        ]
    )
    return result.stdout


def mysql_tsv(query: str) -> list[list[str]]:
    raw = mysql(query)
    rows = []
    for line in raw.splitlines():
        if line == "":
            continue
        rows.append(line.split("\t"))
    return rows


def listmonk_basic_auth() -> str:
    # v4+ Basic auth is the API username and token, never the web password.
    return f"{env('HABIDAT_LISTMONK_API_USER')}:{env('HABIDAT_LISTMONK_API_TOKEN')}"


# curl 7: nothing is listening yet. curl 56: the server closed the socket
# mid-response. Docker itself refuses --network container: while the
# Listmonk container is in a restart loop; that text is a retry too.
_LISTMONK_RETRY_CODES = {7, 56}


def listmonk_http_down(result: subprocess.CompletedProcess[str]) -> bool:
    if result.returncode in _LISTMONK_RETRY_CODES:
        return True
    text = f"{result.stderr or ''}\n{result.stdout or ''}"
    return "is restarting" in text or "wait until the container is running" in text


def listmonk_process_up() -> bool | None:
    """True when the app container is running and not restarting.

    None when LISTMONK_CONTAINER is unset, so tests do not call docker.
    """
    name = os.environ.get("LISTMONK_CONTAINER", "")
    if not name:
        return None
    probe = run(
        ["docker", "inspect", "-f", "{{.State.Running}} {{.State.Restarting}}", name],
        check=False,
    )
    if probe.returncode != 0:
        return False
    return probe.stdout.strip() == "true false"


def run_listmonk_http(
    cmd: list[str],
    *,
    input_text: str | None = None,
    runner=None,
    sleep_fn=time.sleep,
    time_fn=time.time,
    timeout: float = 180,
) -> subprocess.CompletedProcess[str]:
    execute = runner or run
    deadline = time_fn() + timeout
    while True:
        # Don't attach a sidecar while Docker is still restarting the app.
        # Attaching then fails immediately and hides the reload.
        if runner is None and listmonk_process_up() is False:
            if time_fn() >= deadline:
                name = os.environ.get("LISTMONK_CONTAINER", "")
                raise ImportError(f"Listmonk container {name} did not stay running")
            print("Listmonk container is restarting; waiting...", flush=True)
            sleep_fn(2)
            continue
        result = execute(cmd, input_text=input_text, check=False)
        if result.returncode == 0:
            return result
        if not listmonk_http_down(result) or time_fn() >= deadline:
            raise subprocess.CalledProcessError(
                result.returncode, cmd, result.stdout, result.stderr
            )
        print("Listmonk is not accepting API requests; retrying...", flush=True)
        sleep_fn(2)


def listmonk_curl(args: list[str], *, file_mount: tuple[str, str] | None = None) -> str:
    container = env("LISTMONK_CONTAINER")
    image = os.environ.get("LISTMONK_CURL_IMAGE", "curlimages/curl:8.13.0")
    cmd = ["docker", "run", "--rm"]
    if file_mount:
        cmd += ["-v", f"{file_mount[0]}:{file_mount[1]}:ro"]
    else:
        cmd += ["-i"]
    cmd += ["--network", f"container:{container}", image]
    cmd += ["-sS", "-f", "-u", listmonk_basic_auth()]
    cmd += args
    return run_listmonk_http(cmd).stdout


def listmonk_api_json(method: str, path: str, body: dict) -> dict:
    container = env("LISTMONK_CONTAINER")
    image = os.environ.get("LISTMONK_CURL_IMAGE", "curlimages/curl:8.13.0")
    payload = json.dumps(body)
    result = run_listmonk_http(
        [
            "docker",
            "run",
            "--rm",
            "-i",
            "--network",
            f"container:{container}",
            image,
            "-sS",
            "-f",
            "-u",
            listmonk_basic_auth(),
            "-X",
            method,
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
            f"http://127.0.0.1:9000{path}",
        ],
        input_text=payload,
    )
    return json.loads(result.stdout) if result.stdout else {}


def wait_listmonk_ready() -> None:
    # Settings saves reload the process. /health is up again only after that.
    listmonk_curl(["http://127.0.0.1:9000/health"])


def listmonk_get(path: str) -> dict:
    raw = listmonk_curl(["-X", "GET", f"http://127.0.0.1:9000{path}"])
    return json.loads(raw) if raw else {}


def unwrap(payload: dict) -> object:
    if isinstance(payload, dict) and "data" in payload:
        return payload["data"]
    return payload


def container_running(name: str) -> bool:
    if not name:
        return False
    probe = run(["docker", "inspect", "-f", "{{.State.Running}}", name], check=False)
    return probe.returncode == 0 and probe.stdout.strip() == "true"


def mailtrain_running() -> None:
    db_container = os.environ.get("MAILTRAIN_DB_CONTAINER", "")
    if not db_container:
        raise ImportError("Mailtrain database container is not set.")
    names = [db_container]
    # Set only for a habidat-setup Mailtrain. An external database override
    # leaves this empty: the app containers are named per project.
    app = os.environ.get("MAILTRAIN_CONTAINER", "")
    if app:
        names.append(app)
    for name in names:
        if not container_running(name):
            raise ImportError(
                f"Mailtrain is not running (container {name}). "
                "Start it with: ./habidat.sh start mailtrain"
            )


def quote_ident(name: str) -> str:
    if not name.replace("_", "").isalnum():
        raise ImportError(f"refusing unsafe SQL identifier: {name!r}")
    return f"`{name}`"


def _as_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes"}


def _as_int(value: object, default: int) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


# Mailtrain throttling is messages per hour, spaced evenly, plus an optional
# warm-up that lowers that rate for the first N days. Listmonk has one pace
# for the whole instance. A sliding window of 1s or less is ignored, so the
# finest even spacing is one message every 2 seconds.
_DAY_MS = 86_400_000
_MIN_WINDOW_S = 2
_WEEKDAY_KEYS = (
    "enableSenderOnDaySun",
    "enableSenderOnDayMon",
    "enableSenderOnDayTue",
    "enableSenderOnDayWed",
    "enableSenderOnDayThu",
    "enableSenderOnDayFri",
    "enableSenderOnDaySat",
)


def _js_round(value: float) -> int:
    # Mailtrain uses JavaScript Math.round (half away from zero).
    return int(value + 0.5) if value >= 0 else int(value - 0.5)


def _epoch_ms(value: object) -> int:
    raw = _as_int(value, 0)
    if raw <= 0:
        return 0
    # The Mailtrain field is Unix milliseconds. Smaller values are seconds.
    if raw < 10**12:
        return raw * 1000
    return raw


def mailtrain_hourly_limit(settings: dict, now: datetime | None = None) -> tuple[int, int]:
    """Return (configured messages/hour, rate Mailtrain would use right now).

    0 means no cap. During an active warm-up the current rate is lower than
    the configured one. Listmonk has no warm-up schedule, so the migration
    keeps that lower rate.
    """
    configured = _as_int(settings.get("throttling"), 0)
    if configured <= 0:
        return 0, 0
    days = _as_int(settings.get("throttlingWarmUpDays"), 0)
    start_ms = _epoch_ms(settings.get("throttlingWarmUpFrom"))
    if days <= 0 or start_ms <= 0:
        return configured, configured
    moment = now or datetime.now(timezone.utc)
    now_ms = int(moment.timestamp() * 1000)
    if start_ms > now_ms:
        start_ms = now_ms
    elapsed_days = _js_round(abs(now_ms - start_ms) / _DAY_MS)
    if elapsed_days >= days:
        return configured, configured
    if elapsed_days <= 0:
        return configured, 1
    effective = _js_round(configured * (elapsed_days / days))
    return configured, max(effective, 1)


def _window_duration(seconds: int) -> str:
    if seconds % 3600 == 0:
        return f"{seconds // 3600}h"
    if seconds % 60 == 0:
        return f"{seconds // 60}m"
    return f"{seconds}s"


def listmonk_throttle_settings(hourly: int) -> dict:
    """Performance settings that stay at or under `hourly` messages per hour.

    Below one message every two seconds, one message per sliding window matches
    Mailtrain's even spacing. Faster caps use one worker sending whole messages
    per second, with the hourly window as the hard stop.
    """
    if hourly <= 0:
        raise ValueError("hourly cap must be positive")
    # 1800/hour is one message every 2s, the slowest burst-free pace Listmonk
    # can express. Faster caps use a per-second rate plus the hourly stop.
    interval = max((3600 + hourly - 1) // hourly, _MIN_WINDOW_S)
    if hourly <= 3600 // _MIN_WINDOW_S:
        return {
            "app.message_sliding_window": True,
            "app.message_sliding_window_duration": _window_duration(interval),
            "app.message_sliding_window_rate": 1,
            "app.concurrency": 1,
            "app.message_rate": 1,
        }
    return {
        "app.message_sliding_window": True,
        "app.message_sliding_window_duration": "1h",
        "app.message_sliding_window_rate": hourly,
        "app.concurrency": 1,
        "app.message_rate": max(hourly // 3600, 1),
    }


def listmonk_tls_type(encryption: object) -> str:
    value = str(encryption or "").strip().upper()
    if value == "TLS":
        return "TLS"
    if value == "STARTTLS":
        return "STARTTLS"
    return "none"


def mailtrain_config_to_smtp(row: dict) -> dict | None:
    """Map one Mailtrain send configuration onto a Listmonk SMTP server.

    The built-in ZoneMTA and Amazon SES are not SMTP servers Listmonk can use.
    """
    mailer_type = str(row.get("mailer_type") or "").strip()
    settings = row.get("settings") or {}
    if isinstance(settings, str):
        if not settings.strip():
            settings = {}
        else:
            try:
                settings = json.loads(settings)
            except json.JSONDecodeError as exc:
                raise ImportError(
                    f"Mailtrain send configuration {row.get('id')!r} has invalid mailer_settings"
                ) from exc
    if not isinstance(settings, dict):
        return None
    if mailer_type == "aws_ses":
        return None
    if mailer_type == "zone_mta" and _as_int(settings.get("zoneMtaType"), -1) == 3:
        return None
    if mailer_type not in {"generic_smtp", "zone_mta"}:
        return None
    host = str(settings.get("hostname") or "").strip()
    port = _as_int(settings.get("port"), 0)
    if not host or port <= 0:
        return None
    use_auth = _as_bool(settings.get("useAuth"))
    configured_hourly, hourly_limit = mailtrain_hourly_limit(settings)
    return {
        "id": _as_int(row.get("id"), 0),
        "name": str(row.get("name") or "mailtrain").strip() or "mailtrain",
        "list_count": _as_int(row.get("list_count"), 0),
        "from_email": str(row.get("from_email") or "").strip(),
        "host": host,
        "port": port,
        "auth_protocol": "plain" if use_auth else "none",
        "username": str(settings.get("user") or "") if use_auth else "",
        "password": str(settings.get("password") or "") if use_auth else "",
        "tls_type": listmonk_tls_type(settings.get("encryption")),
        "tls_skip_verify": _as_bool(settings.get("allowSelfSigned")),
        "max_conns": max(_as_int(settings.get("maxConnections"), 10), 1),
        "configured_hourly": configured_hourly,
        "hourly_limit": hourly_limit,
        "weekdays_limited": any(settings.get(key) is False for key in _WEEKDAY_KEYS),
    }


def usable_smtp_servers(rows: Iterable[dict], usage: dict[int, int] | None = None) -> list[dict]:
    counts = usage or {}
    converted: list[dict] = []
    for row in rows:
        item = dict(row)
        item["list_count"] = counts.get(_as_int(row.get("id"), 0), 0)
        smtp = mailtrain_config_to_smtp(item)
        if smtp is not None:
            converted.append(smtp)
    converted.sort(key=lambda item: (-item["list_count"], item["id"]))
    return converted


def listmonk_smtp_entry(smtp: dict) -> dict:
    return {
        "name": smtp["name"],
        "uuid": str(uuid.uuid4()),
        "enabled": True,
        "host": smtp["host"],
        "port": smtp["port"],
        "auth_protocol": smtp["auth_protocol"],
        "username": smtp["username"],
        "password": smtp["password"],
        "hello_hostname": "",
        "max_conns": smtp["max_conns"],
        "max_msg_retries": 2,
        # v6.2.0 decodes this as a Go duration. An empty value makes the
        # process crash-loop with "msg_retry_delay time: invalid duration".
        "msg_retry_delay": "10ms",
        "idle_timeout": "15s",
        "wait_timeout": "5s",
        "tls_type": smtp["tls_type"],
        "tls_skip_verify": smtp["tls_skip_verify"],
        "email_headers": [],
        "from_addresses": [smtp["from_email"]] if "@" in smtp["from_email"] else [],
    }


def unmask_listmonk_settings(value: object) -> object:
    # GET /api/settings replaces secrets with bullets. Writing those back
    # stores the mask. An empty secret tells Listmonk to keep the stored one.
    if isinstance(value, str) and value and set(value) <= {"•"}:
        return ""
    if isinstance(value, list):
        return [unmask_listmonk_settings(item) for item in value]
    if isinstance(value, dict):
        return {key: unmask_listmonk_settings(item) for key, item in value.items()}
    return value


def fetch_send_configurations() -> list[dict]:
    tables = [row[0] for row in mysql_tsv("SHOW TABLES")]
    table = next((name for name in tables if name.lower() == "send_configurations"), None)
    if not table:
        return []
    query = (
        "SELECT CONCAT_WS(CHAR(31), id, IFNULL(cid,''), "
        "IFNULL(REPLACE(REPLACE(name, CHAR(31), ''), '\\n', ' '), ''), "
        "IFNULL(mailer_type,''), IFNULL(from_email,''), "
        "IFNULL(REPLACE(REPLACE(mailer_settings, CHAR(31), ''), '\\n', ''), '')) "
        f"FROM {quote_ident(table)} ORDER BY id"
    )
    rows = []
    for line in mysql(query).splitlines():
        if line == "":
            continue
        parts = line.split("\x1f")
        if len(parts) < 6:
            raise ImportError("unexpected Mailtrain send_configurations row")
        settings_raw = parts[5]
        if settings_raw in {"", "NULL", r"\N"}:
            settings: object = {}
        else:
            settings = settings_raw
        rows.append(
            {
                "id": parts[0],
                "cid": parts[1],
                "name": parts[2],
                "mailer_type": parts[3],
                "from_email": parts[4],
                "settings": settings,
            }
        )
    return rows


def fetch_send_usage() -> dict[int, int]:
    tables = [row[0] for row in mysql_tsv("SHOW TABLES")]
    lists_table = next((name for name in tables if name.lower() == "lists"), None)
    if not lists_table or "send_configuration" not in list_columns(lists_table):
        return {}
    usage: dict[int, int] = {}
    for row in mysql_tsv(
        "SELECT send_configuration, COUNT(*) FROM "
        f"{quote_ident(lists_table)} "
        "WHERE send_configuration IS NOT NULL GROUP BY send_configuration"
    ):
        if len(row) < 2 or row[0] in {"", "NULL", r"\N"}:
            continue
        usage[_as_int(row[0], 0)] = _as_int(row[1], 0)
    return usage


def apply_mailtrain_smtp() -> None:
    rows = fetch_send_configurations()
    if not rows:
        print("Mailtrain has no send configurations. Leaving Listmonk SMTP unchanged.")
        return
    servers = usable_smtp_servers(rows, fetch_send_usage())
    if not servers:
        print(
            "Mailtrain has no generic SMTP server to copy "
            "(built-in ZoneMTA and Amazon SES are not Listmonk SMTP). "
            "Leaving the SMTP settings from setup.env."
        )
        return
    settings = unmask_listmonk_settings(unwrap(listmonk_get("/api/settings")))
    if not isinstance(settings, dict):
        raise ImportError("Listmonk settings response was not an object")
    settings["smtp"] = [listmonk_smtp_entry(server) for server in servers]
    from_email = next((server["from_email"] for server in servers if "@" in server["from_email"]), "")
    if from_email:
        settings["app.from_email"] = from_email
    limited = [server for server in servers if server["hourly_limit"] > 0]
    throttle_note = "No Mailtrain hourly cap was set, so Listmonk's send pace is unchanged."
    if limited:
        # One instance-wide pace. The tightest mailbox wins so a private SMTP
        # server is not sent faster than Mailtrain allowed.
        tightest = min(limited, key=lambda server: (server["hourly_limit"], server["id"]))
        pace = listmonk_throttle_settings(tightest["hourly_limit"])
        settings.update(pace)
        if pace["app.message_sliding_window_rate"] == 1:
            pace_text = f"one message every {pace['app.message_sliding_window_duration']}"
        else:
            pace_text = (
                f"{pace['app.message_rate']} per second, "
                f"hard cap {tightest['hourly_limit']} per hour"
            )
        throttle_note = (
            f"Throttling follows {tightest['name']!r} at "
            f"{tightest['hourly_limit']} messages/hour ({pace_text})."
        )
        if tightest["configured_hourly"] != tightest["hourly_limit"]:
            throttle_note += (
                f" Warm-up is still active "
                f"({tightest['hourly_limit']} of {tightest['configured_hourly']}/hour); "
                "Listmonk keeps this lower rate."
            )
        others = [
            f"{server['name']} {server['hourly_limit']}/hour"
            for server in limited
            if server is not tightest
        ]
        if others:
            throttle_note += (
                " Other caps (" + ", ".join(others) + ") share this pace, "
                "because Listmonk has one limit for the instance."
            )
        if any(server["weekdays_limited"] for server in servers):
            throttle_note += " Mailtrain weekday windows are not copied; Listmonk sends every day."
    listmonk_api_json("PUT", "/api/settings", settings)
    # Listmonk reloads itself half a second after this response. The next API
    # call has to land after that reload, not in the gap where port 9000 is down.
    print("Waiting for Listmonk to reload settings...", flush=True)
    time.sleep(1)
    wait_listmonk_ready()
    chosen = servers[0]
    print(
        f"Copied {len(servers)} Mailtrain SMTP server(s). "
        f"Default is {chosen['name']!r} ({chosen['host']}:{chosen['port']}, "
        f"used by {chosen['list_count']} list(s)). {throttle_note}"
    )


def detect_tables() -> tuple[str, list[str], str | None]:
    tables = [row[0] for row in mysql_tsv("SHOW TABLES")]
    lists_table = next((t for t in tables if t.lower() == "lists"), None)
    if not lists_table:
        raise ImportError("Mailtrain database has no lists table.")
    sub_tables = sorted(t for t in tables if t.startswith("subscription__"))
    blacklist = next((t for t in tables if t.lower() in {"blacklist", "blacklisted"}), None)
    return lists_table, sub_tables, blacklist


def list_columns(table: str) -> set[str]:
    return {row[0] for row in mysql_tsv(f"SHOW COLUMNS FROM {quote_ident(table)}")}


def map_status(raw: str, confirmed_flag: str | None) -> str:
    try:
        status = int(raw)
    except ValueError as exc:
        raise ImportError(f"unknown Mailtrain subscription status {raw!r}") from exc
    if status not in KNOWN_STATUSES:
        raise ImportError(
            f"unknown Mailtrain subscription status {status} "
            f"(expected one of {sorted(KNOWN_STATUSES)})"
        )
    if status in STATUS_UNSUBSCRIBED:
        return "unsubscribed"
    if confirmed_flag is not None and confirmed_flag in {"0", "false", "False"}:
        return "unconfirmed"
    return "confirmed"


def email_is_blank(email: str | None) -> bool:
    value = (email or "").strip()
    return value == "" or value.upper() == "NULL"


def bucket_subscription(email: str | None, raw_status: str, confirmed_flag: str | None) -> str:
    """Classify one Mailtrain row.

    Returns 'wiped', 'skip', or a Listmonk status (confirmed / unconfirmed /
    unsubscribed). Wiped means status 2 or 4 with no email: Mailtrain GDPR
    already deleted the address, so it cannot be imported.
    """
    try:
        status = int(str(raw_status).strip())
    except ValueError as exc:
        raise ImportError(f"unknown Mailtrain subscription status {raw_status!r}") from exc
    if status not in KNOWN_STATUSES:
        raise ImportError(
            f"unknown Mailtrain subscription status {status} "
            f"(expected one of {sorted(KNOWN_STATUSES)})"
        )
    if email_is_blank(email):
        if status in STATUS_WIPED_WHEN_BLANK:
            return "wiped"
        return "skip"
    return map_status(str(status), confirmed_flag)


def fetch_lists(lists_table: str) -> list[dict[str, str]]:
    cols = list_columns(lists_table)
    name_col = "name" if "name" in cols else None
    if not name_col:
        raise ImportError(f"{lists_table} has no name column")
    desc = "description" if "description" in cols else "''"
    rows = mysql_tsv(
        f"SELECT id, {name_col}, {desc} FROM {quote_ident(lists_table)} ORDER BY id"
    )
    out = []
    for row in rows:
        out.append(
            {
                "id": row[0],
                "name": row[1] if len(row) > 1 else row[0],
                "description": row[2] if len(row) > 2 and row[2] != "NULL" else "",
            }
        )
    return out


def fetch_subscribers(table: str) -> tuple[dict[str, list[dict[str, str]]], dict[str, int]]:
    cols = list_columns(table)
    if "email" not in cols or "status" not in cols:
        raise ImportError(f"{table} must have email and status columns (has {sorted(cols)})")
    first = "first_name" if "first_name" in cols else ("firstName" if "firstName" in cols else "''")
    last = "last_name" if "last_name" in cols else ("lastName" if "lastName" in cols else "''")
    confirmed_col = next(
        (c for c in ("is_confirmed", "confirmed", "opt_in_status") if c in cols),
        None,
    )
    select = f"email, {first}, {last}, status"
    if confirmed_col:
        select += f", {quote_ident(confirmed_col)}"
    rows = mysql_tsv(f"SELECT {select} FROM {quote_ident(table)}")
    by_status: dict[str, list[dict[str, str]]] = defaultdict(list)
    counts: dict[str, int] = defaultdict(int)
    for row in rows:
        email = (row[0] or "").strip()
        first_name = "" if row[1] in {"", "NULL"} else row[1]
        last_name = "" if row[2] in {"", "NULL"} else row[2]
        raw_status = row[3]
        confirmed_flag = row[4] if confirmed_col and len(row) > 4 else None
        try:
            bucket = bucket_subscription(email, raw_status, confirmed_flag)
        except ImportError as exc:
            raise ImportError(f"{table}: {exc}") from exc
        if bucket == "wiped":
            counts["wiped_unsubscribed"] += 1
            continue
        if bucket == "skip":
            continue
        name = " ".join(p for p in (first_name, last_name) if p).strip()
        by_status[bucket].append({"email": email, "name": name})
        counts[bucket] += 1
    return by_status, dict(counts)


def create_list(name: str, description: str) -> int:
    payload = listmonk_api_json(
        "POST",
        "/api/lists",
        {
            "name": name,
            "type": "private",
            "optin": "single",
            "description": description,
        },
    )
    data = unwrap(payload)
    if not isinstance(data, dict) or "id" not in data:
        raise ImportError(f"Listmonk did not return a list id: {payload}")
    return int(data["id"])


def write_csv(path: Path, rows: Iterable[dict[str, str]]) -> int:
    count = 0
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=["email", "name"])
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
            count += 1
    return count


def import_status_of(payload: object) -> str:
    data = unwrap(payload) if isinstance(payload, dict) else payload
    if isinstance(data, dict):
        return str(data.get("status") or data.get("Status") or "").lower()
    return ""


def require_import_started(status: str) -> None:
    # POST returns importing, or finished if a tiny file completed before the
    # response was written. none means the job never started.
    if status not in {"importing", "finished"}:
        raise ImportError(
            f"Listmonk import did not start (status {status!r}; expected importing or finished)"
        )


def _default_import_getter() -> dict:
    payload = unwrap(listmonk_get("/api/import/subscribers"))
    return payload if isinstance(payload, dict) else {}


def wait_import(getter=None, *, sleep_fn=time.sleep, time_fn=time.time, timeout: float = 600) -> dict:
    """Poll until the importer reports finished.

    Only `finished` is success. `none` / empty means the job is not running
    (the caller must already have seen `importing` or `finished` on POST).
    `getter`, `sleep_fn` and `time_fn` exist so tests can drive the loop.
    """
    get = getter or _default_import_getter
    deadline = time_fn() + timeout
    last: dict = {}
    while True:
        if time_fn() >= deadline:
            raise ImportError(f"timed out waiting for Listmonk import: {last}")
        payload = get()
        last = payload if isinstance(payload, dict) else {}
        status = str(last.get("status") or last.get("Status") or "").lower()
        if status == "finished":
            return last
        if status in {"failed", "error"}:
            raise ImportError(f"Listmonk import failed: {last}")
        if status not in {"importing", "stopping"}:
            raise ImportError(f"Listmonk import is not running (status {status!r}): {last}")
        sleep_fn(1)


def reset_import() -> None:
    # Clears a leftover `finished` so the next poll cannot treat it as this pass.
    listmonk_curl(["-X", "DELETE", "http://127.0.0.1:9000/api/import/subscribers"])


def post_import(params: dict, csv_path: Path) -> None:
    reset_import()
    raw = listmonk_curl(
        [
            "-X",
            "POST",
            "-F",
            f"params={json.dumps(params)}",
            "-F",
            "file=@/import.csv",
            "http://127.0.0.1:9000/api/import/subscribers",
        ],
        file_mount=(str(csv_path.resolve()), "/import.csv"),
    )
    started = import_status_of(json.loads(raw) if raw else {})
    require_import_started(started)
    if started != "finished":
        wait_import()


def import_pass(list_id: int, status: str, rows: list[dict[str, str]], workdir: Path) -> None:
    if not rows:
        return
    csv_path = workdir / f"list-{list_id}-{status}.csv"
    write_csv(csv_path, rows)
    post_import(
        {
            "mode": "subscribe",
            "subscription_status": LISTMONK_STATUS[status],
            "delim": ",",
            "lists": [list_id],
            "overwrite": False,
            "overwrite_userinfo": True,
            "overwrite_subscription_status": True,
        },
        csv_path,
    )


def subscriber_total(list_id: int, status: str) -> int:
    payload = unwrap(
        listmonk_get(
            f"/api/subscribers?page=1&per_page=1&list_id={list_id}&subscription_status={status}"
        )
    )
    if isinstance(payload, dict):
        return int(payload.get("total") or 0)
    return 0


def subscriber_query_path(email: str) -> str:
    # curl rejects a request target that still contains spaces. Encode the SQL
    # expression so plus-addressing and quotes survive the query string too.
    safe = email.replace("\\", "\\\\").replace("'", "''")
    return "/api/subscribers?" + urllib.parse.urlencode(
        {"query": f"subscribers.email = '{safe}'", "per_page": "1"}
    )


def subscriber_by_email(email: str) -> dict | None:
    payload = unwrap(listmonk_get(subscriber_query_path(email)))
    if not isinstance(payload, dict):
        return None
    results = payload.get("results") or []
    return results[0] if results else None


def list_status_for(sub: dict, list_id: int) -> str | None:
    for entry in sub.get("lists") or []:
        if int(entry.get("id") or 0) == list_id:
            return str(entry.get("subscription_status") or entry.get("status") or "")
    return None


def warn_wiped(list_name: str, counts: dict[str, int]) -> None:
    wiped = counts.get("wiped_unsubscribed", 0)
    if wiped <= 0:
        return
    print(
        f"WARNING: list {list_name!r}: skipped {wiped} unsubscribed/complained "
        f"row(s) whose email Mailtrain already wiped. They were NOT imported and "
        f"can be subscribed again in Listmonk. Imported unsubscribed addresses: "
        f"{counts.get('unsubscribed', 0)}.",
        file=sys.stderr,
    )


def assert_unsubscribed(
    list_name: str,
    list_id: int,
    expected: int,
    samples: list[dict[str, str]],
    *,
    exact: bool,
) -> int:
    actual = subscriber_total(list_id, "unsubscribed")
    if exact and actual != expected:
        raise ImportError(
            f"unsubscribe count mismatch on {list_name!r}: "
            f"Mailtrain={expected} Listmonk={actual}"
        )
    if not exact and actual < expected:
        raise ImportError(
            f"unsubscribe count dropped on {list_name!r} after blocklist import: "
            f"Mailtrain={expected} Listmonk={actual}"
        )
    for row in samples:
        sub = subscriber_by_email(row["email"])
        if not sub:
            raise ImportError(f"unsubscribed address {row['email']} missing after import")
        got = list_status_for(sub, list_id)
        if got == "confirmed":
            raise ImportError(
                f"unsubscribed address {row['email']} would be confirmed on "
                f"{list_name!r}; aborting"
            )
        if got != "unsubscribed":
            raise ImportError(
                f"unsubscribed address {row['email']} has status {got!r} "
                f"on {list_name!r}; aborting"
            )
    return actual


def import_blacklist(table: str) -> set[str]:
    cols = list_columns(table)
    email_col = "email" if "email" in cols else None
    if not email_col:
        print(f"blacklist table {table} has no email column, skipping")
        return set()
    rows = mysql_tsv(f"SELECT {quote_ident(email_col)} FROM {quote_ident(table)}")
    emails = [r[0].strip() for r in rows if r and r[0] and not email_is_blank(r[0])]
    if not emails:
        return set()
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "blacklist.csv"
        write_csv(path, ({"email": e, "name": ""} for e in emails))
        post_import(
            {
                "mode": "blocklist",
                "delim": ",",
                "lists": [],
                "overwrite": True,
            },
            path,
        )
    print(f"Imported {len(emails)} globally blocklisted address(es).")
    return {e.lower() for e in emails}


# Mailtrain v2 shared/campaigns.js. RSS listeners and triggered campaigns are
# automations. Regular campaigns and RSS entries are the newsletters themselves.
CAMPAIGN_TYPE_REGULAR = 1
CAMPAIGN_TYPE_RSS = 2
CAMPAIGN_TYPE_RSS_ENTRY = 3
CAMPAIGN_TYPE_TRIGGERED = 4
CAMPAIGN_STATUS_FINISHED = 3

_CAMPAIGN_TYPE_LABEL = {
    CAMPAIGN_TYPE_REGULAR: "regular",
    CAMPAIGN_TYPE_RSS: "rss",
    CAMPAIGN_TYPE_RSS_ENTRY: "rss-entry",
    CAMPAIGN_TYPE_TRIGGERED: "triggered",
}

# Listmonk's UnsubscribeURL opens the page where a person also manages lists.
_LINK_TAG_VALUES = {
    "link:unsubscribe": "{{ UnsubscribeURL }}",
    "LINK_UNSUBSCRIBE": "{{ UnsubscribeURL }}",
    "link:browser": "{{ MessageURL }}",
    "LINK_BROWSER": "{{ MessageURL }}",
    "link:preferences": "{{ UnsubscribeURL }}",
    "LINK_PREFERENCES": "{{ UnsubscribeURL }}",
    "link:manage": "{{ UnsubscribeURL }}",
    "LINK_MANAGE": "{{ UnsubscribeURL }}",
}
_NAME_TAG_VALUE = "{{ .Subscriber.Name }}"
_NAME_TAGS = {
    "first_name",
    "firstName",
    "FIRST_NAME",
    "MERGE_FIRST_NAME",
    "last_name",
    "lastName",
    "LAST_NAME",
    "MERGE_LAST_NAME",
}

_CURLY_TAG = re.compile(r"\{\{\s*([^{}]+?)\s*\}\}")
_SQUARE_TAG = re.compile(r"\[([A-Za-z][A-Za-z0-9_:-]*)\]")
_FILE_PATH = re.compile(
    r"/files/(?P<type>[A-Za-z0-9_-]+)/(?P<sub>[A-Za-z0-9_-]+)/(?P<id>[0-9]+)/(?P<name>[A-Za-z0-9._-]+)"
)
_PASSTHROUGH_TEMPLATE_NAME = "Mailtrain HTML"
_PASSTHROUGH_TEMPLATE_BODY = '{{ template "content" . }}'
# Listmonk returns 400 for a campaign template that does not contain this.
_CONTENT_SLOT_RE = re.compile(r'\{\{(\s+)?template\s+"content"(\s+)?\.(\s+)?\}\}')
_EDITABLE_CAMPAIGN_STATUSES = {"draft", "paused", "scheduled"}


def campaign_import_action(campaign_type: int, status: int) -> str | None:
    """Listmonk status for one Mailtrain campaign, or None when it is skipped."""
    if campaign_type not in (CAMPAIGN_TYPE_REGULAR, CAMPAIGN_TYPE_RSS_ENTRY):
        return None
    if status == CAMPAIGN_STATUS_FINISHED:
        return "finished"
    return "draft"


def mailtrain_import_name(name: str, cid: str, *, shared: bool) -> str:
    base = (name or "").strip() or (cid or "").strip() or "mailtrain"
    if shared and (cid or "").strip():
        return f"{base} ({cid.strip()})"
    return base


def _tag_replacement(token: str) -> str | None:
    if token in _LINK_TAG_VALUES:
        return _LINK_TAG_VALUES[token]
    if token in _NAME_TAGS:
        return _NAME_TAG_VALUE
    return None


def rewrite_mailtrain_html(html: str) -> tuple[str, set[str]]:
    """Rewrite known Mailtrain tags and escape every other {{ }} sequence.

    Listmonk compiles the campaign body as a Go template, so an unknown
    {{token}} would reject the campaign. Escaping leaves the token visible
    as text. The returned set is the tags that were not rewritten.
    """
    leftovers: set[str] = set()
    sentinels: dict[str, str] = {}

    def curly(match: re.Match[str]) -> str:
        token = match.group(1).strip()
        replacement = _tag_replacement(token)
        shown = "{{" + token + "}}"
        if replacement is None:
            leftovers.add(shown)
            return match.group(0)
        key = f"\x00T{len(sentinels)}\x00"
        sentinels[key] = replacement
        return key

    def square(match: re.Match[str]) -> str:
        token = match.group(1)
        replacement = _tag_replacement(token)
        if replacement is None:
            if token.startswith(("LINK_", "MERGE_")) or token in {"FIRST_NAME", "LAST_NAME"}:
                leftovers.add(f"[{token}]")
            return match.group(0)
        key = f"\x00T{len(sentinels)}\x00"
        sentinels[key] = replacement
        return key

    rewritten = _SQUARE_TAG.sub(square, _CURLY_TAG.sub(curly, html))
    rewritten = rewritten.replace("{{", '{{ "{{" }}')
    for key, value in sentinels.items():
        rewritten = rewritten.replace(key, value)
    return rewritten, leftovers


def mailtrain_file_refs(html: str) -> list[tuple[str, str, str, str]]:
    found: list[tuple[str, str, str, str]] = []
    seen: set[tuple[str, str, str, str]] = set()
    for source in (html, urllib.parse.unquote(html)):
        for match in _FILE_PATH.finditer(source):
            parts = (match.group("type"), match.group("sub"), match.group("id"), match.group("name"))
            if parts[3] in {".", ".."} or ".." in parts[3]:
                continue
            if parts in seen:
                continue
            seen.add(parts)
            found.append(parts)
    return found


def apply_file_rewrites(
    html: str,
    public_base: str,
    urls: dict[tuple[str, str, str, str], str],
) -> str:
    base = public_base.rstrip("/")
    items = sorted(urls.items(), key=lambda item: len(item[0][3]), reverse=True)
    for (type_, sub, entity, name), new_url in items:
        path = f"/files/{type_}/{sub}/{entity}/{name}"
        encoded = urllib.parse.quote(path, safe="")
        html = html.replace(base + path, new_url)
        html = html.replace(encoded, urllib.parse.quote(new_url, safe=""))
        html = html.replace(path, new_url)
    return html


def table_named(name: str) -> str | None:
    tables = [row[0] for row in mysql_tsv("SHOW TABLES")]
    return next((table for table in tables if table.lower() == name.lower()), None)


def mysql_units(query: str) -> list[list[str]]:
    # Split only on LF. str.splitlines() also breaks on U+001E, which is a
    # real character in copied HTML and must not start a new row.
    rows = []
    for line in mysql(query).split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        if line == "":
            continue
        rows.append(line.split("\x1f"))
    return rows


def sql_cell(column: str) -> str:
    ident = quote_ident(column)
    return (
        f"IFNULL(REPLACE(REPLACE(REPLACE({ident}, CHAR(31), ''), "
        f"CHAR(10), ' '), CHAR(13), ''), '')"
    )


def sql_html(column: str) -> str:
    # Hex keeps newlines and the unit separator inside the HTML from splitting
    # the mysql batch row. A placeholder byte would be eaten by splitlines.
    return f"IFNULL(HEX({quote_ident(column)}), '')"


def restore_html(value: str) -> str:
    if value in {"", "NULL", r"\N"}:
        return ""
    try:
        return bytes.fromhex(value).decode("utf-8")
    except ValueError as exc:
        raise ImportError("Mailtrain HTML could not be read") from exc


def fetch_templates(table: str) -> list[dict[str, str]]:
    cols = list_columns(table)
    if "id" not in cols or "html" not in cols:
        return []
    name = sql_cell("name") if "name" in cols else "''"
    cid = sql_cell("cid") if "cid" in cols else "''"
    rows = mysql_units(
        "SELECT CONCAT_WS(CHAR(31), id, "
        f"{cid}, {name}, {sql_html('html')}) "
        f"FROM {quote_ident(table)} ORDER BY id"
    )
    out = []
    for parts in rows:
        if len(parts) < 4:
            raise ImportError(f"unexpected Mailtrain templates row ({len(parts)} fields)")
        out.append(
            {
                "id": parts[0],
                "cid": "" if parts[1] in {"NULL", r"\N"} else parts[1],
                "name": "" if parts[2] in {"NULL", r"\N"} else parts[2],
                "html": restore_html(parts[3]),
            }
        )
    return out


def campaign_column_exprs(cols: set[str]) -> list[tuple[str, str]]:
    # Older Mailtrain stores the body in campaigns.html. Current Mailtrain
    # stores it in campaigns.data as JSON: data.sourceCustom.html, and the
    # template id in data.sourceTemplate.
    missing = {"id", "type", "status"} - cols
    if missing:
        raise ImportError(f"Mailtrain campaigns table is missing {sorted(missing)}")
    if "html" not in cols and "data" not in cols:
        raise ImportError(
            "Mailtrain campaigns table has neither an html column nor a data column "
            f"(found {', '.join(sorted(cols))})"
        )
    exprs = [
        ("id", "id"),
        ("type", "`type`"),
        ("status", "`status`"),
    ]
    for column in ("cid", "name", "list"):
        exprs.append((column, sql_cell(column) if column in cols else "''"))
    if "template" in cols:
        exprs.append(("template", sql_cell("template")))
    elif "data" in cols:
        exprs.append(
            (
                "template",
                "IFNULL(JSON_UNQUOTE(JSON_EXTRACT(`data`, '$.sourceTemplate')), '')",
            )
        )
    else:
        exprs.append(("template", "''"))
    if "subject" in cols:
        exprs.append(("subject", sql_cell("subject")))
    elif "data" in cols:
        subject = "JSON_UNQUOTE(JSON_EXTRACT(`data`, '$.subject'))"
        if "subject_override" in cols:
            subject = f"COALESCE(NULLIF({subject}, ''), NULLIF(`subject_override`, ''))"
        exprs.append(("subject", f"IFNULL({subject}, '')"))
    else:
        exprs.append(("subject", "''"))
    if "html" in cols:
        exprs.append(("html", sql_html("html")))
    else:
        exprs.append(
            (
                "html",
                "IFNULL(HEX(JSON_UNQUOTE(JSON_EXTRACT(`data`, '$.sourceCustom.html'))), '')",
            )
        )
    return exprs


def fetch_campaigns(table: str) -> list[dict[str, str]]:
    cols = list_columns(table)
    selected = campaign_column_exprs(cols)
    keys = [key for key, _expr in selected]
    cells = [expr for _key, expr in selected]
    rows = mysql_units(
        "SELECT CONCAT_WS(CHAR(31), " + ", ".join(cells) + f") FROM {quote_ident(table)} ORDER BY id"
    )
    out = []
    for parts in rows:
        if len(parts) < len(keys):
            raise ImportError(
                f"unexpected Mailtrain campaigns row ({len(parts)} fields, expected {len(keys)})"
            )
        row = {}
        for key, value in zip(keys, parts):
            if key == "html":
                row[key] = restore_html(value)
            elif value in {"NULL", r"\N"}:
                row[key] = ""
            else:
                row[key] = value
        out.append(row)
    return out


def fetch_campaign_lists(table: str | None) -> dict[str, list[str]]:
    if not table:
        return {}
    cols = list_columns(table)
    campaign_col = next((name for name in ("campaign", "campaign_id") if name in cols), None)
    list_col = next((name for name in ("list", "list_id") if name in cols), None)
    if not campaign_col or not list_col:
        return {}
    grouped: dict[str, list[str]] = defaultdict(list)
    for row in mysql_tsv(
        f"SELECT {quote_ident(campaign_col)}, {quote_ident(list_col)} FROM {quote_ident(table)}"
    ):
        if len(row) < 2 or row[0] in {"", "NULL", r"\N"} or row[1] in {"", "NULL", r"\N"}:
            continue
        grouped[row[0]].append(row[1])
    return grouped


def assign_import_names(rows: list[dict[str, str]]) -> None:
    counts: dict[str, int] = defaultdict(int)
    for row in rows:
        counts[(row.get("name") or "").strip()] += 1
    for row in rows:
        key = (row.get("name") or "").strip()
        row["import_name"] = mailtrain_import_name(
            key, row.get("cid") or "", shared=counts[key] > 1
        )


def container_env_value(container: str, key: str) -> str:
    probe = run(
        ["docker", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", container]
    )
    prefix = f"{key}="
    for line in probe.stdout.splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :]
    raise ImportError(f"container {container} has no {key}")


def mailtrain_files_container() -> str:
    prefix = env("HABIDAT_DOCKER_PREFIX")
    project = os.environ.get("HABIDAT_LISTMONK_PROJECTID", "")
    names = []
    if project:
        names.append(f"{prefix}-mailtrain-{project}")
    names.append(f"{prefix}-mailtrain")
    for name in names:
        if container_running(name):
            return name
    raise ImportError(
        "Mailtrain files container is not running "
        f"(tried {', '.join(names)}). "
        "Lists and SMTP were already imported."
    )


def listmonk_root_url() -> str:
    settings = unwrap(listmonk_get("/api/settings"))
    if isinstance(settings, dict):
        root = str(settings.get("app.root_url") or "")
        if root:
            return root
    return ""


def listmonk_templates() -> list[dict]:
    payload = unwrap(listmonk_get("/api/templates"))
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        results = payload.get("results") or []
        return [item for item in results if isinstance(item, dict)]
    return []


def listmonk_campaigns() -> list[dict]:
    page = 1
    found: list[dict] = []
    while page < 1000:
        payload = unwrap(listmonk_get(f"/api/campaigns?page={page}&per_page=100&no_body=true"))
        if not isinstance(payload, dict):
            break
        results = [item for item in (payload.get("results") or []) if isinstance(item, dict)]
        if not results:
            break
        found.extend(results)
        total = int(payload.get("total") or 0)
        if total and len(found) >= total:
            break
        page += 1
    return found


def ensure_passthrough_template() -> int:
    for item in listmonk_templates():
        if item.get("name") == _PASSTHROUGH_TEMPLATE_NAME and item.get("type") == "campaign":
            return int(item["id"])
    created = unwrap(
        listmonk_api_json(
            "POST",
            "/api/templates",
            {
                "name": _PASSTHROUGH_TEMPLATE_NAME,
                "type": "campaign",
                "body": _PASSTHROUGH_TEMPLATE_BODY,
            },
        )
    )
    if not isinstance(created, dict) or "id" not in created:
        raise ImportError("Listmonk did not return the Mailtrain HTML template id")
    return int(created["id"])


def with_content_slot(html: str) -> str:
    """Campaign templates must include the content placeholder or Listmonk rejects them."""
    if _CONTENT_SLOT_RE.search(html):
        return html
    match = re.search(r"</body>", html, flags=re.IGNORECASE)
    if match:
        return html[: match.start()] + _PASSTHROUGH_TEMPLATE_BODY + "\n" + html[match.start() :]
    return html + "\n" + _PASSTHROUGH_TEMPLATE_BODY


def upsert_html_template(name: str, body: str, existing: dict[str, int]) -> None:
    payload = {"name": name, "type": "campaign", "body": with_content_slot(body)}
    current = existing.get(name)
    if current:
        listmonk_api_json("PUT", f"/api/templates/{current}", payload)
        return
    created = unwrap(listmonk_api_json("POST", "/api/templates", payload))
    if not isinstance(created, dict) or "id" not in created:
        raise ImportError(f"Listmonk did not return a template id for {name!r}")
    existing[name] = int(created["id"])


def allow_all_media_extensions() -> None:
    # The default list is images only. Mailtrain also stores other files.
    settings = unmask_listmonk_settings(unwrap(listmonk_get("/api/settings")))
    if not isinstance(settings, dict):
        raise ImportError("Listmonk settings response was not an object")
    current = settings.get("upload.extensions")
    if isinstance(current, list) and "*" in current:
        return
    settings["upload.extensions"] = ["*"]
    print("Allowing every media file type so Mailtrain uploads are accepted.", flush=True)
    listmonk_api_json("PUT", "/api/settings", settings)
    print("Waiting for Listmonk to reload settings...", flush=True)
    time.sleep(1)
    wait_listmonk_ready()


def upload_mailtrain_file(
    container: str,
    parts: tuple[str, str, str, str],
    dest_dir: Path,
) -> str | None:
    type_, sub, entity, name = parts
    remote = f"/app/server/files/{type_}/{sub}/{entity}/{name}"
    local = dest_dir / f"{type_}_{sub}_{entity}_{name}"
    copied = run(["docker", "cp", f"{container}:{remote}", str(local)], check=False)
    if copied.returncode != 0 or not local.is_file():
        print(f"WARNING: Mailtrain file {remote} was not on {container}.", file=sys.stderr)
        return None
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", name) or "file"
    try:
        raw = listmonk_curl(
            [
                "-X",
                "POST",
                "-F",
                f"file=@/mailtrain-file;filename={safe}",
                "http://127.0.0.1:9000/api/media",
            ],
            file_mount=(str(local), "/mailtrain-file"),
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stdout or exc.stderr or "").strip().replace("\n", " ")
        print(
            f"WARNING: Listmonk rejected Mailtrain file {remote}: {detail[:300]}",
            file=sys.stderr,
        )
        return None
    data = unwrap(json.loads(raw) if raw else {})
    if not isinstance(data, dict):
        return None
    url = str(data.get("url") or data.get("uri") or "")
    if url.startswith("/"):
        root = listmonk_root_url().rstrip("/")
        url = f"{root}{url}" if root else url
    return url or None


def save_campaign(
    name: str,
    subject: str,
    body: str,
    list_ids: list[int],
    template_id: int,
    action: str,
    existing: dict[str, dict[str, object]],
) -> bool:
    current = existing.get(name)
    if current and str(current.get("status") or "") not in _EDITABLE_CAMPAIGN_STATUSES:
        print(f"Leaving Listmonk campaign {name!r} ({current.get('status')}) unchanged.")
        return False
    payload = {
        "name": name,
        "subject": subject or name,
        "lists": list_ids,
        "body": body,
        "content_type": "html",
        "type": "regular",
        "messenger": "email",
        "template_id": template_id,
        "archive_template_id": template_id,
        "archive": action == "finished",
        "tags": ["mailtrain"],
    }
    if current:
        campaign_id = int(current["id"])
        listmonk_api_json("PUT", f"/api/campaigns/{campaign_id}", payload)
    else:
        created = unwrap(listmonk_api_json("POST", "/api/campaigns", payload))
        if not isinstance(created, dict) or "id" not in created:
            raise ImportError(f"Listmonk did not return a campaign id for {name!r}")
        campaign_id = int(created["id"])
        existing[name] = {"id": campaign_id, "status": "draft"}
    if action == "finished":
        listmonk_api_json("PUT", f"/api/campaigns/{campaign_id}/status", {"status": "finished"})
        if name in existing:
            existing[name]["status"] = "finished"
    return True


def apply_mailtrain_content(list_ids: dict[str, int]) -> None:
    templates_table = table_named("templates")
    campaigns_table = table_named("campaigns")
    if not templates_table and not campaigns_table:
        print("Mailtrain has no templates or campaigns tables. Skipping content.")
        return
    templates = fetch_templates(templates_table) if templates_table else []
    campaigns = fetch_campaigns(campaigns_table) if campaigns_table else []
    if not templates and not campaigns:
        print("Mailtrain has no HTML templates or campaigns to copy.")
        return

    files_container = mailtrain_files_container()
    public_base = container_env_value(files_container, "URL_BASE_PUBLIC").rstrip("/")
    print(f"Copying Mailtrain files from {files_container}.")

    for campaign in campaigns:
        if campaign["html"].strip():
            continue
        source = next((row for row in templates if row["id"] == campaign.get("template")), None)
        if source and source["html"].strip():
            campaign["html"] = source["html"]

    refs: list[tuple[str, str, str, str]] = []
    seen_refs: set[tuple[str, str, str, str]] = set()
    for row in [*templates, *campaigns]:
        for parts in mailtrain_file_refs(row.get("html") or ""):
            if parts in seen_refs:
                continue
            seen_refs.add(parts)
            refs.append(parts)

    urls: dict[tuple[str, str, str, str], str] = {}
    if refs:
        allow_all_media_extensions()
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        for parts in refs:
            uploaded = upload_mailtrain_file(files_container, parts, dest)
            if uploaded:
                urls[parts] = uploaded

    existing_templates: dict[str, int] = {}
    for item in listmonk_templates():
        if item.get("type") == "campaign" and item.get("name"):
            existing_templates[str(item["name"])] = int(item["id"])
    passthrough_id = ensure_passthrough_template()

    assign_import_names(templates)
    for row in templates:
        if row["import_name"] == _PASSTHROUGH_TEMPLATE_NAME:
            row["import_name"] = f"{row['import_name']} ({row['cid'] or row['id']})"
    leftovers: set[str] = set()
    copied_templates = 0
    for row in templates:
        if not row["html"].strip():
            print(f"Skipping Mailtrain template {row['import_name']!r}: no HTML.")
            continue
        body, found = rewrite_mailtrain_html(row["html"])
        leftovers.update(found)
        body = apply_file_rewrites(body, public_base, urls)
        upsert_html_template(row["import_name"], body, existing_templates)
        copied_templates += 1

    campaign_lists = fetch_campaign_lists(table_named("campaign_lists"))
    existing_campaigns: dict[str, dict[str, object]] = {}
    for item in listmonk_campaigns():
        if item.get("name"):
            existing_campaigns[str(item["name"])] = {
                "id": int(item["id"]),
                "status": str(item.get("status") or ""),
            }

    assign_import_names(campaigns)
    copied_campaigns = 0
    for row in campaigns:
        try:
            campaign_type = int(row["type"])
            status = int(row["status"])
        except ValueError as exc:
            raise ImportError(f"Mailtrain campaign {row.get('id')!r} has a bad type or status") from exc
        action = campaign_import_action(campaign_type, status)
        label = _CAMPAIGN_TYPE_LABEL.get(campaign_type, str(campaign_type))
        if action is None:
            print(f"Skipping Mailtrain {label} campaign {row['import_name']!r} (automation).")
            continue
        if not row["html"].strip():
            print(f"Skipping Mailtrain campaign {row['import_name']!r}: no HTML.")
            continue
        source_lists = campaign_lists.get(row["id"]) or ([row["list"]] if row.get("list") else [])
        target_lists = []
        for source_id in source_lists:
            if source_id in list_ids and list_ids[source_id] not in target_lists:
                target_lists.append(list_ids[source_id])
        if not target_lists:
            print(f"Skipping Mailtrain campaign {row['import_name']!r}: none of its lists were imported.")
            continue
        body, found = rewrite_mailtrain_html(row["html"])
        subject, subject_tags = rewrite_mailtrain_html(row.get("subject") or "")
        leftovers.update(found)
        leftovers.update(subject_tags)
        body = apply_file_rewrites(body, public_base, urls)
        if save_campaign(
            row["import_name"],
            subject,
            body,
            target_lists,
            passthrough_id,
            action,
            existing_campaigns,
        ):
            copied_campaigns += 1

    print(f"Copied {copied_templates} Mailtrain template(s) and {copied_campaigns} campaign(s).")
    if leftovers:
        print("Mailtrain tags left unchanged:")
        for tag in sorted(leftovers):
            print(f"  {tag}")


def main() -> int:
    try:
        mailtrain_running()
        apply_mailtrain_smtp()
        lists_table, sub_tables, blacklist = detect_tables()
        lists = fetch_lists(lists_table)
        if not lists:
            print("Mailtrain has no lists to import.")
            return 0

        print(f"Found {len(lists)} Mailtrain list(s), {len(sub_tables)} subscription table(s).")

        checks: list[dict] = []
        list_ids: dict[str, int] = {}
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            for meta in lists:
                table = f"subscription__{meta['id']}"
                if table not in sub_tables:
                    new_id = create_list(meta["name"], meta["description"])
                    list_ids[meta["id"]] = new_id
                    print(f"List {meta['name']!r}: no subscription table, created empty Listmonk list.")
                    continue
                by_status, counts = fetch_subscribers(table)
                print(
                    f"List {meta['name']!r}: "
                    f"{counts.get('confirmed', 0)} confirmed, "
                    f"{counts.get('unsubscribed', 0)} unsubscribed, "
                    f"{counts.get('unconfirmed', 0)} unconfirmed"
                )
                warn_wiped(meta["name"], counts)
                new_id = create_list(meta["name"], meta["description"])
                list_ids[meta["id"]] = new_id
                # Unsubscribed first so a later confirmed pass cannot overwrite
                # an opt-out if the same address appears twice (it should not).
                for status in ("unsubscribed", "unconfirmed", "confirmed"):
                    import_pass(new_id, status, by_status.get(status, []), workdir)

                expected_unsub = counts.get("unsubscribed", 0)
                sample = by_status.get("unsubscribed", [])[:5]
                actual_unsub = assert_unsubscribed(
                    meta["name"], new_id, expected_unsub, sample, exact=True
                )
                print(f"  -> Listmonk list {new_id}: unsubscribed count {actual_unsub} matches.")
                checks.append(
                    {
                        "name": meta["name"],
                        "list_id": new_id,
                        "expected_unsub": expected_unsub,
                        "samples": sample,
                        "confirmed": [row["email"] for row in by_status.get("confirmed", [])],
                    }
                )

        if blacklist:
            blocked = import_blacklist(blacklist)
            for check in checks:
                assert_unsubscribed(
                    check["name"],
                    check["list_id"],
                    check["expected_unsub"],
                    check["samples"],
                    exact=False,
                )
                # Blocklist import unsubscribes the address from every list.
                flipped = sum(1 for email in check["confirmed"] if email.lower() in blocked)
                if flipped:
                    print(
                        f"  blacklist marked {flipped} previously confirmed address(es) "
                        f"unsubscribed on {check['name']!r}."
                    )
        apply_mailtrain_content(list_ids)
        print("Mailtrain import finished. Mailtrain was not removed.")
        return 0
    except subprocess.CalledProcessError as exc:
        # curl -f puts Listmonk's JSON body on stdout and its own line on stderr.
        detail = (exc.stdout or "").strip()
        err = (exc.stderr or "").strip()
        if detail:
            sys.stderr.write(detail[:2000] + "\n")
        if err:
            sys.stderr.write(err + "\n")
        if not detail and not err:
            sys.stderr.write(str(exc) + "\n")
        return 1
    except ImportError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
