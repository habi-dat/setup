#!/usr/bin/env python3
"""Analyser for `habidat.sh security-check`.

lib/security.sh collects raw data (docker inspect output, Syft SBOMs, Grype
results, host tool output, TLS probes, module hook output) into a report
directory. This script turns that raw data into findings, applies the
installation's accepted findings, writes report.json and summary.txt, prints
the summary and exits with the security check's exit code.

Two sub-commands:

  inventory  map running containers to modules, module instances, foreign
             containers and unused images; print what the shell has to scan
  analyse    build findings from everything collected and report them

Standard library only, so it runs wherever lib/render.py runs.
"""

import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

SEVERITIES = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}
GRYPE_SEVERITY = {
    "critical": "CRITICAL",
    "high": "HIGH",
    "medium": "MEDIUM",
    "low": "LOW",
    "negligible": "LOW",
    "unknown": "LOW",
}
TESTSSL_SEVERITY = {"LOW": "LOW", "MEDIUM": "MEDIUM", "HIGH": "HIGH", "CRITICAL": "CRITICAL"}
EOL_WARN_DAYS = 90
CERT_WARN_DAYS = 14
ACCEPT_MAX_DAYS = 183
APT_LISTS_MAX_AGE_DAYS = 7
NON_PUBLIC_SUFFIXES = (".localhost", ".test", ".local", ".example", ".invalid")
ABANDONED_WORDS = re.compile(
    r"deprecated|no longer maintained|not maintained|unmaintained|legacy|archived|discontinued",
    re.I,
)
USER_AGENT = "habidat-security-check (+https://github.com/habi-dat/setup)"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_text(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write("\n")


def env_list_to_dict(env_list):
    out = {}
    for item in env_list or []:
        key, _, value = item.partition("=")
        out[key] = value
    return out


def parse_date(value):
    """Parse an ISO date or datetime (endoflife.date, Docker Hub) to a date."""
    if not value:
        return None
    try:
        return dt.date.fromisoformat(value[:10])
    except ValueError:
        return None


def norm_version(raw):
    """'1:8.2.29-1~deb12u1' -> '8.2.29', 'v24.22.1' -> '24.22.1'."""
    if not raw:
        return None
    raw = raw.split(":", 1)[1] if re.match(r"^\d+:", raw) else raw
    raw = raw.lstrip("vV")
    m = re.match(r"^(\d+(?:\.\d+)*)", raw)
    return m.group(1) if m else None


def is_public_domain(domain):
    domain = (domain or "").lower().strip(".")
    if not domain or domain == "localhost":
        return False
    return not any(domain.endswith(s) for s in NON_PUBLIC_SUFFIXES)


def parse_image_ref(ref):
    """Split an image reference into (registry, repository, tag, digest).

    Docker Hub images come back with registry 'docker.io' and the implicit
    'library/' namespace added, e.g. 'redis' -> ('docker.io', 'library/redis',
    None, None).
    """
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    tag = None
    last = ref.rsplit("/", 1)[-1]
    if ":" in last:
        ref, tag = ref.rsplit(":", 1)
    parts = ref.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        registry, repo = parts[0], "/".join(parts[1:])
    else:
        registry, repo = "docker.io", ref
    if registry == "docker.io" and "/" not in repo:
        repo = "library/" + repo
    return registry, repo, tag, digest


def display_repo(repo):
    return repo[len("library/"):] if repo.startswith("library/") else repo


def load_rules(path, columns):
    rules = []
    for line in read_text(path).splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= columns:
            rules.append(parts[:columns])
    return rules


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
def read_installed(raw):
    """installed.tsv: module, installed version, repo version, multi, instances."""
    modules = []
    for line in read_text(os.path.join(raw, "installed.tsv")).splitlines():
        cols = line.split("\t")
        if len(cols) < 4 or not cols[0]:
            continue
        modules.append(
            {
                "module": cols[0],
                "installed": cols[1],
                "available": cols[2],
                "multi": cols[3] == "1",
                "instances": [i for i in (cols[4] if len(cols) > 4 else "").split(",") if i],
            }
        )
    return modules


def match_module(rest, modules):
    """Map '<module>[-<instance>][-<service>]' to (module, instance)."""
    best = None
    for mod in modules:
        name = mod["module"]
        if rest == name or rest.startswith(name + "-"):
            if best is None or len(name) > len(best["module"]):
                best = mod
    if best is None:
        return None, None
    instance = None
    if best["multi"]:
        tail = rest[len(best["module"]) + 1:]
        for inst in sorted(best["instances"], key=len, reverse=True):
            if tail == inst or tail.startswith(inst + "-"):
                instance = inst
                break
    return best["module"], instance


def classify_container(container, prefix, modules):
    prefix = prefix.lower()
    labels = (container.get("Config") or {}).get("Labels") or {}
    project = (labels.get("com.docker.compose.project") or "").lower()
    name = (container.get("Name") or "").lstrip("/")
    for candidate in (project, name.lower()):
        if candidate.startswith(prefix + "-"):
            module, instance = match_module(candidate[len(prefix) + 1:], modules)
            if module:
                return module, instance
    return None, None


def scope_of(module, instance):
    return f"{module}/{instance}" if instance else module


def build_inventory(args):
    raw = args.raw
    containers = read_json(os.path.join(raw, "containers.json"), []) or []
    images = read_json(os.path.join(raw, "images.json"), []) or []
    modules = read_installed(raw)
    images_by_id = {img.get("Id"): img for img in images}

    inv_containers = []
    used_ids = set()
    for c in containers:
        name = (c.get("Name") or "").lstrip("/")
        module, instance = classify_container(c, args.prefix, modules)
        if module:
            kind, scope = "installation", scope_of(module, instance)
        else:
            kind, scope = "foreign", f"foreign/{name}"
        if args.target:
            if module != args.target:
                continue
            if args.instance and instance != args.instance:
                continue
        image_id = c.get("Image")
        used_ids.add(image_id)
        config = c.get("Config") or {}
        host_config = c.get("HostConfig") or {}
        ports = []
        for port_proto, bindings in ((c.get("NetworkSettings") or {}).get("Ports") or {}).items():
            port, _, proto = port_proto.partition("/")
            for b in bindings or []:
                ports.append(
                    {
                        "container_port": port,
                        "proto": proto or "tcp",
                        "host_ip": b.get("HostIp", ""),
                        "host_port": b.get("HostPort", ""),
                    }
                )
        env = env_list_to_dict(config.get("Env"))
        vhosts = [h.strip() for h in env.get("VIRTUAL_HOST", "").split(",") if h.strip()]
        inv_containers.append(
            {
                "name": name,
                "kind": kind,
                "scope": scope,
                "module": module,
                "instance": instance,
                "image_id": image_id,
                "image_ref": config.get("Image") or "",
                "privileged": bool(host_config.get("Privileged")),
                "mounts": [m.get("Source", "") for m in c.get("Mounts") or []],
                "ports": ports,
                "vhosts": vhosts if kind == "installation" else [],
            }
        )

    inv_images = {}

    def add_image(image_id, ref, scope, kind):
        img = images_by_id.get(image_id) or {}
        entry = inv_images.setdefault(
            image_id,
            {
                "id": image_id,
                "slug": (image_id or "unknown").split(":", 1)[-1][:12],
                "repo_tags": img.get("RepoTags") or [],
                "local_build": not (img.get("RepoDigests") or []),
                "env": env_list_to_dict((img.get("Config") or {}).get("Env")),
                "refs": [],
                "scopes": [],
                "kinds": [],
            },
        )
        if ref and ref not in entry["refs"]:
            entry["refs"].append(ref)
        if scope not in entry["scopes"]:
            entry["scopes"].append(scope)
            entry["kinds"].append(kind)

    for c in inv_containers:
        add_image(c["image_id"], c["image_ref"], c["scope"], c["kind"])

    if args.all_images and not args.target:
        for img in images:
            if img.get("Id") in used_ids:
                continue
            tags = [t for t in img.get("RepoTags") or [] if t != "<none>:<none>"]
            ref = tags[0] if tags else ""
            label = ref or img.get("Id", "")[7:19]
            add_image(img.get("Id"), ref, f"unused/{label}", "unused")

    inventory = {"containers": inv_containers, "images": inv_images, "modules": modules}
    write_json(os.path.join(raw, "inventory.json"), inventory)

    # What the shell has to do next, one record per line.
    for image in inv_images.values():
        label = image["refs"][0] if image["refs"] else image["slug"]
        print(f"image\t{image['id']}\t{image['slug']}\t{label}")
    seen = set()
    for c in inv_containers:
        for host in c["vhosts"]:
            if host not in seen:
                seen.add(host)
                print(f"vhost\t{host}\t{c['module']}")
    for c in inv_containers:
        print(f"container\t{c['name']}\t{c['scope']}")
    return 0


# ---------------------------------------------------------------------------
# Remote lookups with a file cache (endoflife.date, Docker Hub)
# ---------------------------------------------------------------------------
class Fetcher:
    def __init__(self, cache_dir, ttl, offline):
        self.cache_dir = cache_dir
        self.ttl = ttl
        self.offline = offline
        self.failures = {}
        self.stale = {}

    def get(self, group, key, url):
        """Return parsed JSON, {'_notfound': True} for 404, or None."""
        path = os.path.join(self.cache_dir, group, re.sub(r"[^A-Za-z0-9._-]", "_", key) + ".json")
        cached = read_json(path)
        fresh = cached is not None and (time.time() - os.path.getmtime(path)) < self.ttl
        if fresh or (cached is not None and self.offline):
            return cached
        if self.offline:
            self.failures.setdefault(group, []).append(key)
            return None
        data = None
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
                with urllib.request.urlopen(req, timeout=20) as resp:
                    data = json.load(resp)
                break
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    data = {"_notfound": True}
                    break
                if exc.code == 429 and attempt < 2:
                    time.sleep(min(int(exc.headers.get("Retry-After", "5") or 5), 30))
                    continue
                break
            except (urllib.error.URLError, OSError, ValueError):
                break
        if data is None:
            if cached is not None:
                self.stale.setdefault(group, []).append(key)
                return cached
            self.failures.setdefault(group, []).append(key)
            return None
        write_json(path, data)
        return data


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------
class Report:
    def __init__(self):
        self.findings = {}
        self.checks = []
        self.counts = {}
        self.packages = []

    def add(self, ftype, subject, scope, severity, title, fix="", **extra):
        fid = f"{ftype}:{subject}@{scope}" if subject else f"{ftype}@{scope}"
        if fid in self.findings:
            return self.findings[fid]
        finding = {
            "id": fid,
            "type": ftype,
            "subject": subject,
            "scope": scope,
            "severity": severity,
            "title": title,
            "fix": fix,
        }
        finding.update({k: v for k, v in extra.items() if v not in (None, "", [])})
        self.findings[fid] = finding
        return finding

    def check(self, name, status, note=""):
        self.checks.append({"name": name, "status": status, "note": note})


def fix_for_image(scope, kind, ref, local_build):
    if kind == "unused":
        return f"docker image rm {ref}" if ref else "remove the unused image"
    if kind == "foreign":
        return f"pull a newer image for container {scope.split('/', 1)[1]}"
    module = scope.split("/", 1)[0]
    if local_build:
        return f"./habidat.sh build {module}"
    _, _, tag, _ = parse_image_ref(ref or "x")
    if tag in (None, "latest") or re.fullmatch(r"\d+(\.\d+)?(-[a-z0-9]+)?", tag or ""):
        return f"./habidat.sh fix {module}"
    return f"./habidat.sh update {module}"


# Package types whose versions an application pins in its own lockfile.
# Rebuilding the image cannot change them; only a newer release can.
LANGUAGE_TYPES = {
    "npm", "gem", "go-module", "python", "php-composer", "php-pecl", "java-archive",
    "rust-crate", "dotnet", "hex", "erlang-otp", "pub", "swift", "conan", "dart-pub",
}
DEFAULT_EPSS_THRESHOLD = 0.1


def match_paths(art):
    paths = []
    for loc in art.get("locations") or []:
        path = loc.get("accessPath") or loc.get("path")
        if path:
            paths.append(path)
    return paths


def is_tooling(paths, patterns):
    """A package is tooling only if every place it was found matches a pattern."""
    return bool(paths) and bool(patterns) and all(any(p.search(path) for p in patterns) for path in paths)


def highest_per_major(versions):
    """'7.5.3, 7.5.21, 1.1.16, 1.1.20' -> '1.1.20, 7.5.21': the versions that fix everything."""
    best = {}
    for v in versions:
        key = v.lstrip("v").split(".", 1)[0]
        if key not in best or version_tuple(v.lstrip("v")) > version_tuple(best[key].lstrip("v")):
            best[key] = v
    return sorted(best.values(), key=lambda v: version_tuple(v.lstrip("v")))


def upstream_fix(scope, kind, fixed_in):
    versions = ", ".join(highest_per_major(fixed_in))
    if kind == "unused":
        return f"fixed upstream in {versions}; remove the unused image"
    if kind == "foreign":
        return f"fixed upstream in {versions}; arrives with a newer image for container {scope.split('/', 1)[1]}"
    module = scope.split("/", 1)[0]
    return f"fixed upstream in {versions}; arrives with a newer {module} release (./habidat.sh update {module})"


def analyse_vulnerabilities(report, inventory, report_dir, volumes, tooling_patterns, epss_threshold):
    """One finding per vulnerability and scope; per-package groups for the detailed view."""
    targets = []
    for image in inventory["images"].values():
        targets.append((image["slug"], image, None))
    for vol in volumes:
        targets.append((vol["slug"], None, vol))

    for slug, image, vol in targets:
        grype = read_json(os.path.join(report_dir, "grype", f"{slug}.json"))
        if grype is None:
            continue
        if image:
            scopes = list(zip(image["scopes"], image["kinds"]))
            ref = image["refs"][0] if image["refs"] else ""
        else:
            scopes = [(vol["scope"], "installation")]
            ref = ""
        # One finding per vulnerability and scope, listing every affected
        # package: a CVE in openssl hits libssl3 and openssl alike.
        grouped = {}
        packages = {}
        for match in grype.get("matches") or []:
            vuln = match.get("vulnerability") or {}
            art = match.get("artifact") or {}
            vid = vuln.get("id", "?")
            entry = grouped.setdefault(vid, {"severity": "LOW", "packages": [], "fixed": False,
                                             "fixed_in": [], "url": vuln.get("dataSource"),
                                             "types": set(), "kev": False, "epss": 0.0, "tooling": True})
            severity = GRYPE_SEVERITY.get((vuln.get("severity") or "unknown").lower(), "LOW")
            if SEV_RANK[severity] > SEV_RANK[entry["severity"]]:
                entry["severity"] = severity
            if vuln.get("knownExploited"):
                entry["kev"] = True
            for e in vuln.get("epss") or []:
                try:
                    entry["epss"] = max(entry["epss"], float(e.get("epss") or 0))
                except (TypeError, ValueError):
                    pass
            paths = match_paths(art)
            tooling = is_tooling(paths, tooling_patterns)
            if not tooling:
                entry["tooling"] = False
            fix = vuln.get("fix") or {}
            fixed_in = [v for v in fix.get("versions") or [] if v] if fix.get("state") == "fixed" else []
            pkg = f"{art.get('name', '?')} {art.get('version', '')}".strip()
            if pkg not in entry["packages"]:
                entry["packages"].append(pkg)
            entry["types"].add(art.get("type", ""))
            if fixed_in:
                entry["fixed"] = True
                for v in fixed_in:
                    if v not in entry["fixed_in"]:
                        entry["fixed_in"].append(v)
            # Per-package view: all advisories of one package (in any version) together.
            pkey = (art.get("name", "?"), art.get("type", ""))
            group = packages.setdefault(pkey, {"name": pkey[0], "type": pkey[1], "versions": [],
                                               "advisories": {}, "tooling": True})
            if art.get("version") and art["version"] not in group["versions"]:
                group["versions"].append(art["version"])
            if not tooling:
                group["tooling"] = False
            adv = group["advisories"].setdefault(vid, {"severity": severity, "fixed_in": []})
            if SEV_RANK[severity] > SEV_RANK[adv["severity"]]:
                adv["severity"] = severity
            adv["fixed_in"] += [v for v in fixed_in if v not in adv["fixed_in"]]

        for vid, entry in grouped.items():
            entry["urgent"] = not entry["tooling"] and (
                entry["kev"]
                or (entry["epss"] >= epss_threshold and SEV_RANK[entry["severity"]] >= SEV_RANK["MEDIUM"])
            )
            pkgs = entry["packages"]
            types = sorted(t for t in entry["types"] if t)
            shown = ", ".join(pkgs[:4]) + (f" (+{len(pkgs) - 4} more)" if len(pkgs) > 4 else "")
            title = f"{shown} ({', '.join(types)})"
            title += f", fixed in {', '.join(entry['fixed_in'])}" if entry["fixed"] else ", no fix released"
            notes = []
            if entry["kev"]:
                notes.append("known to be exploited (CISA KEV)")
            if entry["epss"] >= epss_threshold:
                notes.append(f"exploitation likely (EPSS {entry['epss']:.0%})")
            if entry["tooling"]:
                notes.append("tooling package, not loaded by the running service")
            if notes:
                title += "; " + "; ".join(notes)
            language_only = bool(types) and all(t in LANGUAGE_TYPES for t in types)
            for scope, kind in scopes:
                if not entry["fixed"]:
                    fix_cmd = ""
                elif vol:
                    fix_cmd = f"update the code in {vol['path']} ({vol['container']})"
                elif language_only:
                    fix_cmd = upstream_fix(scope, kind, entry["fixed_in"])
                else:
                    fix_cmd = fix_for_image(scope, kind, ref, image["local_build"])
                report.add(
                    "vuln", vid, scope, entry["severity"], title, fix_cmd,
                    fixed=entry["fixed"],
                    fixed_in=", ".join(entry["fixed_in"]),
                    packages=pkgs,
                    urgent=entry["urgent"],
                    kev=entry["kev"],
                    epss=round(entry["epss"], 5),
                    tooling=entry["tooling"],
                    image=ref or None,
                    path=vol["path"] if vol else None,
                    url=entry["url"],
                )
        for scope, _kind in scopes:
            for group in packages.values():
                report.packages.append(dict(group, scope=scope))


def package_groups(report, findings):
    """report.json's `vulnerabilities`: advisories per package and scope.

    Accepted vulnerabilities are left out; urgent ones are marked.
    """
    by_id = {f["id"]: f for f in findings if f["type"] == "vuln"}
    out = []
    for group in report.packages:
        advisories = []
        for vid, adv in sorted(group["advisories"].items()):
            finding = by_id.get(f"vuln:{vid}@{group['scope']}")
            if finding is None or finding.get("accepted"):
                continue
            advisories.append({"id": vid, "severity": adv["severity"], "fixed_in": adv["fixed_in"],
                               "urgent": bool(finding.get("urgent"))})
        if not advisories:
            continue
        fixed = [v for a in advisories for v in a["fixed_in"]]
        out.append({
            "scope": group["scope"],
            "package": group["name"],
            "type": group["type"],
            "versions": group["versions"],
            "severity": max((a["severity"] for a in advisories), key=lambda s: SEV_RANK[s]),
            "tooling": group["tooling"],
            "urgent": any(a["urgent"] for a in advisories),
            "unfixed": sum(1 for a in advisories if not a["fixed_in"]),
            "fixed_in": highest_per_major(fixed),
            "advisories": advisories,
        })
    out.sort(key=lambda g: (g["scope"], -SEV_RANK[g["severity"]], g["package"]))
    return out


def eol_candidates(image_env, sbom, rules):
    """Yield (product, version, source) found in one image, first per product."""
    found = {}
    artifacts = (sbom or {}).get("artifacts") or []
    distro = (sbom or {}).get("distro") or {}
    for kind, pattern, product in rules:
        if product in found:
            continue
        if kind == "env":
            version = norm_version(image_env.get(pattern))
            if version:
                found[product] = (version, f"env {pattern}")
        elif kind == "distro":
            if distro.get("id") == pattern:
                version = norm_version(distro.get("versionID"))
                if version:
                    found[product] = (version, f"os-release {pattern}")
        else:
            regex = re.compile(pattern)
            for art in artifacts:
                if art.get("type") == kind and regex.fullmatch(art.get("name", "")):
                    version = norm_version(art.get("version"))
                    if version:
                        found[product] = (version, f"{kind} package {art.get('name')}")
                        break
    for product, (version, source) in found.items():
        yield product, version, source


def match_release(releases, version):
    best = None
    for rel in releases:
        name = str(rel.get("name", ""))
        if version == name or version.startswith(name + "."):
            if best is None or len(name) > len(str(best.get("name", ""))):
                best = rel
    return best


def eol_finding(report, fetcher, today, product, version, source, scope, fix):
    data = fetcher.get("eol", product, f"https://endoflife.date/api/v1/products/{product}/")
    if not data or data.get("_notfound"):
        return
    result = data.get("result") or {}
    releases = result.get("releases") or []
    rel = match_release(releases, version)
    if rel is None:
        return
    label = result.get("label") or product
    eol_date = parse_date(rel.get("eolFrom"))
    newest = next((r.get("name") for r in releases if r.get("isMaintained")), None)
    hint = f" (supported: {newest})" if newest else ""
    subject = f"{product}-{rel.get('name')}"
    if rel.get("isEol") or (eol_date and eol_date <= today):
        when = f" on {eol_date.isoformat()}" if eol_date else ""
        report.add("eol", subject, scope, "HIGH", f"{label} {version} reached end of life{when}{hint}", fix, source=source)
    elif eol_date and (eol_date - today).days <= EOL_WARN_DAYS:
        report.add(
            "eol", subject, scope, "MEDIUM",
            f"{label} {version} reaches end of life on {eol_date.isoformat()}{hint}", fix, source=source,
        )


def analyse_eol(report, inventory, report_dir, rules, fetcher, today, raw, with_host, with_images=True):
    for image in inventory["images"].values() if with_images else ():
        sbom = read_json(os.path.join(report_dir, "sbom", f"{image['slug']}.syft.json"))
        ref = image["refs"][0] if image["refs"] else ""
        for product, version, source in eol_candidates(image["env"], sbom, rules):
            for scope, kind in zip(image["scopes"], image["kinds"]):
                fix = fix_for_image(scope, kind, ref, image["local_build"])
                if kind == "installation":
                    fix = f"./habidat.sh update {scope.split('/', 1)[0]} (or a newer habidat release)"
                eol_finding(report, fetcher, today, product, version, source, scope, fix)

    if not with_host:
        return
    os_release =parse_os_release(read_text(os.path.join(raw, "host", "os-release")))
    if os_release.get("ID") in ("debian", "ubuntu"):
        version = norm_version(os_release.get("VERSION_ID"))
        if version:
            eol_finding(report, fetcher, today, os_release["ID"], version, "host os-release", "host",
                        "upgrade the server to a supported release")
    info = read_json(os.path.join(raw, "docker", "info.json"), {}) or {}
    version = norm_version(info.get("ServerVersion"))
    if version:
        eol_finding(report, fetcher, today, "docker-engine", version, "docker info", "host",
                    "upgrade Docker Engine")


def analyse_hub(report, inventory, moved, fetcher, today, months):
    limit = today - dt.timedelta(days=int(months * 30.44))
    by_ref = {}
    for c in inventory["containers"]:
        image = inventory["images"].get(c["image_id"]) or {}
        by_ref.setdefault((c["image_ref"], c["scope"]), (c["kind"], image))
    for image in inventory["images"].values():
        for scope, kind in zip(image["scopes"], image["kinds"]):
            if kind == "unused" and image["refs"]:
                by_ref.setdefault((image["refs"][0], scope), (kind, image))

    moved_map = {display_repo(parse_image_ref(old)[1]): new for old, new in moved}
    for (ref, scope), (kind, image) in sorted(by_ref.items()):
        if not ref or image.get("local_build", True):
            continue
        registry, repo, tag, digest = parse_image_ref(ref)
        if registry != "docker.io" or digest:
            continue
        name = display_repo(repo)
        fix = fix_for_image(scope, kind, ref, False)
        if tag in (None, "latest"):
            report.add("floating-tag", name, scope, "LOW",
                       f"{ref} has no fixed version tag, so it is unclear which version runs",
                       "pin a version tag in the compose file")
        if name in moved_map:
            report.add("moved", name, scope, "MEDIUM",
                       f"{name} is now published as {moved_map[name]}; the old name may stop getting updates",
                       f"switch the image to {moved_map[name]}")
            continue
        data = fetcher.get("hub", repo, f"https://hub.docker.com/v2/repositories/{repo}/")
        if not data or data.get("_notfound"):
            continue
        last = parse_date(data.get("last_updated"))
        description = data.get("description") or ""
        reasons = []
        if data.get("is_archived"):
            reasons.append("archived on Docker Hub")
        if ABANDONED_WORDS.search(description):
            reasons.append(f"description says \"{description.strip()[:60]}\"")
        if last and last < limit:
            reasons.append(f"no update since {last.isoformat()}")
        if reasons:
            report.add("abandoned", name, scope, "HIGH",
                       f"{name} is no longer maintained: {'; '.join(reasons)}",
                       "replace the image with a maintained one")
            continue
        if tag and tag != "latest":
            tag_data = fetcher.get("hub", f"{repo}:{tag}", f"https://hub.docker.com/v2/repositories/{repo}/tags/{tag}/")
            tag_last = parse_date((tag_data or {}).get("last_updated"))
            if tag_last and tag_last < limit:
                report.add("stale-tag", f"{name}:{tag}", scope, "MEDIUM",
                           f"{name}:{tag} was last rebuilt on {tag_last.isoformat()}; newer tags exist",
                           fix)


def in_target(scope, target):
    """True when a scope belongs to the security check's module target."""
    if not target or target == "all":
        return True
    return scope == target or scope.startswith(target + "/") or target.startswith(scope + "/")


def analyse_outdated(report, inventory, target):
    for mod in inventory["modules"]:
        if not in_target(mod["module"], target):
            continue
        inst, avail = mod["installed"], mod["available"]
        if inst and avail and inst != avail and version_tuple(inst) < version_tuple(avail):
            report.add("outdated-module", mod["module"], mod["module"], "MEDIUM",
                       f"{mod['module']} {inst} is installed, {avail} is available",
                       f"./habidat.sh update {mod['module']}")


def version_tuple(value):
    return tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.-]", value))


