// Reads the organization back as its owner and checks the expected state of each phase.
// `tamper` removes the Umbrella group's own access from its collection (as a person could).
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { VW, decrypt, encrypt, http, login, rsaDecrypt, symKey, userKeys } from './client.ts'

const OUT = process.env.SMOKE_OUT ?? '/smoke/.out'
const phase = process.argv[2]
const state = JSON.parse(readFileSync(`${OUT}/state.json`, 'utf8')) as { orgId: string; owner: string; password: string }
const org = `/api/organizations/${state.orgId}`

const { token } = await login(state.owner, state.password)
const keys = await userKeys(state.owner, state.password, token)
const profile = await http<{ organizations: { id: string; key: string }[] }>('GET', '/api/accounts/profile', { token })
const orgKey = symKey(rsaDecrypt(profile.organizations.find((o) => o.id === state.orgId)!.key, keys.privateKey))

interface Access { id: string; readOnly: boolean; hidePasswords: boolean; manage: boolean }

async function snapshot() {
  const members = (await http<{ data: { id: string; email: string; status: number; type: number }[] }>('GET', `${org}/users`, { token })).data
  const memberEmail = new Map(members.map((m) => [m.id, m.email]))
  const groups = (await http<{ data: { id: string; name: string; externalId: string | null }[] }>('GET', `${org}/groups`, { token })).data
  const groupName = new Map(groups.map((g) => [g.id, g.name]))
  const groupMembers: Record<string, string[]> = {}
  for (const g of groups) {
    const ids = await http<string[]>('GET', `${org}/groups/${g.id}/users`, { token })
    groupMembers[g.name] = ids.map((id) => memberEmail.get(id) ?? id).sort()
  }
  const collections = (
    await http<{ data: { id: string; name: string; externalId: string | null; groups: Access[]; users: Access[] }[] }>('GET', `${org}/collections/details`, { token })
  ).data.map((c) => ({
    id: c.id,
    name: decrypt(c.name, orgKey).toString('utf8'),
    externalId: c.externalId,
    groups: c.groups.map((g) => ({ ...g, name: groupName.get(g.id) ?? g.id })),
  }))

  const login = await fetch(`${VW}/admin`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ token: process.env.VW_ADMIN_TOKEN ?? '' }),
    redirect: 'manual',
  })
  const cookie = login.headers.getSetCookie().map((c) => c.split(';')[0]).find((c) => c.startsWith('VW_ADMIN='))
  assert.ok(cookie, `admin login failed: ${login.status}`)
  const users = (await (await fetch(`${VW}/admin/users`, { headers: { Cookie: cookie } })).json()) as { email: string; userEnabled: boolean }[]

  return {
    members: Object.fromEntries(members.map((m) => [m.email, { status: m.status, type: m.type }])),
    groupMembers,
    groups,
    collections,
    enabled: Object.fromEntries(users.map((u) => [u.email, u.userEnabled])),
  }
}

const OWNER = 'vault-admin@example.org'
const BOT = 'vault-bot@example.org'
const st = (status: number, type: number) => ({ status, type })
const Invited = 0, Accepted = 1, Confirmed = 2, Revoked = -1
const Owner = 0, Admin = 1, User = 2, Manager = 4 // listings report Manager as Custom (4)

function ownManage(s: Awaited<ReturnType<typeof snapshot>>, collection: string, group: string) {
  const c = s.collections.find((x) => x.name === collection)
  assert.ok(c, `collection ${collection} missing`)
  const own = c.groups.find((g) => g.name === group)
  assert.ok(own && own.manage && !own.readOnly && !own.hidePasswords, `${collection}: ${group} lacks manage access`)
}

const s = await snapshot()
try {
  switch (phase) {
    case 'dry': {
      assert.deepEqual(s.members, {
        [OWNER]: st(Confirmed, Owner),
        [BOT]: st(Confirmed, Admin),
        'intruder@example.org': st(Accepted, User),
      })
      assert.deepEqual(s.groups, [])
      assert.deepEqual(s.collections.map((c) => c.name), ['Default collection'])
      break
    }
    case 'run1': {
      assert.deepEqual(s.members, {
        [OWNER]: st(Confirmed, Owner),
        [BOT]: st(Confirmed, Admin),
        'intruder@example.org': st(Accepted, User), // unknown to LDAP: never confirmed
        'alice@example.org': st(Confirmed, Manager),
        'bob@example.org': st(Confirmed, Manager),
        'carol@example.org': st(Invited, User), // no Vaultwarden account yet
        'dave@example.org': st(Invited, User),
      })
      assert.deepEqual(s.groupMembers, {
        Umbrella: ['alice@example.org', 'bob@example.org', 'carol@example.org'],
        'Housing X': ['bob@example.org', 'carol@example.org'],
        'flat-1': ['bob@example.org', 'carol@example.org'],
      })
      for (const name of ['Umbrella', 'Housing X', 'flat-1']) ownManage(s, name, name)
      assert.equal(s.enabled['intruder@example.org'], false)
      assert.equal(s.enabled['alice@example.org'], true)
      break
    }
    case 'tamper': {
      const c = s.collections.find((x) => x.name === 'Umbrella')!
      await http('PUT', `${org}/collections/${c.id}`, {
        token,
        json: { name: encrypt('Umbrella', orgKey), externalId: c.externalId, groups: [], users: [] },
      })
      console.log('removed own group access from the Umbrella collection')
      process.exit(0)
    }
    case 'run2': {
      assert.equal(s.members['bob@example.org'].status, Revoked)
      assert.equal(s.enabled['bob@example.org'], false)
      assert.deepEqual(s.groupMembers, { Umbrella: ['alice@example.org'], 'Housing Y': [] })
      ownManage(s, 'Umbrella', 'Umbrella') // restored
      ownManage(s, 'Housing Y', 'Housing Y') // renamed with its group
      const orphan = s.collections.find((c) => c.name === 'flat-1')
      assert.ok(orphan && orphan.groups.length === 0, 'collection of a deleted group is kept, without groups')
      break
    }
    case 'run3': {
      assert.deepEqual(s.members['bob@example.org'], st(Confirmed, Manager))
      assert.equal(s.enabled['bob@example.org'], true)
      assert.deepEqual(s.groupMembers, { Umbrella: ['alice@example.org', 'bob@example.org'], 'Housing Y': ['bob@example.org'] })
      break
    }
    default:
      throw new Error(`unknown phase ${phase}`)
  }
} catch (err) {
  console.error(JSON.stringify(s, null, 2))
  throw err
}
console.log(`verify ${phase}: ok`)
