import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import {
  type Access,
  type Directory,
  type LdapGroup,
  type LdapUser,
  type VwCollection,
  type VwGroup,
  type VwMember,
  type VwUser,
  MemberStatus,
  MemberType,
  buildDirectory,
  checkRemovals,
  groupUpdateBody,
  nextDisabledRecords,
  planAccounts,
  planCollections,
  planConfirm,
  planGroups,
  planImport,
  planPromote,
  removalCounts,
} from '../src/plan.ts'

const USERS = 'ou=users,dc=habidat,dc=local'
const GROUPS = 'ou=groups,dc=habidat,dc=local'

const user = (uid: string, email: string | null = `${uid}@example.org`): LdapUser => ({
  dn: `uid=${uid},${USERS}`,
  uuid: `u-${uid}`,
  email,
})
const group = (cn: string, members: string[], o: string | null = null): LdapGroup => ({
  dn: `cn=${cn},${GROUPS}`,
  uuid: `g-${cn}`,
  cn,
  o,
  memberDns: members.map((m) => (m.startsWith('@') ? `cn=${m.slice(1)},${GROUPS}` : `uid=${m},${USERS}`)),
})
const member = (email: string, over: Partial<VwMember> = {}): VwMember => ({
  id: `m-${email}`,
  userId: `user-${email}`,
  email,
  externalId: `u-${email.split('@')[0]}`,
  status: MemberStatus.Confirmed,
  type: MemberType.User,
  groups: [],
  collections: [],
  ...over,
})
const manage = (id: string): Access => ({ id, readOnly: false, hidePasswords: false, manage: true })

const BOT = 'bot@example.org'
const OWNER = 'owner@example.org'
const excluded = new Set([BOT, OWNER])

function members(dir: Directory, uuid: string): string[] {
  return dir.groups.find((g) => g.uuid === uuid)?.memberUuids ?? []
}

describe('buildDirectory', () => {
  test('nested groups are flattened transitively', () => {
    const dir = buildDirectory(
      [user('alice'), user('bob'), user('carol')],
      [group('umbrella', ['alice', '@housing-x']), group('housing-x', ['bob', '@flat-1']), group('flat-1', ['carol'])],
    )
    assert.deepEqual(members(dir, 'g-umbrella'), ['u-alice', 'u-bob', 'u-carol'])
    assert.deepEqual(members(dir, 'g-housing-x'), ['u-bob', 'u-carol'])
    assert.deepEqual(members(dir, 'g-flat-1'), ['u-carol'])
  })

  test('cyclic groups terminate and share all members', () => {
    const dir = buildDirectory(
      [user('alice'), user('bob')],
      [group('a', ['alice', '@b']), group('b', ['bob', '@a']), group('self', ['@self'])],
    )
    assert.deepEqual(members(dir, 'g-a'), ['u-alice', 'u-bob'])
    assert.deepEqual(members(dir, 'g-b'), ['u-alice', 'u-bob'])
    assert.deepEqual(members(dir, 'g-self'), [])
  })

  test('member DNs match case- and whitespace-insensitively; placeholders are ignored', () => {
    const g = group('x', [])
    g.memberDns = ['UID=Alice, OU=Users,DC=habidat,DC=local', USERS, 'cn=unknown,ou=groups,dc=habidat,dc=local']
    const dir = buildDirectory([user('alice')], [g])
    assert.deepEqual(members(dir, 'g-x'), ['u-alice'])
  })

  test('display name is o, falling back to cn', () => {
    const dir = buildDirectory([], [group('slug', [], 'Nice Name'), group('plain', [])])
    assert.deepEqual(
      dir.groups.map((g) => g.name),
      ['Nice Name', 'plain'],
    )
  })

  test('users without mail are reported and left out of groups', () => {
    const dir = buildDirectory([user('alice'), user('nomail', null)], [group('g', ['alice', 'nomail'])])
    assert.deepEqual(
      dir.users.map((u) => u.email),
      ['alice@example.org'],
    )
    assert.deepEqual(dir.usersWithoutMail, [`uid=nomail,${USERS}`])
    assert.ok(dir.allUserUuids.has('u-nomail'))
    assert.deepEqual(members(dir, 'g-g'), ['u-alice'])
  })

  test('emails are lower-cased', () => {
    const dir = buildDirectory([user('alice', 'Alice@Example.ORG')], [])
    assert.equal(dir.users[0].email, 'alice@example.org')
  })
})

