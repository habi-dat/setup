# pull previous version

git checkout 27.1.2

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
git checkout 28.0.4
```

# update nextcloud

NOTE: please make sure to have docker compose plugin installed so `docker compose` commands work (previously the outdated `docker-compose` standalone command was used)

```
update all apps in admin panel
./habidat.sh update nextcloud
```

# checkout master again

git checkout master
