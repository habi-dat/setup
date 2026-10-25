// Pure diff logic: LDAP state + Vaultwarden state -> actions. No I/O in this file.

// ---------------------------------------------------------------- LDAP side

export interface LdapUser {
  dn: string
  uuid: string // entryUUID
  email: string | null
}

export interface LdapGroup {
  dn: string
  uuid: string // entryUUID
  cn: string
  o: string | null
  memberDns: string[]
}

export interface DirUser {
  uuid: string
  email: string // lower-cased
}

export interface DirGroup {
  uuid: string
  name: string
  memberUuids: string[] // users only, direct + via sub-groups, sorted
}

export interface Directory {
  users: DirUser[] // users with a mail address
  allUserUuids: Set<string> // every LDAP user, with or without mail
  usersWithoutMail: string[] // DNs, for logging
  groups: DirGroup[]
}

export function normalizeDn(dn: string): string {
  return dn
    .split(',')
    .map((part) => part.trim())
    .join(',')
    .toLowerCase()
}

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase()
}

/** Resolves nested groups: a group's members are its direct user members plus the users of
 *  every group reachable through `member` DNs. Cycles are cut by a visited set. `owner` is not
 *  read at all. Member DNs that are neither a user nor a group (e.g. the placeholder habidat-auth
 *  writes into empty groups) are ignored. */
export function buildDirectory(users: LdapUser[], groups: LdapGroup[]): Directory {
  const userByDn = new Map(users.map((u) => [normalizeDn(u.dn), u]))
  const groupByDn = new Map(groups.map((g) => [normalizeDn(g.dn), g]))

  const resolved = new Map<string, Set<string>>()
  const collect = (groupDn: string): Set<string> => {
    const cached = resolved.get(groupDn)
    if (cached) return cached
    const result = new Set<string>()
    const visited = new Set<string>([groupDn])
    const stack = [groupDn]
    while (stack.length > 0) {
      const group = groupByDn.get(stack.pop() as string)
      if (!group) continue
      for (const raw of group.memberDns) {
        const dn = normalizeDn(raw)
        const user = userByDn.get(dn)
        if (user) {
          result.add(user.uuid)
        } else if (groupByDn.has(dn) && !visited.has(dn)) {
          visited.add(dn)
          stack.push(dn)
        }
      }
    }
    resolved.set(groupDn, result)
    return result
  }

  const withMail = users.filter((u) => u.email != null && u.email.trim() !== '')
  const mailUuids = new Set(withMail.map((u) => u.uuid))
  return {
    users: withMail.map((u) => ({ uuid: u.uuid, email: normalizeEmail(u.email as string) })),
    allUserUuids: new Set(users.map((u) => u.uuid)),
    usersWithoutMail: users.filter((u) => !mailUuids.has(u.uuid)).map((u) => u.dn),
    groups: groups.map((g) => ({
      uuid: g.uuid,
      name: groupName(g),
      memberUuids: [...collect(normalizeDn(g.dn))].filter((uuid) => mailUuids.has(uuid)).sort(),
    })),
  }
}

export function groupName(group: Pick<LdapGroup, 'cn' | 'o'>): string {
  return group.o?.trim() || group.cn
}

// ---------------------------------------------------------------- Vaultwarden side

export const MemberStatus = { Revoked: -1, Invited: 0, Accepted: 1, Confirmed: 2 } as const
// Vaultwarden reports Manager (3) as Custom (4) in member listings.
export const MemberType = { Owner: 0, Admin: 1, User: 2, Manager: 3, Custom: 4 } as const

export interface Access {
  id: string
  readOnly: boolean
  hidePasswords: boolean
  manage: boolean
}

export interface VwMember {
  id: string
  userId: string
  email: string // lower-cased
  externalId: string | null
  status: number
  type: number
  groups: string[]
  collections: Access[] // direct collection assignments
}

export interface VwGroup {
  id: string
  name: string
  externalId: string | null
  collections: Access[]
}

export interface VwCollection {
  id: string
  name: string // decrypted
  externalId: string | null
  groups: Access[]
  users: Access[]
}

export interface VwUser {
  id: string
  email: string // lower-cased
  enabled: boolean
}

export interface DisabledRecord {
  id: string
  email: string
  disabledAt: string
}

/** Emails the sync never touches: the confirmation bot and the organization owner. */
export type Excluded = Set<string>

// ---------------------------------------------------------------- step 2: import

export interface ImportPayload {
  groups: { name: string; externalId: string; memberExternalIds: string[] }[]
  members: { email: string; externalId: string; deleted: boolean }[]
  overwriteExisting: false
}

export interface ImportPlan {
  payload: ImportPayload
  revoke: VwMember[]
  restore: VwMember[] // revoked members that are back in LDAP; the import restores them
  add: DirUser[] // LDAP users that are not yet in the organization
}

