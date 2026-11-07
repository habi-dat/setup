# Restore at the snapshot's version, then update; never run setup

A restore puts back `store/<module>/` (which already holds the rendered compose file and `passwords.env`) and the module's data at the module version recorded in the snapshot, starts the module, runs its link steps (ADR 0007), and then runs the normal `./habidat.sh update` to reach the repo's current version. It never runs `setup.sh`, because setup generates new secrets that would no longer match the restored data, and some secrets (the listmonk API token, Vaultwarden bot credentials) cannot be generated again at all. Restoring older data straight into newer code is not an option either: Nextcloud, for one, only upgrades.

## Consequences

- Old versioned restore scripts and `versions/<v>/` templates must stay in the repo for as long as snapshots of those versions may exist. Deleting an old version directory breaks restores of old snapshots.
- On a fresh server, `install backup`, `snapshots` and `restore` work without `setup.env`. `restore all <snapshot>` puts `setup.env` back first, then restores the modules in dependency order. `store/backup/` is never restored over the local one, because the new server has its own SSH key.
- Domain and Docker prefix come from the snapshot, because every volume name contains the prefix. Restoring under a different domain is out of scope.
- Taking over the backup repository from a new server asks for confirmation and warns when the newest snapshot is less than 24 hours old, since the old server may still be writing to it.
- The smallest unit of restore is a module instance.
