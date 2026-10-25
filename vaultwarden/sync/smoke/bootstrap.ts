// Does the manual one-time setup of the real installation against a throwaway Vaultwarden:
// owner + org, bot as confirmed Admin, both API keys. Also registers alice/bob (so they become
// Accepted on import) and an intruder that the owner invites by hand (must never be confirmed).
import { mkdirSync, writeFileSync } from 'node:fs'
import { encrypt, http, keyPair, login, newSymKey, register, rsaEncrypt } from './client.ts'

const OUT = process.argv[2] ?? '/smoke/.out'
const PW = 'smoke-test-master-password'
const OWNER = 'vault-admin@example.org'
const BOT = 'vault-bot@example.org'

for (const email of [OWNER, BOT, 'alice@example.org', 'bob@example.org', 'intruder@example.org']) await register(email, PW)

const owner = await login(OWNER, PW)
const ownerProfile = await http<{ id: string }>('GET', '/api/accounts/profile', { token: owner.token })
const ownerPublic = await http<{ publicKey: string }>('GET', `/api/users/${ownerProfile.id}/public-key`, { token: owner.token })

const org = newSymKey()
const created = await http<{ id: string }>('POST', '/api/organizations', {
  token: owner.token,
  json: {
    name: 'Smoke',
    billingEmail: OWNER,
    collectionName: encrypt('Default collection', org.key),
    key: rsaEncrypt(org.raw, ownerPublic.publicKey),
    keys: keyPair(org.key),
    planType: 0,
  },
})
const orgId = created.id

await http('POST', `/api/organizations/${orgId}/users/invite`, {
  token: owner.token,
  json: { emails: [BOT], groups: [], type: 1, collections: [], permissions: {} },
})
await http('POST', `/api/organizations/${orgId}/users/invite`, {
  token: owner.token,
  json: { emails: ['intruder@example.org'], groups: [], type: 2, collections: [], permissions: {} },
})
const members = await http<{ data: { id: string; userId: string; email: string; status: number }[] }>(
  'GET',
  `/api/organizations/${orgId}/users`,
  { token: owner.token },
)
const botMember = members.data.find((m) => m.email === BOT)
if (!botMember || botMember.status !== 1) throw new Error(`bot is not Accepted: ${JSON.stringify(botMember)}`)
const botPublic = await http<{ publicKey: string }>('GET', `/api/users/${botMember.userId}/public-key`, { token: owner.token })
await http('POST', `/api/organizations/${orgId}/users/${botMember.id}/confirm`, {
  token: owner.token,
  json: { key: rsaEncrypt(org.raw, botPublic.publicKey) },
})

const orgApiKey = await http<{ apiKey: string }>('POST', `/api/organizations/${orgId}/api-key`, {
  token: owner.token,
  json: { masterPasswordHash: owner.hash },
})
const bot = await login(BOT, PW)
const botApiKey = await http<{ apiKey: string }>('POST', '/api/accounts/api-key', {
  token: bot.token,
  json: { masterPasswordHash: bot.hash },
})

mkdirSync(OUT, { recursive: true })
writeFileSync(
  `${OUT}/credentials.env`,
  [
    `VW_ORG_ID=${orgId}`,
    `VW_ORG_CLIENT_ID=organization.${orgId}`,
    `VW_ORG_CLIENT_SECRET=${orgApiKey.apiKey}`,
    `VW_BOT_CLIENT_ID=user.${botMember.userId}`,
    `VW_BOT_CLIENT_SECRET=${botApiKey.apiKey}`,
    `VW_BOT_MASTER_PASSWORD=${PW}`,
    '',
  ].join('\n'),
)
writeFileSync(`${OUT}/state.json`, JSON.stringify({ orgId, owner: OWNER, password: PW }, null, 2))
console.log(`bootstrap done: org ${orgId}`)
