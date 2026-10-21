# pull previous version

git checkout 34.0.4.1

# export auth

```
./habidat.sh export auth
```

# export nexcloud

```
./habidat.sh export nextcloud nodata
```

# export discourse

```
./habidat.sh export discourse
```

# pull new habidat-setup

```
git checkout 35.0.2
```

# update nextcloud

```
update all apps in admin panel
./habidat.sh update nextcloud
```

This is a major upgrade (34 -> 35). Majors cannot be skipped: the instance has
to be on 34.0.4 / 34.0.4.1 before running this. The image entrypoint runs
`occ upgrade` on the first start, the migration waits for maintenance mode to
end (up to 15 minutes).

Apps whose installed release does not declare support for 35 are disabled by
`occ upgrade`. The migration records the enabled apps before pulling the new
image, runs `occ app:update --all` afterwards and re-enables everything that was
enabled on 34. An app without a 35 release stays disabled with a warning in the
output.

# checkout master again

git checkout master

# notes

- The database stays on MariaDB 11.8. Nextcloud 35 dropped MariaDB 10.6 (which
  34.0.4 already left behind) and supports 10.11 / 11.4 / 11.8 / 12.3. 12.3 is
  now the recommended version, but 11.8 is a supported LTS, so the database
  upgrade is deliberately not bundled with the nextcloud major upgrade. No
  volume snapshot is needed for this update, the exports above are enough.

- Nextcloud 35 requires PHP 8.3 or newer (8.2 dropped). The official image ships
  a supported version, nothing to do.

- The 34.0.4 export/import scripts (`mariadb-dump`/`mariadb`) are used for 35.0.2
  as well, there is no separate 35.0.2 script.

- After the update check `Administration settings -> Overview` for setup
  warnings and run

  ```
  docker exec -u www-data <prefix>-nextcloud php occ db:schema:check
  ```

  There are community reports of NC 35 upgrades where this lists a missing
  `oc_federated_invites` table (cloud_federation_api / contacts), with no
  confirmed fix yet:
  https://help.nextcloud.com/t/nc35-update-breaks-database-occ-upgrade-occ-dbcheck-lists-multiple-errors-warnings/250764
  If it shows up, note it before touching anything - it does not block login or
  file access in the reported cases.

- After a major upgrade nextcloud schedules background migrations. They are run
  by the cron container; let them finish (a few cron runs) before the next
  major upgrade.
