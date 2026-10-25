# vaultwarden-sync

Sidecar of the `vaultwarden` module. It mirrors the users and groups of habidat-auth (read from its LDAP) into the single Vaultwarden organization every few minutes. habidat-auth itself is not changed.

The image is built locally by the module (`compose build sync`). It runs on Node 24, with TypeScript executed through Node's native type stripping, so there is no build step. Its dependencies are `ldapts` and a pinned `@bitwarden/cli` (bw).

## What a run does

Identities are matched by LDAP `entryUUID`, which becomes the Vaultwarden `externalId` of members, groups and group collections. It stays stable when a slug or DN is renamed. A group's name is its `o` attribute, or `cn` if there is no `o`.

The **confirmation bot** and the **owner** (`VW_OWNER_EMAIL`) are excluded from every step. The bot's email is read from its own profile.

1. **Read LDAP.**
   - Users are read from `inetOrgPerson` entries under `LDAP_USERS_DN`. Users without `mail` are logged and skipped.
   - Groups are read from `groupOfNames` entries under `LDAP_GROUPS_DN`.
   - A group's members are its direct user members plus, transitively, the users of every group listed in its `member` attribute. Cycles are handled. `owner` is ignored.
   - **Safety stop:** the run aborts before changing anything if LDAP returns no users. It also aborts if a single run would remove more than allowed in one of these categories:
     - revoked members, out of all synced members;
     - deleted groups, out of all synced groups;
     - disabled accounts, out of all enabled accounts.

     The limit per category is `max(1, floor(SYNC_MAX_REMOVAL_RATIO × current))`.
2. **Import** with `POST /api/public/organization/import` (org API key, `overwriteExisting=false`).
   - Every LDAP user with a mail address is sent as a member.
   - Members whose `externalId` is no longer in LDAP are sent with `deleted: true`, which revokes them. Revoked members whose email is back in LDAP are restored by the same import.
   - Every LDAP group is sent with its transitive member list. Vaultwarden replaces group memberships on every import.
   - New members start out as Invited. Without SMTP they are accepted automatically once they set their master password; existing accounts are accepted right away.
3. **Groups.**
   - Groups whose `externalId` vanished from LDAP are deleted. Groups without an `externalId` (made by hand) are never touched.
   - Renamed groups get a `PUT` that sends back their current collections and users, because the 1.37.4 import does not rename groups.
4. **Group collections.** Every LDAP group has one collection, with `externalId` = the group's `entryUUID`.
   - **Missing collections** are created with `bw create org-collection`. Collection names are encrypted, which is why bw is used here. The group's own entry is `readOnly:false, hidePasswords:false, manage:true`.
   - **Existing collections** are checked on every run:
     - The group's own manage assignment is restored if someone removed or weakened it.
     - The collection is renamed together with its group.
     - Assignments to other groups and users are kept.
   - **Collections of deleted groups** are left alone, so after the group is gone only the owner can still reach them.
5. **Confirm.** Members that are Accepted, of type User, and whose email exists in LDAP are confirmed with `bw confirm org-member`; bw encrypts the org key for them. Accepted members with an unknown email are logged and skipped.
6. **Promote.** Members that are Confirmed, of type User, and in LDAP become **Manager** (without access-all) via `PUT /organizations/<org>/users/<member>`. The request carries their current groups and direct collections, because that endpoint replaces both.
7. **Disable and re-enable accounts** through the `/admin` API.
   - **Disable:** enabled accounts whose email is not in LDAP are disabled. The bot and the owner are never disabled. Every account the sync disabled is recorded in `/state/disabled.json`.
   - **Re-enable:** only accounts recorded in `/state/disabled.json` are re-enabled, once their email is back in LDAP. Accounts an admin disabled by hand stay disabled.

Failures of single actions (one collection, one confirmation, …) are logged; the run continues and is marked as failed. A failed import stops the run.

## Environment

The module's compose file provides these variables through `sync.env` (settings) and `credentials.env` (written by `./habidat.sh configure vaultwarden`).