def parse_os_release(text):
    out = {}
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key:
            out[key.strip()] = value.strip().strip('"')
    return out


def analyse_host(report, raw, today):
    host = os.path.join(raw, "host")
    if not os.path.isdir(host):
        return
    # Pending security updates from `apt-get -s dist-upgrade`.
    sim = read_text(os.path.join(host, "apt-sim.txt"))
    updates = []
    for line in sim.splitlines():
        m = re.match(r"^Inst (\S+) (?:\[(\S+)\] )?\((\S+) (.*)\)", line)
        if m and "security" in m.group(4).lower():
            updates.append(f"{m.group(1)} {m.group(2) or ''}→{m.group(3)}".replace(" →", " → "))
    if updates:
        names = [u.split()[0] for u in updates]
        shown = ", ".join(names[:8]) + (f" (+{len(names) - 8} more)" if len(names) > 8 else "")
        report.add("host-updates", "", "host", "HIGH",
                   f"{len(updates)} security update(s) pending: {shown}",
                   "apt-get update && apt-get upgrade", details=updates)
    age = read_text(os.path.join(host, "apt-lists-age")).strip()
    if age.isdigit() and int(age) > APT_LISTS_MAX_AGE_DAYS:
        report.add("host-apt-stale", "", "host", "MEDIUM",
                   f"package lists are {age} days old, so pending updates may be missing",
                   "apt-get update (and check that it runs automatically)")

    support = read_text(os.path.join(host, "support-status.txt"))
    sources = sorted(set(re.findall(r"^\s*\*\s*Source:\s*(\S+)", support, re.M)))
    if sources:
        report.add("host-unsupported", "", "host", "MEDIUM",
                   f"{len(sources)} package(s) without full security support: {', '.join(sources[:8])}",
                   "replace them or accept the risk (see check-support-status)", details=sources)

    nr = read_text(os.path.join(host, "needrestart.txt"))
    kv = {}
    services = []
    for line in nr.splitlines():
        key, _, value = line.partition(":")
        value = value.strip()
        if key == "NEEDRESTART-SVC":
            services.append(value)
        elif key.startswith("NEEDRESTART-"):
            kv[key] = value
    if kv.get("NEEDRESTART-KSTA") in ("2", "3"):
        report.add("host-reboot", "", "host", "MEDIUM",
                   f"running kernel {kv.get('NEEDRESTART-KCUR', '?')}, installed {kv.get('NEEDRESTART-KEXP', '?')}",
                   "reboot the server")
    if services:
        report.add("host-restart", "", "host", "MEDIUM",
                   f"{len(services)} service(s) use outdated libraries: {', '.join(services[:8])}",
                   "needrestart -r a (or reboot)", details=services)

    unattended = parse_os_release(read_text(os.path.join(host, "unattended.txt")))
    if unattended:
        if unattended.get("installed") != "yes" or unattended.get("enabled") != "1":
            report.add("host-no-auto-updates", "", "host", "MEDIUM",
                       "security updates are not installed automatically",
                       "apt-get install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades")

    lynis = read_text(os.path.join(host, "lynis-report.dat"))
    for line in lynis.splitlines():
        if line.startswith("warning[]="):
            parts = line.split("=", 1)[1].split("|")
            test_id = parts[0] if parts else "?"
            text = parts[1] if len(parts) > 1 else ""
            report.add("lynis", test_id, "host", "MEDIUM", text, f"see lynis show details {test_id}")
        elif line.startswith("hardening_index="):
            report.check("host.lynis.index", "ok", f"Lynis hardening index {line.split('=', 1)[1]}")


