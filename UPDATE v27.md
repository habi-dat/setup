# pull previous version

git checkout 26.0.7

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
git checkout 27.1.2
```

# update nextcloud

```
update all apps in admin panel
./habidat.sh update nextcloud
```

# checkout master again

git checkout master