| Variable | Default | Meaning |
|---|---|---|
| `LDAP_URL` | – | e.g. `ldap://<prefix>-ldap:389` |
| `LDAP_BIND_DN`, `LDAP_BIND_PASSWORD` | – | `cn=admin,<base>` and its password |
| `LDAP_USERS_DN`, `LDAP_GROUPS_DN` | – | `ou=users,<base>`, `ou=groups,<base>` |
| `VW_URL` | – | Internal Vaultwarden URL, e.g. `http://<prefix>-vaultwarden` |
| `VW_ADMIN_TOKEN` | – | Plain `ADMIN_TOKEN` of Vaultwarden (for `/admin`) |
| `VW_OWNER_EMAIL` | – | Email of the organization owner (super admin) |
| `VW_ORG_ID` | – | Organization id |
| `VW_ORG_CLIENT_ID`, `VW_ORG_CLIENT_SECRET` | – | Organization API key (`organization.<id>`) |
| `VW_BOT_CLIENT_ID`, `VW_BOT_CLIENT_SECRET` | – | Personal API key of the bot (`user.<id>`) |
| `VW_BOT_MASTER_PASSWORD` | – | Master password of the bot (bw unlock) |
| `SYNC_INTERVAL_SECONDS` | `300` | Pause between runs (min. 30) |
| `SYNC_DRY_RUN` | `false` | Log the planned actions only |
| `SYNC_MAX_REMOVAL_RATIO` | `0.3` | Safety stop, see above. `1` disables it |
| `STATE_DIR` | `/state` | Persistent state directory |
| `BW_PROXY_PORT` | `8087` | Loopback port of the TLS proxy for bw |

If any required variable is missing, the container logs `not configured yet, run ./habidat.sh configure vaultwarden` with the missing names, writes that to `last-run.json`, and then idles instead of crash-looping (`--once` exits 1). Restart it after running `configure`.

## Command line

```
node src/main.ts             # loop forever (container default)
node src/main.ts --once      # single run; exit 0 ok, 1 errors or not configured, 3 safety stop
node src/main.ts --dry-run   # combine with --once to only print the plan
node src/main.ts --health    # exit 0 if the last real run succeeded recently (HEALTHCHECK)
```

Inside the running container: `docker compose exec sync node src/main.ts --once --dry-run`. A lock file in `/state` keeps a manual run from overlapping with the loop.

## State directory (`/state`, must be a persistent volume)

| File | Content |
|---|---|
| `last-run.json` | Result of the last real (non-dry) run: `ok`, `aborted`, `error`, `summary`, timestamps |
| `disabled.json` | Accounts disabled by the sync, so that only those are re-enabled |
| `bw/` | bw CLI login state (stays logged in between runs) |
| `tls/` | Self-signed certificate of the loopback TLS proxy |
| `admin-session.json` | Reused `/admin` session cookie (the admin login is rate limited) |
| `device-id` | Stable device identifier for the bot's API logins |

## Implementation notes

- **bw needs HTTPS.** bw 2026.10 refuses every server URL that is not `https://` (`InsecureUrlNotAllowedError`). The sync therefore listens on `https://127.0.0.1:$BW_PROXY_PORT` and forwards requests to `VW_URL`.
  - The proxy uses a self-signed certificate, which only the bw subprocess trusts (via `NODE_EXTRA_CA_CERTS`).
  - REST calls made by the sync itself go to `VW_URL` directly.
- **Manager shows up as type 4.** Vaultwarden reports Manager members as type 4 ("custom") in member listings. Promotion sends type 3.
- **Admin cookie.** `/admin` requests carry `X-Forwarded-Proto: https`. The session cookie is reused until Vaultwarden rejects it.
- **Email changes.** Members are matched by email in Vaultwarden's import. If a user's email changes in auth, the import invites the new address, and the old account stays in the organization until an admin removes it.

## Development

```bash
npm ci
npm test            # node --test, unit tests of the pure diff logic in src/plan.ts
npm run typecheck   # tsc --noEmit
```

`src/plan.ts` holds all decisions as pure functions. `src/vw.ts` (REST), `src/bw.ts` (bw CLI), `src/ldap.ts`, and `src/main.ts` only fetch and execute.

### End-to-end smoke test

`smoke/run.sh` needs Docker only. It works like this:

1. It builds the image and starts `vaultwarden/server:1.37.4` and `osixia/openldap:1.3.0`, the same image habidat-auth uses.
2. It seeds LDAP with nested and cyclic groups.
3. It bootstraps the organization the way the manual one-time setup does: the owner, the bot as a confirmed Admin, and both API keys. Doing that needs client-side crypto, which lives in `smoke/client.ts`.
4. It runs the sync through four phases, each followed by a check:
   - a dry run, which must change nothing;
   - the first real run;
   - a run after an LDAP change (group renamed, group deleted, user deleted) and a manually removed collection assignment;
   - a run after the deleted user comes back.

```bash
vaultwarden/sync/smoke/run.sh          # KEEP=1 leaves the containers running
```
