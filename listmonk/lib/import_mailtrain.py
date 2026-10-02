#!/usr/bin/env python3
"""Copy Mailtrain lists and subscribers into one Listmonk instance.

Unsubscribe status is per-list. Each Mailtrain subscription__* table is dumped
in full (no WHERE status=1) and imported in separate Listmonk passes per
target status so an unsubscribed row can never become confirmed.
"""

from __future__ import annotations

import csv
import json
import os
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
    result = run(cmd)
    return result.stdout


def listmonk_api_json(method: str, path: str, body: dict) -> dict:
    container = env("LISTMONK_CONTAINER")
    image = os.environ.get("LISTMONK_CURL_IMAGE", "curlimages/curl:8.13.0")
    payload = json.dumps(body)
    result = run(
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


def listmonk_get(path: str) -> dict:
    raw = listmonk_curl(["-X", "GET", f"http://127.0.0.1:9000{path}"])
    return json.loads(raw) if raw else {}


def unwrap(payload: dict) -> object:
    if isinstance(payload, dict) and "data" in payload:
        return payload["data"]
    return payload


def mailtrain_running() -> None:
    container = os.environ.get("MAILTRAIN_CONTAINER", "")
    db_container = os.environ.get("MAILTRAIN_DB_CONTAINER", "")
    for name in (container, db_container):
        if not name:
            raise ImportError("Mailtrain is not installed (store/mailtrain missing).")
        probe = run(["docker", "inspect", "-f", "{{.State.Running}}", name], check=False)
        if probe.returncode != 0 or probe.stdout.strip() != "true":
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
        "idle_timeout": "15s",
        "wait_timeout": "5s",
        "tls_type": smtp["tls_type"],
        "tls_skip_verify": smtp["tls_skip_verify"],
        "email_headers": [],
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
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            for meta in lists:
                table = f"subscription__{meta['id']}"
                if table not in sub_tables:
                    create_list(meta["name"], meta["description"])
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
        print("Mailtrain import finished. Mailtrain was not removed.")
        return 0
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(exc.stderr or exc.stdout or str(exc))
        sys.stderr.write("\n")
        return 1
    except ImportError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
