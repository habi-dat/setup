# One Vaultwarden organization for the whole platform

All shared passwords live in a single Vaultwarden organization; every auth user is a member, every auth group is mirrored as a Vaultwarden group, and collections are shared with any mix of groups. In Vaultwarden an item belongs to exactly one organization and can never be shared across organizations, so one organization is the only layout in which any group can share with any other group without guests being invited and confirmed per organization.

## Consequences

- The super admin (organization Owner) and the confirmation bot (Admin) can read every shared password; Vaultwarden has no setting to prevent Owners/Admins from seeing all collections. Accepted: the platform operator is already trusted by all groups.
- Isolation between groups relies on collection assignments only.

## Considered Options

- **One organization per group, other groups invited as guests**: real isolation from the platform operator, but needs a registry (owning group, API key, guest groups) per organization, per-organization confirmation by that group's owners, and much more clicking.
