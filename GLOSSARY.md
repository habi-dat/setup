# habidat

A modular collaboration platform for small collective projects (housing projects and their umbrella associations). Users and groups live in the auth module; every other module consumes them.

## Installation

**Installation**:
Everything one habidat setup runs on one server: its settings, its modules and all their data.
_Avoid_: Instance, deployment, server

**Module instance**:
One of several independent copies of the same module in an installation, each with its own name, address and data.
_Avoid_: Instance (on its own), project

**Link step**:
The part of a module that writes what other modules need to know about it, such as its login app in auth. Safe to repeat, and never undoes what an admin changed in the other module.
_Avoid_: Registration, re-install

## Backup

**Snapshot**:
The state of an installation at one moment, kept in its backup repository. Any single module or module instance can be restored from it.
_Avoid_: Backup (as a noun), archive

**Backup repository**:
The encrypted store on another server that holds all snapshots of exactly one installation.
_Avoid_: Remote, backup server

**Export**:
One module's or module instance's data written to a local file, outside the backup repository.
_Avoid_: Dump, backup

**Restore**:
Bringing a module, a module instance or a whole installation back to the state of a snapshot or an export.
_Avoid_: Import

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
