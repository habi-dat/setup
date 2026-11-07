#!/usr/bin/env python3
"""Write a synthetic security-check report tree for tests/50_security.bats.

    security_fixture.py <dir>

Creates <dir>/report (raw data as lib/security.sh would collect it, plus SBOM
and Grype output), <dir>/cache (endoflife.date and Docker Hub responses, so the
analyser never needs the network) and <dir>/base/setup.env.

The installation (prefix "hab", domain example.org) has:

  nginx      hab-nginx           jwilder/nginx-proxy (moved), 80/443, docker.sock
  auth       hab-user            habidat/auth:2.2 (Alpine 3.20 EOL, Node 24, Next 15)
             hab-ldap            osixia/openldap:1.3.0 (tag stale), 389 on 0.0.0.0
  nextcloud  hab-nextcloud       habidat/nextcloud:32.0.5 (PHP 8.2, Nextcloud 32)
  mediawiki  hab-mediawiki-wiki1 habidat/mediawiki (floating tag), instance wiki1
  discourse  hab-discourse       local_discourse/app (built locally, no compose labels)
  foreign    portainer           portainer/portainer-ce:latest, privileged, docker.sock, 9000
  unused     mongo:4.4           (only with --all-images)
"""

import json
import os
import sys

TODAY = "2026-11-07"


def sha(c):
    return "sha256:" + c * 64


IDS = {
    "nginx": sha("d"),
    "auth": sha("c"),
    "ldap": sha("b"),
    "nextcloud": sha("a"),
    "mediawiki": sha("e"),
    "discourse": sha("f"),
    "portainer": sha("1"),
    "mongo": sha("2"),
}


def container(name, image_key, ref, project=None, env=None, ports=None, privileged=False, sock=False):
    labels = {"com.docker.compose.project": project} if project else {}
    return {
        "Name": "/" + name,
        "Image": IDS[image_key],
        "Config": {"Image": ref, "Labels": labels, "Env": env or []},
        "HostConfig": {"Privileged": privileged},
        "Mounts": [{"Source": "/var/run/docker.sock"}] if sock else [],
        "NetworkSettings": {"Ports": ports or {}},
    }


def image(key, tags, env=None, local=False):
    return {
        "Id": IDS[key],
        "RepoTags": tags,
        "RepoDigests": [] if local else [tags[0].split(":")[0] + "@" + sha("9")],
        "Config": {"Env": env or []},
    }


def release(name, eol, is_eol, maintained=None):
    return {
        "name": name, "isEol": is_eol, "eolFrom": eol,
        "isMaintained": (not is_eol) if maintained is None else maintained,
    }


def eol(product, label, releases):
    return {"result": {"name": product, "label": label, "releases": releases}}


def hub(last, description="", archived=None):
    return {"last_updated": last + "T00:00:00Z", "description": description, "is_archived": archived}


def grype_match(vid, pkg, version, ptype, severity, fixed_in=None, kev=False, epss=None, path=None):
    vuln = {
        "id": vid, "severity": severity, "dataSource": f"https://example.invalid/{vid}",
        "fix": {"state": "fixed", "versions": [fixed_in]} if fixed_in else {"state": "not-fixed", "versions": []},
        "knownExploited": [{"cve": vid, "knownRansomwareCampaignUse": "Unknown"}] if kev else None,
        "epss": [{"cve": vid, "epss": epss, "percentile": 0.9, "date": "2026-11-06"}] if epss is not None else [],
    }
    artifact = {"name": pkg, "version": version, "type": ptype,
                "locations": [{"path": path or "/lib/apk/db/installed"}]}
    return {"vulnerability": vuln, "artifact": artifact}


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        if isinstance(data, str):
            fh.write(data)
        else:
            json.dump(data, fh, indent=1)


def slug(key):
    return IDS[key].split(":", 1)[1][:12]


