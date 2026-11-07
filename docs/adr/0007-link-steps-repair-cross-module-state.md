# Link steps repair cross-module state after a restore

Several modules write into other modules' state: nextcloud and discourse add lines to `store/auth/auth.env`; listmonk, mediawiki, website and vaultwarden add app files to `store/auth/user-import/` and login apps to the auth database; auth adds to `store/nginx/networks.env`; dokuwiki and direktkredit add to `store/nextcloud/nextcloud.env`. Restoring one module's `store/<module>/` therefore silently drops what other modules added after the snapshot. We restore the folder whole anyway, and every module gets a repeatable link step that rewrites everything it contributes elsewhere from its own `store/<module>/`. After a restore, the restored module runs its link step; if it is one others write into (auth, nextcloud, nginx), every installed module that links into it runs its link step too.

## Considered Options

- **Give every file exactly one owner** (e.g. nextcloud writes `store/nextcloud/for-auth.env` and auth's compose file reads it). Cleaner ownership, but it changes five setup scripts and makes auth's template depend on which modules are installed, while restores would still need to fix the auth database. Link steps solve both with one mechanism.

## Consequences

- In the auth database a link step creates a missing app with its install-time group, but on an existing app only updates what must match the module's own files: OIDC client ID, client secret and redirect URIs. It never touches groups, name or URL, so an admin's changes survive. It therefore does not run `user-init`.
- habidat-auth's startup import currently re-attaches install-time groups to apps that already exist (`packages/db/prisma/seed.ts`), which brings back group access an admin removed whenever any module is installed. That needs a separate change in habidat-auth.
- Link steps only add. Restoring auth from before a module was removed brings back that module's stale entries until `remove` gets a matching unlink.