def analyse_docker(report, raw, inventory, expected_mounts, with_host):
    info = read_json(os.path.join(raw, "docker", "info.json")) if with_host else None
    if info:
        daemon = read_json(os.path.join(raw, "docker", "daemon.json"), {}) or {}
        security = " ".join(info.get("SecurityOptions") or [])
        if "name=userns" not in security:
            report.add("docker", "userns-remap", "host", "LOW",
                       "containers run without user namespace remapping (root in a container is root on the host)",
                       'set "userns-remap" in /etc/docker/daemon.json')
        if not info.get("LiveRestoreEnabled"):
            report.add("docker", "live-restore", "host", "LOW",
                       "containers stop while the Docker daemon restarts (e.g. during security updates)",
                       'set "live-restore": true in /etc/docker/daemon.json')
        if not daemon.get("no-new-privileges"):
            report.add("docker", "no-new-privileges", "host", "LOW",
                       "processes in containers may gain new privileges by default",
                       'set "no-new-privileges": true in /etc/docker/daemon.json')
        driver = info.get("LoggingDriver") or "json-file"
        if driver == "json-file" and not (daemon.get("log-opts") or {}).get("max-size"):
            report.add("docker", "log-rotation", "host", "LOW",
                       "container logs are not rotated by default and can fill the disk",
                       'set "log-opts": {"max-size": "50m"} in /etc/docker/daemon.json')
        bridge = read_json(os.path.join(raw, "docker", "bridge.json"), []) or []
        options = (bridge[0].get("Options") or {}) if bridge else {}
        if options.get("com.docker.network.bridge.enable_icc", "true") == "true":
            report.add("docker", "icc", "host", "LOW",
                       "containers on the default bridge network can reach each other",
                       'set "icc": false in /etc/docker/daemon.json')

    patterns = [re.compile(p[0]) for p in expected_mounts]
    for c in inventory["containers"]:
        if c["privileged"]:
            report.add("privileged", c["name"], c["scope"], "HIGH",
                       f"container {c['name']} runs privileged (full access to the host)",
                       "remove privileged: true")
        if any(m in ("/var/run/docker.sock", "/run/docker.sock") for m in c["mounts"]):
            repo = display_repo(parse_image_ref(c["image_ref"] or "x")[1])
            if not any(p.fullmatch(repo) for p in patterns):
                report.add("docker-sock", c["name"], c["scope"], "HIGH",
                           f"container {c['name']} ({c['image_ref']}) can control Docker and so the whole host",
                           "remove the docker.sock mount")