describe('planImport', () => {
  test('imports LDAP users and groups, excludes bot and owner everywhere', () => {
    const dir = buildDirectory(
      [user('alice'), user('bot'), user('owner')],
      [group('g', ['alice', 'bot', 'owner'], 'Group')],
    )
    const plan = planImport(dir, [member(BOT, { type: MemberType.Admin, externalId: null })], excluded)
    assert.deepEqual(plan.payload, {
      members: [{ email: 'alice@example.org', externalId: 'u-alice', deleted: false }],
      groups: [{ name: 'Group', externalId: 'g-g', memberExternalIds: ['u-alice'] }],
      overwriteExisting: false,
    })
    assert.deepEqual(
      plan.add.map((u) => u.email),
      ['alice@example.org'],
    )
  })

  test('revokes members whose externalId vanished, but never owners, bot, unsynced or revoked ones', () => {
    const dir = buildDirectory([user('alice'), user('nomail', null)], [])
    const gone = member('gone@example.org')
    const plan = planImport(
      dir,
      [
        member('alice@example.org'),
        gone,
        member('nomail@example.org', { externalId: 'u-nomail' }),
        member('manual@example.org', { externalId: null }),
        member('old@example.org', { status: MemberStatus.Revoked }),
        member('boss@example.org', { type: MemberType.Owner }),
        member(BOT, { externalId: 'u-bot' }),
      ],
      excluded,
    )
    assert.deepEqual(plan.revoke, [gone])
    assert.deepEqual(plan.restore, [])
    assert.deepEqual(plan.payload.members.at(-1), { email: 'gone@example.org', externalId: 'u-gone', deleted: true })
  })

  test('revoked members that are back in LDAP are reported as restored (not as added)', () => {
    const dir = buildDirectory([user('bob')], [])
    const bob = member('bob@example.org', { externalId: 'u-old-bob', status: MemberStatus.Revoked })
    const plan = planImport(dir, [bob], excluded)
    assert.deepEqual(plan.restore, [bob])
    assert.deepEqual(plan.add, [])
    assert.deepEqual(plan.revoke, [])
    assert.deepEqual(plan.payload.members, [{ email: 'bob@example.org', externalId: 'u-bob', deleted: false }])
  })
})

describe('planGroups', () => {
  const dir = buildDirectory([], [group('keep', [], 'Keep'), group('renamed', [], 'New Name')])
  const vw: VwGroup[] = [
    { id: '1', name: 'Keep', externalId: 'g-keep', collections: [] },
    { id: '2', name: 'Old Name', externalId: 'g-renamed', collections: [manage('c1')] },
    { id: '3', name: 'Deleted', externalId: 'g-deleted', collections: [] },
    { id: '4', name: 'Hand made', externalId: null, collections: [] },
  ]

  test('deletes vanished groups and renames changed ones, ignores groups without externalId', () => {
    const plan = planGroups(dir, vw)
    assert.deepEqual(
      plan.delete.map((g) => g.id),
      ['3'],
    )
    assert.deepEqual(
      plan.rename.map((r) => [r.group.id, r.name]),
      [['2', 'New Name']],
    )
  })

  test('rename keeps current collections and users', () => {
    assert.deepEqual(groupUpdateBody(vw[1], 'New Name', ['m1', 'm2']), {
      name: 'New Name',
      accessAll: false,
      externalId: 'g-renamed',
      collections: [manage('c1')],
      users: ['m1', 'm2'],
    })
  })
})

