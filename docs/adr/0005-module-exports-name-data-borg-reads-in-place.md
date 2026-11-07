# Module exports name their data; borg reads it in place

Every module (except mailtrain, being retired, and direktkredit, whose data lives in an external platform repo) owns a versioned export and restore script. The export writes uncompressed database and LDAP dumps into a staging folder while services keep running, and names the Docker volumes and the `store/<module>/` path that belong to the module. The backup module mounts those read-only into a pinned borg 1.4 container and stores one archive per run with a manifest (module versions, module instances, repo commit, Docker prefix, per-module success). `./habidat.sh export` packs the same set into a `.tar.gz` for a one-off local export. We chose this because the existing exports produce `.tar.gz` files: borg cannot deduplicate a freshly compressed archive, so a large Nextcloud would be uploaded in full every night, and staging the copy would need the same amount of free disk.

## Considered Options

- **The backup module knows how to back up every module.** One place to read, but every module change would have to touch the backup module, and the existing versioned export/import plumbing would go unused.
- **Stop all modules for the backup.** Fully consistent, but minutes of downtime every night. Instead, modules that need it quiesce themselves (Nextcloud uses maintenance mode while it is dumped).

## Consequences

- The four existing export/import pairs (auth, nextcloud, discourse, vaultwarden) are rewritten to the new contract, and `import` is renamed `restore` (kept one release as an alias for `restore --file`).
- A failing module is marked as failed in the snapshot's manifest instead of aborting the whole run.
- Snapshots contain every secret in `store/`, including the Vaultwarden confirmation bot's credentials (see ADR 0003), so whoever holds the backup repository's passphrase and key can read every shared password. The key is `repokey-blake2`; the passphrase and exported key are shown once at setup for offline storage.
