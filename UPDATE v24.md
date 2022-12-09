# export auth

```
./habidat.sh export auth
```

# export nexcloud

```
./habidat.sh export auth nodata
```

# export discourse

```
./habidat.sh export discourse
```

## preparation for new auth tool

# copy saml key files to new directory

```
cd store/auth/cert
mkdir saml
cp server.cert saml/cert.cer
cp server.pem saml/key.pem
chmod +r saml/key.pem
```

# pull new habidat-setup

```
git pull
git checkout 24.0.1
```

# update auth

```
./habidat.sh update auth
```

# copy new emailtemplate store

```
docker exec -it habidat-user bash
cp templates/emailTemplateStore.json data
exit
```

# update nextcloud

```
update all aps in admin panel
./habidat.sh update nextcloud
```