export function planImport(dir: Directory, members: VwMember[], excluded: Excluded): ImportPlan {
  const users = dir.users.filter((u) => !excluded.has(u.email))
  const syncedUuids = new Set(users.map((u) => u.uuid))
  const syncedEmails = new Set(users.map((u) => u.email))
  const memberEmails = new Set(members.map((m) => m.email))

  const revoke = members.filter(
    (m) =>
      m.externalId != null &&
      !dir.allUserUuids.has(m.externalId) &&
      m.status !== MemberStatus.Revoked &&
      m.type !== MemberType.Owner &&
      !excluded.has(m.email),
  )

  return {
    payload: {
      members: [
        ...users.map((u) => ({ email: u.email, externalId: u.uuid, deleted: false })),
        ...revoke.map((m) => ({ email: m.email, externalId: m.externalId as string, deleted: true })),
      ],
      groups: dir.groups.map((g) => ({
        name: g.name,
        externalId: g.uuid,
        memberExternalIds: g.memberUuids.filter((uuid) => syncedUuids.has(uuid)),
      })),
      overwriteExisting: false,
    },
    revoke,
    restore: members.filter(
      (m) => m.status === MemberStatus.Revoked && m.type !== MemberType.Owner && syncedEmails.has(m.email),
    ),
    add: users.filter((u) => !memberEmails.has(u.email)),
  }
}

// ---------------------------------------------------------------- step 3: groups

export interface GroupPlan {
  delete: VwGroup[]
  rename: { group: VwGroup; name: string }[]
}

/** Groups without externalId were created by hand and are never touched. */
export function planGroups(dir: Directory, groups: VwGroup[]): GroupPlan {
  const ldapByUuid = new Map(dir.groups.map((g) => [g.uuid, g]))
  const plan: GroupPlan = { delete: [], rename: [] }
  for (const group of groups) {
    if (group.externalId == null) continue
    const ldap = ldapByUuid.get(group.externalId)
    if (!ldap) plan.delete.push(group)
    else if (ldap.name !== group.name) plan.rename.push({ group, name: ldap.name })
  }
  return plan
}

/** PUT /organizations/<org>/groups/<id> replaces collections and users, so the current ones
 *  are sent back unchanged. */
export function groupUpdateBody(group: VwGroup, name: string, memberIds: string[]) {
  return {
    name,
    accessAll: false,
    externalId: group.externalId,
    collections: group.collections.map(accessBody),
    users: memberIds,
  }
}

function accessBody(a: Access): Access {
  return { id: a.id, readOnly: a.readOnly, hidePasswords: a.hidePasswords, manage: a.manage }
}

// ---------------------------------------------------------------- step 4: group collections

export interface CollectionBody {
  name: string
  externalId: string
  groups: Access[]
  users: Access[]
}

export interface CollectionPlan {
  create: { groupUuid: string; groupId: string | null; body: CollectionBody }[]
  update: { collection: VwCollection; reasons: string[]; body: CollectionBody }[]
}

export function ownGroupAccess(groupId: string): Access {
  return { id: groupId, readOnly: false, hidePasswords: false, manage: true }
}

function hasOwnAccess(collection: VwCollection, groupId: string): boolean {
  const entry = collection.groups.find((g) => g.id === groupId)
  return entry != null && !entry.readOnly && !entry.hidePasswords && entry.manage
}

/** Every LDAP group has a group collection (externalId = group entryUUID) which its own group
 *  can manage. Other group/user assignments made by people are kept. Collections of groups that
 *  vanished from LDAP are left alone. `fullAccessMemberIds` are Owners/Admins: the details
 *  endpoint lists them on every collection although they have no stored assignment, so they
 *  are not written back. */
export function planCollections(
  dir: Directory,
  groups: VwGroup[],
  collections: VwCollection[],
  fullAccessMemberIds: Set<string>,
): CollectionPlan {
  const groupIdByExt = new Map(groups.filter((g) => g.externalId != null).map((g) => [g.externalId as string, g.id]))
  const collectionByExt = new Map<string, VwCollection>()
  for (const c of collections) if (c.externalId != null && !collectionByExt.has(c.externalId)) collectionByExt.set(c.externalId, c)

  const plan: CollectionPlan = { create: [], update: [] }
  for (const group of dir.groups) {
    const groupId = groupIdByExt.get(group.uuid) ?? null
    const existing = collectionByExt.get(group.uuid)
    if (!existing) {
      plan.create.push({
        groupUuid: group.uuid,
        groupId,
        body: {
          name: group.name,
          externalId: group.uuid,
          groups: groupId ? [ownGroupAccess(groupId)] : [],
          users: [],
        },
      })
      continue
    }
    if (!groupId) continue // group not created in Vaultwarden yet (dry run)

    const reasons: string[] = []
    if (existing.name !== group.name) reasons.push(`rename "${existing.name}" -> "${group.name}"`)
    if (!hasOwnAccess(existing, groupId)) reasons.push('restore own group manage access')
    if (reasons.length === 0) continue

    plan.update.push({
      collection: existing,
      reasons,
      body: {
        name: group.name,
        externalId: group.uuid,
        groups: [...existing.groups.filter((g) => g.id !== groupId).map(accessBody), ownGroupAccess(groupId)],
        users: dedupe(existing.users.filter((u) => !fullAccessMemberIds.has(u.id))).map(accessBody),
      },
    })
  }
  return plan
}

