# pull previous version

git checkout 34.0.4

# pull new habidat-setup

```
git checkout 34.0.4.1
```

# update nextcloud

Config-only step: Nextcloud stays on image `34.0.4`. It clears SAML displayName/email/quota mappings (LDAP remains the source) and removes the `discoursesso` app.

```
./habidat.sh update nextcloud
```

# retarget DiscourseConnect to habidat-auth

Discourse still used the Nextcloud plugin URL. After this, `discourse_connect_url` / `logout_redirect` point at habidat-auth `/sso/discourse`. This rebuilds Discourse.

```
./habidat.sh update discourse
```

# checkout master again

git checkout master

# notes

- `general-uid_mapping=uid` is unchanged. Display name, email and quota are no longer copied from the SAML assertion; Nextcloud keeps reading `cn` / `mail` / `description` from LDAP.
- Existing Nextcloud accounts that already got a SAML quota override of `default` are not reset by this update. Fix those in Nextcloud (set quota back to default / LDAP) if they drifted.
- The DiscourseConnect shared secret is still `HABIDAT_DISCOURSE_SSO_SECRET` from `store/nextcloud/passwords.env` (copied into auth). Only the SSO URL changes.
