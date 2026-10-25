import assert from 'node:assert/strict'
import { test } from 'node:test'
import { loadConfig } from '../src/config.ts'

const complete = {
  LDAP_URL: 'ldap://habidat-ldap:389',
  LDAP_BIND_DN: 'cn=admin,dc=habidat,dc=local',
  LDAP_BIND_PASSWORD: 'secret',
  LDAP_USERS_DN: 'ou=users,dc=habidat,dc=local',
  LDAP_GROUPS_DN: 'ou=groups,dc=habidat,dc=local',
  VW_URL: 'http://habidat-vaultwarden/',
  VW_ADMIN_TOKEN: 'token',
  VW_OWNER_EMAIL: 'Vault-Admin@Example.com',
  VW_ORG_ID: 'org',
  VW_ORG_CLIENT_ID: 'organization.org',
  VW_ORG_CLIENT_SECRET: 'orgsecret',
  VW_BOT_CLIENT_ID: 'user.bot',
  VW_BOT_CLIENT_SECRET: 'botsecret',
  VW_BOT_MASTER_PASSWORD: 'botpassword',
}

test('defaults and normalization', () => {
  const result = loadConfig(complete)
  assert.ok(result.ok)
  assert.equal(result.config.vwUrl, 'http://habidat-vaultwarden')
  assert.equal(result.config.vwOwnerEmail, 'vault-admin@example.com')
  assert.equal(result.config.intervalSeconds, 300)
  assert.equal(result.config.maxRemovalRatio, 0.3)
  assert.equal(result.config.dryRun, false)
  assert.equal(result.config.stateDir, '/state')
})

test('--dry-run flag and SYNC_DRY_RUN enable dry run', () => {
  const flag = loadConfig(complete, ['--once', '--dry-run'])
  assert.ok(flag.ok && flag.config.dryRun)
  const env = loadConfig({ ...complete, SYNC_DRY_RUN: 'true' })
  assert.ok(env.ok && env.config.dryRun)
})

test('missing credentials are listed instead of throwing', () => {
  const result = loadConfig({ ...complete, VW_ORG_ID: '', VW_BOT_MASTER_PASSWORD: undefined })
  assert.deepEqual(result, { ok: false, missing: ['VW_ORG_ID', 'VW_BOT_MASTER_PASSWORD'], invalid: [] })
})

test('invalid numbers are rejected', () => {
  const result = loadConfig({ ...complete, SYNC_INTERVAL_SECONDS: 'soon', SYNC_MAX_REMOVAL_RATIO: '2' })
  assert.equal(result.ok, false)
  assert.equal(result.ok === false && result.invalid.length, 2)
})
