# pull previous version

git checkout 30.0.5

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
git checkout 31.0.2
```

# update nextcloud

```
update all apps in admin panel
./habidat.sh update nextcloud
```

# checkout master again

git checkout master