describe('planCollections', () => {
  const dir = buildDirectory([], [group('a', [], 'A'), group('b', [], 'B'), group('c', [], 'C'), group('new', [], 'New')])
  const groups: VwGroup[] = [
    { id: 'GA', name: 'A', externalId: 'g-a', collections: [] },
    { id: 'GB', name: 'B', externalId: 'g-b', collections: [] },
    { id: 'GC', name: 'C', externalId: 'g-c', collections: [] },
    { id: 'GN', name: 'New', externalId: 'g-new', collections: [] },
  ]
  const other: Access = { id: 'GX', readOnly: true, hidePasswords: false, manage: false }
  const collections: VwCollection[] = [
    { id: 'CA', name: 'A', externalId: 'g-a', groups: [manage('GA'), other], users: [] },
    {
      id: 'CB',
      name: 'B',
      externalId: 'g-b',
      groups: [other, { id: 'GB', readOnly: true, hidePasswords: false, manage: false }],
      users: [manage('owner-member'), manage('user-member')],
    },
    { id: 'CC', name: 'Old C', externalId: 'g-c', groups: [manage('GC')], users: [] },
    { id: 'CZ', name: 'Orphan', externalId: 'g-deleted', groups: [], users: [] },
    { id: 'CM', name: 'Manual', externalId: null, groups: [], users: [] },
  ]

  test('creates missing group collections with own group manage access and both arrays', () => {
    const plan = planCollections(dir, groups, collections, new Set())
    assert.deepEqual(plan.create, [
      {
        groupUuid: 'g-new',
        groupId: 'GN',
        body: { name: 'New', externalId: 'g-new', groups: [manage('GN')], users: [] },
      },
    ])
  })

  test('re-asserts own group access, keeping other groups and direct users (minus full-access members)', () => {
    const plan = planCollections(dir, groups, collections, new Set(['owner-member']))
    const b = plan.update.find((u) => u.collection.id === 'CB')
    assert.ok(b)
    assert.deepEqual(b.reasons, ['restore own group manage access'])
    assert.deepEqual(b.body, {
      name: 'B',
      externalId: 'g-b',
      groups: [other, manage('GB')],
      users: [manage('user-member')],
    })
  })

  test('renames collections of renamed groups; leaves correct, orphaned and manual ones alone', () => {
    const plan = planCollections(dir, groups, collections, new Set())
    const c = plan.update.find((u) => u.collection.id === 'CC')
    assert.ok(c)
    assert.deepEqual(c.reasons, ['rename "Old C" -> "C"'])
    assert.equal(c.body.name, 'C')
    assert.deepEqual(
      plan.update.map((u) => u.collection.id).sort(),
      ['CB', 'CC'],
    )
  })

  test('collections for groups not yet in Vaultwarden are planned without group (dry run)', () => {
    const plan = planCollections(dir, groups.slice(0, 3), collections, new Set())
    assert.deepEqual(plan.create[0].groupId, null)
    assert.deepEqual(plan.create[0].body.groups, [])
  })
})

describe('planConfirm', () => {
  test('confirms only accepted plain users whose email is in LDAP', () => {
    const dir = buildDirectory([user('alice'), user('bob'), user('bot')], [])
    const alice = member('alice@example.org', { status: MemberStatus.Accepted })
    const intruder = member('intruder@example.org', { status: MemberStatus.Accepted })
    const plan = planConfirm(
      dir,
      [
        alice,
        intruder,
        member('bob@example.org', { status: MemberStatus.Invited }),
        member('bob2@example.org', { status: MemberStatus.Confirmed }),
        member('alice@example.org', { id: 'admin', status: MemberStatus.Accepted, type: MemberType.Admin }),
        member(BOT, { status: MemberStatus.Accepted }),
      ],
      excluded,
    )
    assert.deepEqual(plan.confirm, [alice])
    assert.deepEqual(plan.unknown, [intruder])
  })
})

