// Plain REST client for everything that needs no client-side crypto.
import type { Config } from './config.ts'
import type { Access, ImportPayload, PromoteBody, VwCollection, VwGroup, VwMember, VwUser } from './plan.ts'
import { normalizeEmail } from './plan.ts'

type Fetch = typeof fetch

export class HttpError extends Error {
  status: number
  constructor(method: string, path: string, status: number, body: string) {
    super(`${method} ${path} -> ${status}: ${body.slice(0, 500)}`)
    this.status = status
  }
}

interface Token {
  value: string
  expiresAt: number
}

export interface AdminSessionStore {
  load(): string | null
  save(cookie: string | null): void
}

const DEVICE_TYPE_SDK = '21'

export class VwClient {
  #config: Config
  #fetch: Fetch
  #deviceId: string
  #tokens = new Map<'bot' | 'org', Token>()
  #adminStore: AdminSessionStore
  #adminCookie: string | null

  constructor(config: Config, deviceId: string, adminStore: AdminSessionStore, fetchImpl: Fetch = fetch) {
    this.#config = config
    this.#fetch = fetchImpl
    this.#deviceId = deviceId
    this.#adminStore = adminStore
    this.#adminCookie = adminStore.load()
  }

  // ------------------------------------------------------------ auth

  async #token(kind: 'bot' | 'org'): Promise<string> {
    const cached = this.#tokens.get(kind)
    if (cached && cached.expiresAt > Date.now() + 60_000) return cached.value