def analyse_exposure(report, raw, inventory, expected_ports, with_host):
    ufw_enabled = bool(re.search(r"^\s*ENABLED\s*=\s*yes", read_text(os.path.join(raw, "host", "ufw.conf")), re.M | re.I))
    published = set()
    for c in inventory["containers"]:
        for p in c["ports"]:
            ip = p["host_ip"]
            if not is_exposed_address(ip):
                continue
            published.add((p["proto"], p["host_port"]))
            if p["proto"] == "tcp" and p["host_port"] in expected_ports:
                continue
            ftype = "ufw-bypass" if ufw_enabled else "exposed"
            where = ip or "0.0.0.0"
            title = f"{p['proto']}/{p['host_port']} of {c['name']} is published on {where}"
            if ufw_enabled:
                title += "; Docker bypasses ufw, so the firewall does not filter it"
            report.add(ftype, f"{p['proto']}/{p['host_port']}", c["scope"], "HIGH", title,
                       "bind the port to 127.0.0.1 or remove the port mapping")

    if not with_host:
        return
    ss_path = os.path.join(raw, "host", "ss.txt")
    for line in read_text(ss_path).splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        local = cols[3]
        addr, _, port = local.rpartition(":")
        addr = addr.strip("[]").split("%", 1)[0]
        if not is_exposed_address(addr) or not port.isdigit():
            continue
        if port in expected_ports or ("tcp", port) in published:
            continue
        report.add("exposed", f"tcp/{port}", "host", "HIGH",
                   f"a host service listens on {addr}:{port}, reachable from outside",
                   "bind the service to 127.0.0.1 or block the port in the firewall")