describe('planPromote', () => {
  test('promotes confirmed users in LDAP to Manager and sends their full state', () => {
    const dir = buildDirectory([user('alice'), user('bob'), user('carol'), user('bot')], [])
    const alice = member('alice@example.org', { groups: ['G1', 'G2'], collections: [manage('C1')] })
    const plan = planPromote(
      dir,
      [
        alice,
        member('bob@example.org', { status: MemberStatus.Accepted }),
        member('carol@example.org', { type: MemberType.Custom }),
        member('gone@example.org'),
        member(BOT),
      ],
      excluded,
    )
    assert.equal(plan.length, 1)
    assert.equal(plan[0].member, alice)
    assert.deepEqual(plan[0].body, {
      type: MemberType.Manager,
      groups: ['G1', 'G2'],
      collections: [manage('C1')],
      permissions: {},
    })
  })
})

describe('planAccounts', () => {
  const dir = buildDirectory([user('alice'), user('back')], [])
  const users: VwUser[] = [
    { id: '1', email: 'alice@example.org', enabled: true },
    { id: '2', email: 'gone@example.org', enabled: true },
    { id: '3', email: 'back@example.org', enabled: false },
    { id: '4', email: 'blocked@example.org', enabled: false },
    { id: '5', email: BOT, enabled: true },
    { id: '6', email: OWNER, enabled: true },
    { id: '7', email: 'manual-off@example.org', enabled: false },
  ]

  test('disables accounts absent from LDAP (not bot/owner), re-enables only those the sync disabled', () => {
    const disabledBySync = [
      { id: '3', email: 'back@example.org', disabledAt: 't0' },
      { id: '4', email: 'blocked@example.org', disabledAt: 't0' },
    ]
    const plan = planAccounts(dir, users, disabledBySync, excluded)
    assert.deepEqual(
      plan.disable.map((u) => u.id),
      ['2'],
    )
    assert.deepEqual(
      plan.enable.map((u) => u.id),
      ['3'],
    )
  })

  test('disabled.json keeps still-disabled entries, adds new ones, drops re-enabled and deleted', () => {
    const next = nextDisabledRecords(
      [
        { id: '3', email: 'back@example.org', disabledAt: 't0' },
        { id: '4', email: 'blocked@example.org', disabledAt: 't0' },
        { id: '99', email: 'deleted@example.org', disabledAt: 't0' },
      ],
      users,
      [users[1]],
      [users[2]],
      't1',
    )
    assert.deepEqual(next, [
      { id: '4', email: 'blocked@example.org', disabledAt: 't0' },
      { id: '2', email: 'gone@example.org', disabledAt: 't1' },
    ])
  })
})

describe('checkRemovals', () => {
  const dir = buildDirectory([user('alice')], [])

  test('aborts when LDAP has no users', () => {
    const check = checkRemovals(buildDirectory([], []), [], 0.3)
    assert.equal(check.ok, false)
  })

  test('aborts when removals exceed the ratio', () => {
    const check = checkRemovals(dir, [{ label: 'synced members', removing: 4, current: 10 }], 0.3)
    assert.equal(check.ok, false)
    assert.match(check.reasons[0], /4 of 10 synced members/)
  })

  test('allows removals up to the ratio and always at least one', () => {
    assert.equal(checkRemovals(dir, [{ label: 'x', removing: 3, current: 10 }], 0.3).ok, true)
    assert.equal(checkRemovals(dir, [{ label: 'x', removing: 1, current: 2 }], 0.3).ok, true)
    assert.equal(checkRemovals(dir, [{ label: 'x', removing: 2, current: 2 }], 0.3).ok, false)
  })

  test('removalCounts covers members, groups and accounts', () => {
    const ms = [member('a@example.org'), member('b@example.org', { externalId: null })]
    const gs: VwGroup[] = [{ id: 'g', name: 'g', externalId: 'x', collections: [] }]
    const us: VwUser[] = [
      { id: '1', email: 'a@example.org', enabled: true },
      { id: '2', email: BOT, enabled: true },
    ]
    const counts = removalCounts(
      ms,
      gs,
      us,
      { payload: { members: [], groups: [], overwriteExisting: false }, revoke: [ms[0]], restore: [], add: [] },
      { delete: gs, rename: [] },
      { disable: [us[0]], enable: [] },
      excluded,
    )
    assert.deepEqual(
      counts.map((c) => [c.removing, c.current]),
      [
        [1, 1],
        [1, 1],
        [1, 1],
      ],
    )
  })
})