function dedupe(entries: Access[]): Access[] {
  const seen = new Set<string>()
  return entries.filter((e) => (seen.has(e.id) ? false : (seen.add(e.id), true)))
}

// ---------------------------------------------------------------- step 5: confirm

export interface ConfirmPlan {
  confirm: VwMember[]
  unknown: VwMember[] // accepted, but the email is not in LDAP: logged and skipped
}

export function planConfirm(dir: Directory, members: VwMember[], excluded: Excluded): ConfirmPlan {
  const known = new Set(dir.users.map((u) => u.email))
  const plan: ConfirmPlan = { confirm: [], unknown: [] }
  for (const m of members) {
    if (m.status !== MemberStatus.Accepted || m.type !== MemberType.User || excluded.has(m.email)) continue
    if (known.has(m.email)) plan.confirm.push(m)
    else plan.unknown.push(m)
  }
  return plan
}

// ---------------------------------------------------------------- step 6: promote

export interface PromoteBody {
  type: number
  groups: string[]
  collections: Access[]
  permissions: Record<string, never>
}

/** PUT /organizations/<org>/users/<member> replaces the member's groups and direct collections,
 *  so the current state goes along with the new type. */
export function planPromote(
  dir: Directory,
  members: VwMember[],
  excluded: Excluded,
): { member: VwMember; body: PromoteBody }[] {
  const known = new Set(dir.users.map((u) => u.email))
  return members
    .filter(
      (m) =>
        m.status === MemberStatus.Confirmed &&
        m.type === MemberType.User &&
        known.has(m.email) &&
        !excluded.has(m.email),
    )
    .map((member) => ({
      member,
      body: {
        type: MemberType.Manager,
        groups: [...member.groups],
        collections: member.collections.map(accessBody),
        permissions: {},
      },
    }))
}

// ---------------------------------------------------------------- step 7: disable / enable

export interface AccountPlan {
  disable: VwUser[]
  enable: VwUser[]
}

export function planAccounts(
  dir: Directory,
  users: VwUser[],
  disabledBySync: DisabledRecord[],
  excluded: Excluded,
): AccountPlan {
  const known = new Set(dir.users.map((u) => u.email))
  const ours = new Set(disabledBySync.map((d) => d.id))
  return {
    disable: users.filter((u) => u.enabled && !known.has(u.email) && !excluded.has(u.email)),
    enable: users.filter((u) => !u.enabled && ours.has(u.id) && known.has(u.email)),
  }
}

export function nextDisabledRecords(
  previous: DisabledRecord[],
  users: VwUser[],
  disabled: VwUser[],
  enabled: VwUser[],
  now: string,
): DisabledRecord[] {
  const existing = new Set(users.map((u) => u.id))
  const enabledIds = new Set(enabled.map((u) => u.id))
  const kept = previous.filter((r) => existing.has(r.id) && !enabledIds.has(r.id))
  const keptIds = new Set(kept.map((r) => r.id))
  return [
    ...kept,
    ...disabled.filter((u) => !keptIds.has(u.id)).map((u) => ({ id: u.id, email: u.email, disabledAt: now })),
  ]
}

// ---------------------------------------------------------------- safety check

export interface RemovalCheck {
  ok: boolean
  reasons: string[]
}

/** Allowed removals per kind: max(1, floor(ratio * current)). A single removal is always
 *  allowed so small installations are not blocked forever. */
export function checkRemovals(
  dir: Directory,
  counts: { label: string; removing: number; current: number }[],
  maxRatio: number,
): RemovalCheck {
  const reasons: string[] = []
  if (dir.users.length === 0) reasons.push('LDAP returned no users with a mail address')
  for (const { label, removing, current } of counts) {
    const allowed = Math.max(1, Math.floor(maxRatio * current))
    if (removing > allowed)
      reasons.push(`${removing} of ${current} ${label} would be removed (allowed: ${allowed}, SYNC_MAX_REMOVAL_RATIO=${maxRatio})`)
  }
  return { ok: reasons.length === 0, reasons }
}

export function removalCounts(
  members: VwMember[],
  groups: VwGroup[],
  users: VwUser[],
  importPlan: ImportPlan,
  groupPlan: GroupPlan,
  accountPlan: AccountPlan,
  excluded: Excluded,
) {
  return [
    {
      label: 'synced members',
      removing: importPlan.revoke.length,
      current: members.filter((m) => m.externalId != null && m.status !== MemberStatus.Revoked).length,
    },
    { label: 'synced groups', removing: groupPlan.delete.length, current: groups.filter((g) => g.externalId != null).length },
    {
      label: 'enabled accounts',
      removing: accountPlan.disable.length,
      current: users.filter((u) => u.enabled && !excluded.has(u.email)).length,
    },
  ]
}