def is_exposed_address(addr):
    if addr in ("", "*", "0.0.0.0", "::"):
        return True
    try:
        return ipaddress.ip_address(addr).is_global
    except ValueError:
        return False


def analyse_tls(report, raw, today):
    tls_dir = os.path.join(raw, "tls")
    if not os.path.isdir(tls_dir):
        return
    for entry in sorted(os.listdir(tls_dir)):
        path = os.path.join(tls_dir, entry)
        if entry.endswith(".cert"):
            host = entry[:-len(".cert")]
            kv = parse_os_release(read_text(path))
            if kv.get("connect") != "ok":
                report.check(f"tls.cert:{host}", "failed", "no TLS connection on 127.0.0.1:443")
                continue
            not_after = None
            try:
                not_after = dt.datetime.strptime(kv.get("notafter", ""), "%b %d %H:%M:%S %Y %Z").date()
            except ValueError:
                pass
            if not_after and (not_after - today).days < CERT_WARN_DAYS:
                state = "expired" if not_after < today else "expires"
                report.add("cert-expiry", host, "host", "HIGH",
                           f"certificate for {host} {state} on {not_after.isoformat()}",
                           "check the Let's Encrypt companion (./habidat.sh restart nginx)")
            if kv.get("hostmatch") == "no":
                report.add("cert-mismatch", host, "host", "HIGH",
                           f"certificate served for {host} does not cover that name ({kv.get('subject', '')})",
                           "check VIRTUAL_HOST / LETSENCRYPT_HOST of the module")
            verify = kv.get("verify", "0")
            if not verify.startswith("0"):
                report.add("cert-untrusted", host, "host", "HIGH",
                           f"certificate for {host} is not trusted: {verify}",
                           "enable Let's Encrypt (HABIDAT_LETSENCRYPT=true)")
        elif entry.startswith("testssl-") and entry.endswith(".json"):
            host = entry[len("testssl-"):-len(".json")]
            data = read_json(path, [])
            if isinstance(data, dict):
                data = data.get("scanResult") or []
            for item in data or []:
                sev = TESTSSL_SEVERITY.get((item.get("severity") or "").upper())
                if not sev:
                    continue
                report.add("tls", item.get("id", "?"), "host", sev,
                           f"{host}: {item.get('finding', '')}",
                           "adjust the TLS settings of the nginx module")


