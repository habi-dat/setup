# pull previous version

git checkout 34.0.3

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

# snapshot the nextcloud database volume

NOTE: this update also upgrades MariaDB from 10.6 (end of life since 2026-07-06)
to 11.8, the version recommended by nextcloud 34. The data directory is upgraded
in place by `mariadb-upgrade`, and MariaDB does not support downgrading
afterwards. The exports above do not cover this - take a copy of the database
volume before updating, it is the only way back:

```
docker compose -f store/nextcloud/docker-compose.yml -p <prefix>-nextcloud stop -t 300 nextcloud cron db
docker run --rm -v <prefix>-nextcloud_db:/from -v "$PWD":/to alpine \
  tar -czf /to/nextcloud-db-volume.tar.gz -C /from .
```

# pull new habidat-setup

```
git checkout 34.0.4
```

# update nextcloud

```
update all apps in admin panel
./habidat.sh update nextcloud
```

The migration stops the stack with a 5 minute timeout so InnoDB shuts down
cleanly, then starts MariaDB 11.8 with `MARIADB_AUTO_UPGRADE=1` and waits for
the container to report healthy before touching nextcloud. Expect the database
to take a few minutes on the first start. A dump of the old system tables is
left in the volume as `system_mysql_backup_*.sql.zst`.

# checkout master again

git checkout master

# notes

- Since MariaDB 11.4.2 a `SET NAMES utf8mb4` - which is what the nextcloud
  database connection does - resolves to `utf8mb4_uca1400_ai_ci` instead of
  `utf8mb4_general_ci`. The nextcloud tables are `utf8mb4_bin`, so the new
  connection collation would cause "Illegal mix of collations" errors. The
  compose file therefore pins the old default with
  `--character-set-collations=utf8mb4=utf8mb4_general_ci`, which reproduces the
  10.6 behaviour exactly. Verified on the installation before updating:

  ```
  -- tables and columns: utf8mb4_bin
  select table_collation, count(*) from information_schema.tables
    where table_schema='nextcloud' group by table_collation;
  select collation_name, count(*) from information_schema.columns
    where table_schema='nextcloud' and collation_name is not null group by collation_name;
  -- database default and server: utf8mb4 / utf8mb4_general_ci
  select default_character_set_name, default_collation_name
    from information_schema.schemata where schema_name='nextcloud';
  show variables like 'collation%';
  ```

  If another installation reports different values, adjust
  `--character-set-collations` in
  `nextcloud/versions/34.0.4/docker-compose.yml.j2` to the collation that
  `collation_server` shows there before updating.

- The `mysql` and `mysqldump` symlinks are gone from the MariaDB docker image as
  of 11.0. `export`/`import` use `mariadb-dump`/`mariadb` from 34.0.4 on
  (`nextcloud/export/34.0.4.sh`, `nextcloud/import/34.0.4.sh`); the 34.0.3
  scripts are kept unchanged for installations still running 10.6.

- MariaDB 12.3 LTS is deliberately not used yet: nextcloud 34 supports
  10.6 / 10.11 / 11.4 / 11.8 only and would show a setup check warning. 12.3
  becomes the target with nextcloud 35, which drops 10.6 and adds 12.3.
