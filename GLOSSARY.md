# habidat

A modular collaboration platform for small collective projects (housing projects and their umbrella associations). Users and groups live in the auth module; every other module consumes them.

## Identity

**Group**:
A set of users defined in the auth module, optionally nested under one or more parent groups. The only notion of "who belongs together" on the platform.
_Avoid_: Tenant, organisation, team

**Group member**:
A user who is directly in a group, or in any of its sub-groups (transitively). Being a group owner alone does not make someone a member.
_Avoid_: Participant

**Group owner**:
A user who administers a group in the auth module. Grants no rights in other modules by itself.

**Auth admin**:
A user in the auth module's `admin` group. Administers users and groups, but has no special rights in the password manager.
_Avoid_: Super admin, platform admin

## Password manager

**Personal vault**:
The passwords a single user keeps for themselves; never visible to anyone else.

**Collection**:
A shared container of passwords that one or more groups can access.
_Avoid_: Shared folder

**Group collection**:
The collection that exists for every group by default, named after it. Its group members can always manage it and share it with other groups.

**Folder**:
A user's personal way of sorting the passwords they can see. Never shared.

**Super admin**:
The single account that owns the password manager's shared space and can see every collection. Not tied to being an auth admin.
_Avoid_: Admin, owner

**Confirmation bot**:
A technical account that automatically grants newly joined users access to the collections of their groups, so that group membership in auth is all it takes.
