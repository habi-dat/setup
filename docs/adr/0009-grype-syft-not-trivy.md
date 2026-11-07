# Grype and Syft, not Trivy, scan images in the security check

The security check scans container images with Syft (which lists everything inside an image) and Grype (which matches that list against known vulnerabilities), and uses no second scanner. Trivy is the better-known choice and covers OS and language packages equally well, but it does not see PHP or Node.js when they are compiled from source, which is how the official `php` and `node` images and most of ours ship them. Syft recognises those runtimes, and the MariaDB, PostgreSQL, Redis, MongoDB, nginx and OpenLDAP servers, from their binaries, and the same Syft list is what the end-of-life check reads versions from. Trivy was also compromised twice in 2026 (CVE-2026-33634: a malicious release, images and CI action tags), which made pinning mandatory either way but tipped the balance.

## Consequences

- Both scanners run as containers pinned by version and image digest, never `latest`. Updating them is a deliberate change in the repo.
- Accepted findings, the end-of-life product map and the saved reports use Grype's vulnerability IDs and Syft's package names. Switching scanners later means migrating the accepted-findings file and the map.
- Grype matches runtime binaries against NVD CPEs, which produces more false positives than distro-package matching. Accepted findings are the way to live with those.
- Grype downloads its vulnerability database at run time without an account; a security check without network access cannot check vulnerabilities.
