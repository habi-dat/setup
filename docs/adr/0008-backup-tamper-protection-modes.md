# Two ways to protect backups from a compromised server

The server pushes its snapshots over SSH to one backup repository per installation, so whoever takes over the server also holds a key to its backups. The backup module offers two `protection` modes. `provider-snapshots` is for a Hetzner Storage Box: each installation uses its own sub-account, the server prunes and compacts normally every night, and the box's automatic snapshots (read-only for SSH users, managed in the Hetzner Console) let an attack be undone. `append-only` is for a self-run SSH server: the server's key is locked in `authorized_keys` to `borg serve --append-only --restrict-to-repository …`, so its `prune` only marks snapshots as deleted, and space is freed by hand from a trusted machine. We did not use append-only on Hetzner because forcing a command in `authorized_keys` is not in Hetzner's documentation, and a Storage Box cannot run scheduled jobs to free space.

## Consequences

- With `provider-snapshots`, an attack can be undone only for as many days as the box has snapshot slots (10 to 40 depending on plan). The alerts for "no successful snapshot in 36 hours" and "number of snapshots dropped sharply" are what make that window enough.
- Rolling a Storage Box back to a snapshot rolls back the whole box, every sub-account and all newer box snapshots. To recover one installation, copy its directory out of `.zfs/snapshot/<name>/` instead of rolling back.
- With `append-only`, freeing space happens through `borg compact` or any write from a key without the append-only restriction, and that permanently removes everything marked as deleted, including an attacker's deletions. Check the repository before running it. `borg compact` does not need the repository key. Until then, a deletion can be rolled back by hand as described in borg's append-only notes.
- Borg runs as 1.4 and always passes `--remote-path=borg-1.4`, because Hetzner offers 1.1, 1.2 and 1.4 with 1.2 as the default.
- Every new server, including one built for a restore, gets its own SSH key, and an admin adds its `authorized_keys` line on the target by hand, so a habidat server never holds an admin login to the backup storage.
