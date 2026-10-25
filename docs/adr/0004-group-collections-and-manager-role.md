# Every group gets a collection automatically; every user is a Manager without "access all"

We want anyone to be able to share passwords with any group without asking an admin. Vaultwarden only lets Owners, Admins, or Managers with "access all" create collections, and all of those see every password, so free collection creation by users is impossible without giving up isolation between groups. Instead the sync (as the confirmation bot) creates one group collection per auth group, gives that group "manage" on it, and makes every member a Manager *without* "access all": they still see only collections shared with their groups, but can share their group collections with any other group. Additional collections come from creating an auth sub-group, or from the super admin on request.

## Consequences

- The sync re-asserts each group's access to its own group collection on every run, so a group cannot lock itself out; access granted to other groups is left as users set it.
- When an auth group is renamed its collection is renamed; when it is deleted the collection and its passwords are kept, reachable only by the super admin.
- Because members of a sub-group count as members of the parent group, everyone below an umbrella group can manage the umbrella's group collection.
