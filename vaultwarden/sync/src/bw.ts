// Wrapper around the bw CLI for everything that needs client-side crypto: encrypted collection
// names and confirming members (bw encrypts the org key with the member's public key).
import { execFile } from 'node:child_process'
import path from 'node:path'
import type { CollectionBody } from './plan.ts'

export interface BwOptions {
  bin: string
  appDataDir: string // persisted, so bw stays logged in between runs
  serverUrl: string // https URL of the loopback TLS proxy
  caFile: string
  clientId: string
  clientSecret: string
  masterPassword: string
  orgId: string
}

interface BwResponse<T> {
  success: boolean
  message?: string
  data?: T
}

export const defaultBwBin = path.join(import.meta.dirname, '..', 'node_modules', '.bin', 'bw')

export class Bw {
  #opts: BwOptions
  #session: string | null = null

  constructor(opts: BwOptions) {
    this.#opts = opts
  }

  #run<T>(args: string[]): Promise<T> {
    const env: NodeJS.ProcessEnv = {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      BITWARDENCLI_APPDATA_DIR: this.#opts.appDataDir,
      NODE_EXTRA_CA_CERTS: this.#opts.caFile,
      BW_NOINTERACTION: 'true',
      BW_CLIENTID: this.#opts.clientId,
      BW_CLIENTSECRET: this.#opts.clientSecret,
      BW_PASSWORD: this.#opts.masterPassword,
      ...(this.#session ? { BW_SESSION: this.#session } : {}),
    }
    return new Promise((resolve, reject) => {
      execFile(
        this.#opts.bin,
        [...args, '--response', '--nointeraction'],
        { env, maxBuffer: 64 * 1024 * 1024, timeout: 120_000 },
        (error, stdout, stderr) => {
          let parsed: BwResponse<T> | null = null
          try {
            parsed = JSON.parse(stdout) as BwResponse<T>
          } catch {
            // fall through
          }
          if (parsed?.success) return resolve(parsed.data as T)
          const reason = parsed?.message ?? (stderr.trim() || error?.message || 'unknown error')
          reject(new Error(`bw ${args[0]} ${args[1] ?? ''}: ${reason}`.replace(/\s+:/, ':')))
        },
      )
    })
  }

  /** Logs in with the bot's API key (if needed), unlocks with its master password and syncs. */
  async ready(): Promise<void> {
    let status = await this.#status()
    if (status.serverUrl !== this.#opts.serverUrl) {
      if (status.status !== 'unauthenticated') await this.#run(['logout']).catch(() => {})
      await this.#run(['config', 'server', this.#opts.serverUrl])
      status = await this.#status()
    }
    if (status.status === 'unauthenticated') await this.#run(['login', '--apikey'])
    if (!this.#session) {
      const unlocked = await this.#run<{ raw: string }>(['unlock', '--passwordenv', 'BW_PASSWORD'])
      this.#session = unlocked.raw
    }
    await this.#run(['sync'])
  }

  async #status(): Promise<{ serverUrl: string | null; status: string }> {
    const data = await this.#run<{ template: { serverUrl: string | null; status: string } }>(['status'])
    return data.template
  }

  async collectionNames(): Promise<Map<string, string>> {
    const list = await this.#run<{ data: { id: string; name: string }[] }>([
      'list', 'org-collections', '--organizationid', this.#opts.orgId,
    ])
    return new Map(list.data.map((c) => [c.id, c.name]))
  }

  async createCollection(body: CollectionBody): Promise<string> {
    const created = await this.#run<{ id: string }>([
      'create', 'org-collection', encode({ organizationId: this.#opts.orgId, ...body }),
      '--organizationid', this.#opts.orgId,
    ])
    return created.id
  }

  async editCollection(id: string, body: CollectionBody): Promise<void> {
    await this.#run([
      'edit', 'org-collection', id, encode({ organizationId: this.#opts.orgId, ...body }),
      '--organizationid', this.#opts.orgId,
    ])
  }

  async confirmMember(memberId: string): Promise<void> {
    await this.#run(['confirm', 'org-member', memberId, '--organizationid', this.#opts.orgId])
  }
}

function encode(value: unknown): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64')
}
