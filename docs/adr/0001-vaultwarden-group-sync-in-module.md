# Vaultwarden group sync runs as a container in the vaultwarden module, reading LDAP

Vaultwarden has no LDAP sync and no IdP group mapping upstream; it only accepts a full member/group list per organization via `POST /api/public/organization/import`. We run a small sync container inside the `vaultwarden` module that reads groups from habidat-auth's LDAP (nested groups flattened, so sub-group members count as parent-group members), pushes the complete list every few minutes, and is the only component holding Vaultwarden credentials. habidat-auth stays unaware of Vaultwarden, and no `groups` claim is needed in its OIDC tokens — group membership is decided by the sync, not at login.

## Considered Options

- **habidat-auth worker target (like Discourse)**: instant, reuses the outbox/retry queue, but needs a schema migration and auth release, and the confirmation bot's master password would not belong in auth anyway — so it would be two components instead of one. The import API is full-state, so event-driven sync only buys minutes of latency.
- **OIDCWarden fork (login-time group mapping)**: aborts sync when one IdP group matches groups in several orgs, cannot create groups, and revokes only on next login; plus fork dependency.
- **Bitwarden Directory Connector**: no official image, plaintext secrets in `data.json`, never deletes groups, DN-based externalIds break on rename, hash cache hides manual drift.
- **chistokhinsv/vaultwarden-ldap-sync**: only invites/revokes org members; does not create or fill Vaultwarden groups; unmaintained since 2025-07.
