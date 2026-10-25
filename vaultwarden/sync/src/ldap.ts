import { Client } from 'ldapts'
import type { Config } from './config.ts'
import type { LdapGroup, LdapUser } from './plan.ts'

type Entry = Record<string, unknown> & { dn: string }

function first(entry: Entry, name: string): string | null {
  const value = entry[name]
  const v = Array.isArray(value) ? value[0] : value
  if (v == null) return null
  return Buffer.isBuffer(v) ? v.toString('utf8') : String(v)
}

function all(entry: Entry, name: string): string[] {
  const value = entry[name]
  if (value == null) return []
  return (Array.isArray(value) ? value : [value]).map((v) => (Buffer.isBuffer(v) ? v.toString('utf8') : String(v)))
}

/** Reads all users and groups. entryUUID is operational, so it is requested explicitly. */
export async function readLdap(config: Config): Promise<{ users: LdapUser[]; groups: LdapGroup[] }> {
  const client = new Client({ url: config.ldapUrl, timeout: 30_000, connectTimeout: 10_000 })
  try {
    await client.bind(config.ldapBindDn, config.ldapBindPassword)

    const userResult = await client.search(config.ldapUsersDn, {
      scope: 'one',
      filter: '(objectClass=inetOrgPerson)',
      attributes: ['entryUUID', 'mail'],
      paged: { pageSize: 500 },
    })
    const groupResult = await client.search(config.ldapGroupsDn, {
      scope: 'one',
      filter: '(objectClass=groupOfNames)',
      attributes: ['entryUUID', 'cn', 'o', 'member'],
      paged: { pageSize: 500 },
    })

    const users: LdapUser[] = []
    for (const entry of userResult.searchEntries as Entry[]) {
      const uuid = first(entry, 'entryUUID')
      if (!uuid) throw new Error(`LDAP entry ${entry.dn} has no entryUUID`)
      users.push({ dn: entry.dn, uuid, email: first(entry, 'mail') })
    }
    const groups: LdapGroup[] = []
    for (const entry of groupResult.searchEntries as Entry[]) {
      const uuid = first(entry, 'entryUUID')
      if (!uuid) throw new Error(`LDAP entry ${entry.dn} has no entryUUID`)
      groups.push({
        dn: entry.dn,
        uuid,
        cn: first(entry, 'cn') ?? entry.dn,
        o: first(entry, 'o'),
        memberDns: all(entry, 'member'),
      })
    }
    return { users, groups }
  } finally {
    await client.unbind().catch(() => {})
  }
}