def analyse_config(report, base_dir):
    path = os.path.join(base_dir, "setup.env")
    try:
        mode = os.stat(path).st_mode & 0o777
        if mode & 0o077:
            report.add("config", "setup-env-mode", "host", "HIGH",
                       f"setup.env holds passwords but is readable by others (mode {mode:o})",
                       f"chmod 600 {path}")
    except OSError:
        pass
    domain = os.environ.get("HABIDAT_DOMAIN", "")
    if not is_public_domain(domain):
        return
    checks = [
        ("HABIDAT_MAILHOG", "true", "mailhog",
         "mailhog (a development mail catcher) is enabled on a public domain",
         "set HABIDAT_MAILHOG=false and configure real SMTP"),
        ("HABIDAT_CREATE_SELFSIGNED", "true", "selfsigned",
         "self-signed certificates are enabled on a public domain",
         "set HABIDAT_CREATE_SELFSIGNED=false and HABIDAT_LETSENCRYPT=true"),
        ("HABIDAT_LETSENCRYPT", "false", "no-letsencrypt",
         "Let's Encrypt is disabled on a public domain",
         "set HABIDAT_LETSENCRYPT=true"),
    ]
    for var, bad, subject, title, fix in checks:
        if os.environ.get(var, "").lower() == bad:
            report.add("config", subject, "host", "HIGH", title, fix)


def analyse_hooks(report, raw, target):
    hooks = os.path.join(raw, "hooks")
    if not os.path.isdir(hooks):
        return
    for entry in sorted(os.listdir(hooks)):
        if not entry.endswith(".tsv"):
            continue
        scope = entry[:-4].replace("__", "/")
        if not in_target(scope, target):
            continue
        for line in read_text(os.path.join(hooks, entry)).splitlines():
            cols = line.split("\t")
            if cols[0] == "finding" and len(cols) >= 5:
                sev = cols[3].upper() if cols[3].upper() in SEV_RANK else "MEDIUM"
                report.add(cols[1], cols[2], scope, sev, cols[4], cols[5] if len(cols) > 5 else "")
            elif cols[0] == "skip" and len(cols) >= 2:
                report.check(f"hook:{scope}", "skipped", cols[1])


