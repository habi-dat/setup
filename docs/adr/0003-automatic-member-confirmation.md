# Members are confirmed automatically by a bot; Vaultwarden runs without SMTP

Vaultwarden only grants a new member access to shared passwords after an Owner/Admin client encrypts the organization key for them ("confirm"), and only once the member has "accepted". We want auth group membership to be all it takes, so a confirmation bot (an organization Admin whose API key and master password live in `store/vaultwarden/passwords.env`) runs `bw confirm` from the sync container. Vaultwarden runs without SMTP, because only then does setting the initial master password accept pending invitations automatically; with SMTP every user would have to click an invite link.

## Consequences

- This deliberately weakens Bitwarden's end-to-end guarantee. Without the bot, a copy of the server (database, backups) exposes only ciphertext; with it, the bot's credentials on the server unlock the organization key, so anyone who can read `store/vaultwarden/passwords.env`, or can change group membership in auth, can read every shared password. Personal vaults are unaffected.
- The bot only confirms pending members whose email belongs to an auth user in the current sync; anything else is left unconfirmed and logged. This closes the route of inserting a member directly into Vaultwarden's database, not the route of stealing the bot's credentials.
- Groups that need protection against server compromise can get a separate, manually confirmed organization without the bot (and without the super admin) on request; it is not part of the automated setup.
- Vaultwarden's own emails (welcome, new-device notice, password hint, email 2FA) are unavailable and emergency access is limited.