def main(root):
    report = os.path.join(root, "report")
    raw = os.path.join(report, "raw")
    cache = os.path.join(root, "cache")

    containers = [
        container("hab-nginx", "nginx", "jwilder/nginx-proxy", "hab-nginx", sock=True,
                  ports={"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "80"}],
                         "443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "443"}]}),
        container("hab-user", "auth", "habidat/auth:2.2", "hab-auth", env=["VIRTUAL_HOST=user.example.org"]),
        container("hab-ldap", "ldap", "osixia/openldap:1.3.0", "hab-auth",
                  ports={"389/tcp": [{"HostIp": "0.0.0.0", "HostPort": "389"}],
                         "636/tcp": [{"HostIp": "127.0.0.1", "HostPort": "636"}]}),
        container("hab-nextcloud", "nextcloud", "habidat/nextcloud:32.0.5", "hab-nextcloud",
                  env=["VIRTUAL_HOST=cloud.example.org"]),
        container("hab-mediawiki-wiki1", "mediawiki", "habidat/mediawiki", "hab-mediawiki-wiki1",
                  env=["VIRTUAL_HOST=wiki1.mediawiki.example.org"]),
        container("hab-discourse", "discourse", "local_discourse/app"),
        container("portainer", "portainer", "portainer/portainer-ce:latest", "portainer", privileged=True,
                  sock=True, ports={"9000/tcp": [{"HostIp": "0.0.0.0", "HostPort": "9000"}]}),
    ]
    images = [
        image("nginx", ["jwilder/nginx-proxy:latest"]),
        image("auth", ["habidat/auth:2.2"], env=["NODE_VERSION=24.22.1"]),
        image("ldap", ["osixia/openldap:1.3.0"]),
        image("nextcloud", ["habidat/nextcloud:32.0.5"], env=["PHP_VERSION=8.2.29", "NEXTCLOUD_VERSION=32.0.5"]),
        image("mediawiki", ["habidat/mediawiki:latest"]),
        image("discourse", ["local_discourse/app:latest"], local=True),
        image("portainer", ["portainer/portainer-ce:latest"]),
        image("mongo", ["mongo:4.4"]),
    ]
    write(os.path.join(raw, "containers.json"), containers)
    write(os.path.join(raw, "images.json"), images)
    write(os.path.join(raw, "installed.tsv"), "".join(
        "\t".join(row) + "\n" for row in [
            ("nginx", "1.0.0", "1.0.0", "0", ""),
            ("auth", "2.1.1", "2.2.0", "0", ""),
            ("nextcloud", "35.0.2", "35.0.2", "0", ""),
            ("discourse", "3.4.0", "3.4.0", "0", ""),
            ("mediawiki", "1.35.8", "1.35.8", "1", "wiki1"),
        ]))
    write(os.path.join(raw, "checks.tsv"), "host.needrestart\tok\t\n")

    # Image scans. Urgent in auth: CVE-2026-0004 (KEV), CVE-2026-0005 (MEDIUM
    # with high EPSS) and CVE-2026-0008 (KEV, no fix). Not urgent: the npm HIGH
    # (low EPSS), the unfixed CRITICAL, the MEDIUM, BEAST (high EPSS but
    # negligible) and the KEV in npm's own tar (tooling).
    write(os.path.join(report, "sbom", slug("auth") + ".syft.json"), {
        "distro": {"id": "alpine", "versionID": "3.20.3"},
        "artifacts": [
            {"name": "next", "version": "15.0.0", "type": "npm"},
            {"name": "node", "version": "24.22.1", "type": "binary"},
        ],
    })
    write(os.path.join(report, "grype", slug("auth") + ".json"), {"matches": [
        grype_match("GHSA-next-0001", "next", "15.0.0", "npm", "High", "15.0.9", epss=0.004,
                    path="/app/node_modules/next/package.json"),
        grype_match("CVE-2026-0002", "busybox", "1.36.1-r0", "apk", "Critical"),
        grype_match("CVE-2026-0003", "zlib", "1.3.1-r0", "apk", "Medium", "1.3.2-r0"),
        grype_match("CVE-2026-0003", "zlib-dev", "1.3.1-r0", "apk", "Medium", "1.3.2-r0"),
        grype_match("CVE-2026-0004", "openssl", "3.3.2-r0", "apk", "High", "3.3.3-r0", kev=True, epss=0.83),
        grype_match("CVE-2026-0005", "libxml2", "2.12.7-r0", "apk", "Medium", "2.12.9-r0", epss=0.4),
        grype_match("CVE-2011-3389", "gnutls", "3.8.5-r0", "apk", "Negligible", epss=0.73),
        grype_match("GHSA-tar-0006", "tar", "6.2.1", "npm", "Critical", "7.5.19", kev=True, epss=0.5,
                    path="/usr/local/lib/node_modules/npm/node_modules/tar/package.json"),
        grype_match("GHSA-tar-0007", "tar", "6.2.1", "npm", "High", "7.5.21",
                    path="/usr/local/lib/node_modules/npm/node_modules/tar/package.json"),
        grype_match("CVE-2026-0008", "musl", "1.2.5-r0", "apk", "Critical", kev=True),
    ]})
    write(os.path.join(report, "sbom", slug("nextcloud") + ".syft.json"), {
        "distro": {"id": "debian", "versionID": "12"}, "artifacts": []})
    write(os.path.join(report, "grype", slug("nextcloud") + ".json"), {"matches": []})

    # Host.
    host = os.path.join(raw, "host")
    write(os.path.join(host, "os-release"), 'ID=debian\nVERSION_ID="12"\n')
    write(os.path.join(host, "apt-sim.txt"),
          "Inst openssl [3.0.15-1~deb12u1] (3.0.17-1~deb12u2 Debian-Security:12/stable-security [amd64])\n"
          "Inst tzdata [2025a-0+deb12u1] (2025b-0+deb12u1 Debian:12.12/stable [all])\n")
    write(os.path.join(host, "apt-lists-age"), "1\n")
    write(os.path.join(host, "needrestart.txt"),
          "NEEDRESTART-VER: 3.6\nNEEDRESTART-KCUR: 6.1.0-28-amd64\nNEEDRESTART-KEXP: 6.1.0-31-amd64\n"
          "NEEDRESTART-KSTA: 3\nNEEDRESTART-SVC: ssh.service\n")
    write(os.path.join(host, "unattended.txt"), "installed=no\nenabled=0\n")
    write(os.path.join(host, "ss.txt"),
          "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n"
          "LISTEN 0 128 0.0.0.0:5432 0.0.0.0:*\n"
          "LISTEN 0 128 127.0.0.1:3306 0.0.0.0:*\n"
          "LISTEN 0 128 [::]:389 [::]:*\n"
          "LISTEN 0 128 127.0.0.53%lo:53 0.0.0.0:*\n")
    write(os.path.join(host, "ufw.conf"), "ENABLED=yes\nLOGLEVEL=low\n")

    # Docker daemon: defaults everywhere, except log rotation is set.
    write(os.path.join(raw, "docker", "info.json"), {
        "ServerVersion": "26.1.4", "SecurityOptions": ["name=apparmor", "name=seccomp,profile=builtin"],
        "LiveRestoreEnabled": False, "LoggingDriver": "json-file"})
    write(os.path.join(raw, "docker", "daemon.json"), {"log-opts": {"max-size": "50m"}})
    write(os.path.join(raw, "docker", "bridge.json"), [{"Options": {"com.docker.network.bridge.enable_icc": "true"}}])

    # TLS: one certificate about to expire, one fine; testssl finds one HIGH.
    tls = os.path.join(raw, "tls")
    write(os.path.join(tls, "user.example.org.cert"),
          "connect=ok\nverify=0 (ok)\nnotafter=Nov 15 12:00:00 2026 GMT\nsubject=CN=user.example.org\nhostmatch=yes\n")
    write(os.path.join(tls, "cloud.example.org.cert"),
          "connect=ok\nverify=0 (ok)\nnotafter=Jan 30 12:00:00 2027 GMT\nsubject=CN=cloud.example.org\nhostmatch=yes\n")
    write(os.path.join(tls, "testssl-user.example.org.json"), [
        {"id": "TLS1", "severity": "HIGH", "finding": "offered (deprecated)"},
        {"id": "TLS1_3", "severity": "OK", "finding": "offered"},
        {"id": "scanProblem", "severity": "WARN", "finding": "something"},
    ])

    # Module hook output.
    write(os.path.join(raw, "hooks", "nextcloud.tsv"),
          "volume\thab-nextcloud\t/var/www/html/custom_apps\n"
          "finding\toutdated-app\tcalendar\tMEDIUM\tNextcloud app calendar 6.1.0 is available\tocc app:update calendar\n")

    # endoflife.date responses.
    eol_data = {
        "alpine-linux": eol("alpine-linux", "Alpine Linux", [
            release("3.24", "2028-05-01", False), release("3.20", "2026-04-01", True)]),
        "nodejs": eol("nodejs", "Node.js", [release("26", "2029-04-30", False), release("24", "2028-04-30", False)]),
        "nextjs": eol("nextjs", "Next.js", [release("16", None, False), release("15", "2026-12-01", False)]),
        "php": eol("php", "PHP", [release("8.5", "2029-12-31", False), release("8.2", "2026-12-31", False)]),
        "nextcloud": eol("nextcloud", "Nextcloud", [release("35", "2027-10-01", False), release("32", "2026-09-30", True)]),
        "debian": eol("debian", "Debian", [release("13", "2028-08-09", False), release("12", "2026-06-10", False)]),
        "docker-engine": eol("docker-engine", "Docker Engine", [release("29", None, False), release("26.1", "2025-02-01", True)]),
        "mongodb": eol("mongodb", "MongoDB", [release("4.4", "2024-02-29", True)]),
    }
    for product, data in eol_data.items():
        write(os.path.join(cache, "eol", product + ".json"), data)

    # Docker Hub responses (file names as the analyser's cache key).
    hub_data = {
        "habidat_auth": hub("2026-10-25"),
        "habidat_auth_2.2": hub("2026-10-25"),
        "osixia_openldap": hub("2026-10-27", "OpenLDAP container image"),
        "osixia_openldap_1.3.0": hub("2020-05-07"),
        "habidat_nextcloud": hub("2026-10-01"),
        "habidat_nextcloud_32.0.5": hub("2026-06-01"),
        "habidat_mediawiki": hub("2025-01-01", "MediaWiki for habi*DAT"),
        "portainer_portainer-ce": hub("2026-11-01"),
        "library_mongo": hub("2026-11-01"),
        "library_mongo_4.4": hub("2024-02-20"),
    }
    for key, data in hub_data.items():
        write(os.path.join(cache, "hub", key + ".json"), data)

    write(os.path.join(root, "base", "setup.env"), "HABIDAT_DOMAIN=example.org\n")
    os.chmod(os.path.join(root, "base", "setup.env"), 0o600)
    write(os.path.join(root, "accepted"), "")


if __name__ == "__main__":
    main(sys.argv[1])