    const form = new URLSearchParams({ grant_type: 'client_credentials' })
    if (kind === 'org') {
      form.set('scope', 'api.organization')
      form.set('client_id', this.#config.vwOrgClientId)
      form.set('client_secret', this.#config.vwOrgClientSecret)
    } else {
      form.set('scope', 'api')
      form.set('client_id', this.#config.vwBotClientId)
      form.set('client_secret', this.#config.vwBotClientSecret)
      form.set('device_identifier', this.#deviceId)
      form.set('device_name', 'habidat-vaultwarden-sync')
      form.set('device_type', DEVICE_TYPE_SDK)
    }
    const res = await this.#fetch(`${this.#config.vwUrl}/identity/connect/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: form,
    })
    const text = await res.text()
    if (!res.ok) throw new HttpError('POST', `/identity/connect/token (${kind} API key)`, res.status, text)
    const json = JSON.parse(text) as { access_token: string; expires_in: number }
    const token = { value: json.access_token, expiresAt: Date.now() + json.expires_in * 1000 }
    this.#tokens.set(kind, token)
    return token.value
  }

  async #api<T>(method: string, path: string, body?: unknown, kind: 'bot' | 'org' = 'bot'): Promise<T> {
    const res = await this.#fetch(`${this.#config.vwUrl}/api${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${await this.#token(kind)}`,
        Accept: 'application/json',
        ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    })
    const text = await res.text()
    if (!res.ok) throw new HttpError(method, path, res.status, text)
    return (text ? JSON.parse(text) : null) as T
  }

  get #org(): string {
    return `/organizations/${this.#config.vwOrgId}`
  }

  // ------------------------------------------------------------ organization API (bot = Admin)

  async botEmail(): Promise<string> {
    const profile = await this.#api<{ email: string }>('GET', '/accounts/profile')
    return normalizeEmail(profile.email)
  }

  async members(): Promise<VwMember[]> {
    const res = await this.#api<{ data: RawMember[] }>('GET', `${this.#org}/users?includeGroups=true&includeCollections=true`)
    return res.data.map((m) => ({
      id: m.id,
      userId: m.userId,
      email: normalizeEmail(m.email),
      externalId: m.externalId || null,
      status: m.status,
      type: m.type,
      groups: m.groups ?? [],
      collections: (m.collections ?? []).map(access),
    }))
  }

  async groups(): Promise<VwGroup[]> {
    const res = await this.#api<{ data: RawGroup[] }>('GET', `${this.#org}/groups/details`)
    return res.data.map((g) => ({
      id: g.id,
      name: g.name,
      externalId: g.externalId || null,
      collections: (g.collections ?? []).map(access),
    }))
  }

  groupMemberIds(groupId: string): Promise<string[]> {
    return this.#api<string[]>('GET', `${this.#org}/groups/${groupId}/users`)
  }

  async updateGroup(groupId: string, body: unknown): Promise<void> {
    await this.#api('PUT', `${this.#org}/groups/${groupId}`, body)
  }

  async deleteGroup(groupId: string): Promise<void> {
    await this.#api('DELETE', `${this.#org}/groups/${groupId}`)
  }

  /** Collection assignments; names are encrypted here and come from `bw list` instead. */
  async collectionAccess(): Promise<Omit<VwCollection, 'name'>[]> {
    const res = await this.#api<{ data: RawCollection[] }>('GET', `${this.#org}/collections/details`)
    return res.data.map((c) => ({
      id: c.id,
      externalId: c.externalId || null,
      groups: (c.groups ?? []).map(access),
      users: (c.users ?? []).map(access),
    }))
  }

  async updateMember(memberId: string, body: PromoteBody): Promise<void> {
    await this.#api('PUT', `${this.#org}/users/${memberId}`, body)
  }

  async importOrganization(payload: ImportPayload): Promise<void> {
    await this.#api('POST', '/public/organization/import', payload, 'org')
  }

  // ------------------------------------------------------------ admin API

  async #adminLogin(): Promise<void> {
    const res = await this.#fetch(`${this.#config.vwUrl}/admin`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Forwarded-Proto': 'https' },
      body: new URLSearchParams({ token: this.#config.vwAdminToken }),
      redirect: 'manual',
    })
    await res.text()
    const cookie = res.headers
      .getSetCookie()
      .map((c) => c.split(';')[0])
      .find((c) => c.startsWith('VW_ADMIN='))
    if (!cookie) {
      const hint = res.status === 429 ? ' (rate limited, retry in a few minutes)' : res.status === 401 ? ' (wrong VW_ADMIN_TOKEN?)' : ''
      throw new Error(`admin login failed: HTTP ${res.status}${hint}`)
    }
    this.#adminCookie = cookie
    this.#adminStore.save(cookie)
  }

  async #admin<T>(method: string, path: string): Promise<T> {
    // The login is rate limited (3 per 5 minutes by default), so the cookie is reused until it expires.
    for (let attempt = 0; attempt < 2; attempt++) {
      if (!this.#adminCookie) await this.#adminLogin()
      const res = await this.#fetch(`${this.#config.vwUrl}/admin${path}`, {
        method,
        headers: {
          Cookie: this.#adminCookie as string,
          Accept: 'application/json',
          'X-Forwarded-Proto': 'https',
          ...(method === 'POST' ? { 'Content-Type': 'application/json' } : {}),
        },
        redirect: 'manual',
      })
      const text = await res.text()
      if (res.status === 401 && attempt === 0) {
        this.#adminCookie = null
        this.#adminStore.save(null)
        continue
      }
      if (!res.ok) throw new HttpError(method, `/admin${path}`, res.status, text)
      return (text ? JSON.parse(text) : null) as T
    }
    throw new Error('unreachable')
  }

  async users(): Promise<VwUser[]> {
    const users = await this.#admin<{ id: string; email: string; userEnabled: boolean }[]>('GET', '/users')
    return users.map((u) => ({ id: u.id, email: normalizeEmail(u.email), enabled: u.userEnabled }))
  }

  async disableUser(userId: string): Promise<void> {
    await this.#admin('POST', `/users/${userId}/disable`)
  }

  async enableUser(userId: string): Promise<void> {
    await this.#admin('POST', `/users/${userId}/enable`)
  }
}

interface RawAccess {
  id: string
  readOnly: boolean
  hidePasswords: boolean
  manage: boolean
}
interface RawMember {
  id: string
  userId: string
  email: string
  externalId: string | null
  status: number
  type: number
  groups?: string[]
  collections?: RawAccess[]
}
interface RawGroup {
  id: string
  name: string
  externalId: string | null
  collections?: RawAccess[]
}
interface RawCollection {
  id: string
  externalId: string | null
  groups?: RawAccess[]
  users?: RawAccess[]
}

function access(a: RawAccess): Access {
  return { id: a.id, readOnly: !!a.readOnly, hidePasswords: !!a.hidePasswords, manage: !!a.manage }
}