def read_volumes(raw):
    out = []
    for line in read_text(os.path.join(raw, "volumes.tsv")).splitlines():
        cols = line.split("\t")
        if len(cols) >= 4:
            out.append({"scope": cols[0], "container": cols[1], "path": cols[2], "slug": cols[3]})
    return out


def read_checks(report, raw):
    for line in read_text(os.path.join(raw, "checks.tsv")).splitlines():
        cols = line.split("\t")
        if len(cols) >= 2:
            report.check(cols[0], cols[1], cols[2] if len(cols) > 2 else "")


# ---------------------------------------------------------------------------
# Accepted findings
# ---------------------------------------------------------------------------
def load_accepted(path, today):
    """Return (rules, warnings). A rule is (id_pattern_regex, until, reason)."""
    rules, warnings = [], []
    limit = today + dt.timedelta(days=ACCEPT_MAX_DAYS)
    for number, line in enumerate(read_text(path).splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split(None, 2)
        where = f"accepted line {number}"
        if len(parts) < 3 or not parts[2].strip():
            warnings.append(f"{where}: needs '<finding id> <YYYY-MM-DD> <reason>', ignored")
            continue
        fid, until_raw, reason = parts
        try:
            until = dt.date.fromisoformat(until_raw)
        except ValueError:
            warnings.append(f"{where}: '{until_raw}' is not a YYYY-MM-DD date, ignored")
            continue
        if until > limit:
            warnings.append(f"{where}: expiry {until} is more than {ACCEPT_MAX_DAYS} days away, ignored")
            continue
        pattern = re.compile(re.escape(fid).replace(r"\*", ".*") + r"\Z")
        rules.append((fid, pattern, until, reason.strip()))
    return rules, warnings


def apply_accepted(findings, rules, today):
    expired = []
    for finding in findings:
        for fid, pattern, until, reason in rules:
            if pattern.match(finding["id"]):
                if until < today:
                    if fid not in expired:
                        expired.append(fid)
                    continue
                finding["accepted"] = {"until": until.isoformat(), "reason": reason, "rule": fid}
                break
    return expired


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
COLORS = {"CRITICAL": "\033[1;31m", "HIGH": "\033[31m", "MEDIUM": "\033[33m", "LOW": "\033[36m"}
RESET = "\033[0m"


def scope_group(scope):
    if scope.startswith("foreign/"):
        return "foreign containers"
    if scope.startswith("unused/"):
        return "unused images"
    return scope


def short_id(finding):
    return finding["id"].rsplit("@", 1)[0]


def render_summary(findings, checks, inventory, threshold, verbose, color, extra_lines, packages=()):
    display_bar = SEVERITIES[max(SEV_RANK[threshold] - 1, 0)]
    module_order = [m["module"] for m in inventory["modules"]]

    def group_key(group):
        if group == "host":
            return (0, 0, group)
        if group == "foreign containers":
            return (2, 0, group)
        if group == "unused images":
            return (3, 0, group)
        mod = group.split("/", 1)[0]
        return (1, module_order.index(mod) if mod in module_order else 999, group)

    def label(sev):
        return f"{COLORS[sev]}{sev:<8}{RESET}" if color else f"{sev:<8}"

    groups = {}
    others = {}  # group -> non-urgent vulnerabilities at or above the threshold
    for f in findings:
        if f.get("accepted"):
            continue
        group = scope_group(f["scope"])
        groups.setdefault(group, [])
        if f["type"] == "vuln":
            if f.get("urgent"):
                groups[group].append(f)
            elif SEV_RANK[f["severity"]] >= SEV_RANK[threshold]:
                others.setdefault(group, []).append(f)
        elif verbose or SEV_RANK[f["severity"]] >= SEV_RANK[display_bar]:
            groups[group].append(f)

    # --verbose: every non-urgent vulnerability, one line per package.
    pkg_lines = {}
    if verbose:
        for g in packages:
            advisories = [a for a in g["advisories"] if not a["urgent"]]
            if not advisories:
                continue
            sev = max((a["severity"] for a in advisories), key=lambda s: SEV_RANK[s])
            unfixed = sum(1 for a in advisories if not a["fixed_in"])
            fixed = highest_per_major([v for a in advisories for v in a["fixed_in"]])
            text = f"{g['package']} {', '.join(g['versions'])} ({g['type']}): {len(advisories)} "
            text += "advisory" if len(advisories) == 1 else "advisories"
            if fixed:
                text += f", fixed in {', '.join(fixed)}"
            if unfixed:
                text += f", {unfixed} without a fix"
            if g["tooling"]:
                text += " (tooling)"
            group = scope_group(g["scope"])
            if group in ("foreign containers", "unused images"):
                text += f" @{g['scope'].split('/', 1)[1]}"
            pkg_lines.setdefault(group, []).append((sev, text))
            groups.setdefault(group, [])

    lines = []
    for group in sorted(groups, key=group_key):
        items = sorted(groups[group], key=lambda f: (-SEV_RANK[f["severity"]], f["id"]))
        if not items and not others.get(group) and not pkg_lines.get(group):
            continue
        lines.append(group)
        for f in items:
            ident = short_id(f)
            if group in ("foreign containers", "unused images"):
                ident += "@" + f["scope"].split("/", 1)[1]
            lines.append(f"  {label(f['severity'])} {ident}")
            lines.append(f"           {f['title']}")
            if f.get("fix"):
                lines.append(f"           fix: {f['fix']}")
        if pkg_lines.get(group):
            lines.append("  other vulnerabilities by package:")
            for sev, text in sorted(pkg_lines[group], key=lambda x: (-SEV_RANK[x[0]], x[1])):
                lines.append(f"  {label(sev)} {text}")
        elif others.get(group):
            rest = others[group]
            count = len(rest)
            details = []
            critical = sum(1 for f in rest if f["severity"] == "CRITICAL")
            if critical and threshold != "CRITICAL":
                details.append(f"{critical} critical")
            unfixed = sum(1 for f in rest if not f.get("fixed"))
            if unfixed:
                details.append(f"{unfixed} without a fix")
            noun = "vulnerability" if count == 1 else "vulnerabilities"
            further = "further " if any(f["type"] == "vuln" for f in items) else ""
            line = f"  + {count} {further}known {noun} at {threshold} or above"
            if details:
                line += f" ({', '.join(details)})"
            line += ", none known or likely to be exploited (see report or --verbose)"
            lines.append(line)
    for c in checks:
        if c["status"] in ("skipped", "failed"):
            lines.append(f"{c['status']}: {c['name']}" + (f" ({c['note']})" if c["note"] else ""))
    lines.extend(extra_lines)
    return lines


def compute_exit(findings, checks, threshold):
    """Urgent vulnerabilities always count; other findings from the threshold up."""
    failed = any(c["status"] == "failed" for c in checks)
    hits = [
        f for f in findings
        if not f.get("accepted")
        and (f.get("urgent") if f["type"] == "vuln" else SEV_RANK[f["severity"]] >= SEV_RANK[threshold])
    ]
    return (2 if failed else 1 if hits else 0), hits


def epss_threshold_from_env(report):
    raw = os.environ.get("HABIDAT_SECURITY_EPSS_THRESHOLD", "").strip()
    if not raw:
        return DEFAULT_EPSS_THRESHOLD
    try:
        value = float(raw)
    except ValueError:
        value = -1
    if not 0 <= value <= 1:
        report.check("config.epss", "failed",
                     f"HABIDAT_SECURITY_EPSS_THRESHOLD={raw} is not a number between 0 and 1")
        return DEFAULT_EPSS_THRESHOLD
    return value


def run_analyse(args):
    report_dir = args.report
    raw = os.path.join(report_dir, "raw")
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    inventory = read_json(os.path.join(raw, "inventory.json"),
                          {"containers": [], "images": {}, "modules": []})
    threshold = args.severity.upper()
    ttl = float(os.environ.get("HABIDAT_SECURITY_CACHE_TTL", 24 * 3600))
    fetcher = Fetcher(args.cache, ttl, args.offline)
    expected_ports = {
        p.strip() for p in os.environ.get("HABIDAT_SECURITY_EXPECTED_PORTS", "22,80,443").split(",") if p.strip()
    }
    months = int(os.environ.get("HABIDAT_SECURITY_ABANDONED_MONTHS", "12") or 12)

    report = Report()
    read_checks(report, raw)
    volumes = read_volumes(raw)
    data = args.data
    with_host = not args.module_only
    tooling = [re.compile(r[0]) for r in load_rules(os.path.join(data, "tooling-paths"), 1)]
    epss_threshold = epss_threshold_from_env(report)
    with_images = not args.host_only
    if with_images:
        analyse_vulnerabilities(report, inventory, report_dir, volumes, tooling, epss_threshold)
    analyse_docker(report, raw, inventory, load_rules(os.path.join(data, "expected-mounts"), 1), with_host)
    analyse_exposure(report, raw, inventory, expected_ports, with_host)
    if with_host:
        analyse_host(report, raw, today)
        analyse_tls(report, raw, today)
        analyse_config(report, args.base)
    analyse_eol(report, inventory, report_dir, load_rules(os.path.join(data, "eol-products"), 3), fetcher, today,
                raw, with_host, with_images)
    if with_images:
        analyse_hub(report, inventory, load_rules(os.path.join(data, "moved-images"), 2), fetcher, today, months)
        analyse_outdated(report, inventory, args.target)
        analyse_hooks(report, raw, args.target)

    for group, label, url in (("eol", "end-of-life data", "endoflife.date"), ("hub", "image metadata", "hub.docker.com")):
        if fetcher.failures.get(group):
            report.check(f"{group}.fetch", "failed",
                         f"could not reach {url} for {label}: {', '.join(sorted(set(fetcher.failures[group]))[:5])}")
        elif fetcher.stale.get(group):
            report.check(f"{group}.fetch", "ok", f"{url} unreachable, used cached {label}")

    findings = sorted(report.findings.values(), key=lambda f: f["id"])
    rules, warnings = load_accepted(args.accepted, today)
    expired = apply_accepted(findings, rules, today)
    exit_code, hits = compute_exit(findings, report.checks, threshold)
    packages = package_groups(report, findings)

    accepted_count = sum(1 for f in findings if f.get("accepted"))
    failed = [c for c in report.checks if c["status"] == "failed"]
    extra = [f"warning: {w}" for w in warnings]
    extra += [f"acceptance expired: {fid} (finding is active again)" for fid in expired]
    extra.append(
        f"{len(hits)} finding(s) to act on (urgent vulnerabilities, other findings at {threshold} or above)"
        + (f", {accepted_count} accepted" if accepted_count else "")
        + (f", {len(failed)} check(s) could not run" if failed else "")
        + f" -> exit {exit_code}"
    )
    extra.append(f"report: {os.path.relpath(report_dir, args.base) if args.base else report_dir}/")
    lines = render_summary(findings, report.checks, inventory, threshold, args.verbose, args.color, extra,
                           packages)

    scanners = read_json(os.path.join(raw, "scanners.json"), {}) or {}
    write_json(os.path.join(report_dir, "report.json"), {
        "started": args.started,
        "target": "host" if args.host_only else args.target or "all",
        "options": {
            "all_images": args.all_images, "host_audit": args.host_audit,
            "tls_full": args.tls_full, "severity": threshold,
            "epss_threshold": epss_threshold,
        },
        "scanners": scanners,
        "checks": report.checks,
        "findings": findings,
        "vulnerabilities": packages,
        "exit_code": exit_code,
    })
    plain = [re.sub(r"\033\[[0-9;]*m", "", line) for line in lines]
    with open(os.path.join(report_dir, "summary.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(plain) + "\n")
    print("\n".join(lines))
    return exit_code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    inv = sub.add_parser("inventory")
    inv.add_argument("--raw", required=True)
    inv.add_argument("--prefix", required=True)
    inv.add_argument("--target")
    inv.add_argument("--instance")
    inv.add_argument("--all-images", action="store_true")

    ana = sub.add_parser("analyse")
    ana.add_argument("--report", required=True)
    ana.add_argument("--cache", required=True)
    ana.add_argument("--accepted", required=True)
    ana.add_argument("--data", required=True)
    ana.add_argument("--base", default="")
    ana.add_argument("--severity", default="HIGH", choices=SEVERITIES + [s.lower() for s in SEVERITIES])
    ana.add_argument("--target")
    ana.add_argument("--module-only", action="store_true")
    ana.add_argument("--host-only", action="store_true",
                     help="the server itself: no image vulnerabilities, image end of life, Docker Hub or module checks")
    ana.add_argument("--all-images", action="store_true")
    ana.add_argument("--host-audit", action="store_true")
    ana.add_argument("--tls-full", action="store_true")
    ana.add_argument("--verbose", action="store_true")
    ana.add_argument("--color", action="store_true")
    ana.add_argument("--offline", action="store_true")
    ana.add_argument("--today")
    ana.add_argument("--started", default=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    args = parser.parse_args(argv)
    if args.cmd == "inventory":
        return build_inventory(args)
    return run_analyse(args)


if __name__ == "__main__":
    sys.exit(main())
