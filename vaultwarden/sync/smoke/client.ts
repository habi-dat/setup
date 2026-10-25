// Minimal Bitwarden client crypto + API helpers for the smoke test only: registering accounts,
// creating the organization and reading results back. The sync itself never does crypto.
import crypto from 'node:crypto'

export const VW = process.env.VW_URL ?? 'http://vaultwarden'
const KDF_ITERATIONS = 600_000

export interface SymKey {
  enc: Buffer
  mac: Buffer
}

const symKey = (raw: Buffer): SymKey => ({ enc: raw.subarray(0, 32), mac: raw.subarray(32, 64) })
const hkdfExpand = (prk: Buffer, info: string) =>
  crypto.createHmac('sha256', prk).update(Buffer.concat([Buffer.from(info), Buffer.from([1])])).digest()

export function masterKeys(email: string, password: string) {
  const masterKey = crypto.pbkdf2Sync(password, email.trim().toLowerCase(), KDF_ITERATIONS, 32, 'sha256')
  return {
    hash: crypto.pbkdf2Sync(masterKey, password, 1, 32, 'sha256').toString('base64'),
    stretched: { enc: hkdfExpand(masterKey, 'enc'), mac: hkdfExpand(masterKey, 'mac') } as SymKey,
  }
}

export function encrypt(data: Buffer | string, key: SymKey): string {
  const iv = crypto.randomBytes(16)
  const cipher = crypto.createCipheriv('aes-256-cbc', key.enc, iv)
  const ct = Buffer.concat([cipher.update(data), cipher.final()])
  const mac = crypto.createHmac('sha256', key.mac).update(Buffer.concat([iv, ct])).digest()
  return `2.${iv.toString('base64')}|${ct.toString('base64')}|${mac.toString('base64')}`
}

export function decrypt(encString: string, key: SymKey): Buffer {
  const [type, rest] = encString.split('.', 2)
  if (type !== '2') throw new Error(`unsupported EncString type ${type}`)
  const [iv, ct, mac] = rest.split('|').map((p) => Buffer.from(p, 'base64'))
  const expected = crypto.createHmac('sha256', key.mac).update(Buffer.concat([iv, ct])).digest()
  if (!crypto.timingSafeEqual(expected, mac)) throw new Error('MAC mismatch')
  const decipher = crypto.createDecipheriv('aes-256-cbc', key.enc, iv)
  return Buffer.concat([decipher.update(ct), decipher.final()])
}

export function rsaEncrypt(data: Buffer, publicKeyB64: string): string {
  const key = crypto.createPublicKey({ key: Buffer.from(publicKeyB64, 'base64'), format: 'der', type: 'spki' })
  const ct = crypto.publicEncrypt({ key, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha1' }, data)
  return `4.${ct.toString('base64')}`
}

export function keyPair(protectWith: SymKey) {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  return {
    publicKey: publicKey.export({ format: 'der', type: 'spki' }).toString('base64'),
    encryptedPrivateKey: encrypt(privateKey.export({ format: 'der', type: 'pkcs8' }), protectWith),
  }
}

export function newSymKey(): { raw: Buffer; key: SymKey } {
  const raw = crypto.randomBytes(64)
  return { raw, key: symKey(raw) }
}

export { symKey }

// ---------------------------------------------------------------- HTTP

export async function http<T>(method: string, path: string, opts: { token?: string; json?: unknown; form?: Record<string, string>; accept?: string } = {}): Promise<T> {
  const headers: Record<string, string> = { Accept: opts.accept ?? 'application/json' }
  let body: string | undefined
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`
  if (opts.json !== undefined) {
    headers['Content-Type'] = 'application/json'
    body = JSON.stringify(opts.json)
  }
  if (opts.form) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    body = new URLSearchParams(opts.form).toString()
  }
  const res = await fetch(`${VW}${path}`, { method, headers, body })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 400)}`)
  return (text ? JSON.parse(text) : null) as T
}

export async function register(email: string, password: string) {
  const token = await http<string>('POST', '/identity/accounts/register/send-verification-email', {
    json: { email, name: email.split('@')[0], receiveMarketingEmails: false },
  })
  const { hash, stretched } = masterKeys(email, password)
  const user = newSymKey()
  await http('POST', '/identity/accounts/register/finish', {
    json: {
      email,
      emailVerificationToken: token,
      masterPasswordHash: hash,
      masterPasswordHint: null,
      key: encrypt(user.raw, stretched),
      kdf: 0,
      kdfIterations: KDF_ITERATIONS,
      keys: keyPair(user.key),
    },
  })
}

export async function login(email: string, password: string): Promise<{ token: string; hash: string }> {
  const { hash } = masterKeys(email, password)
  const res = await http<{ access_token: string }>('POST', '/identity/connect/token', {
    form: {
      grant_type: 'password',
      username: email,
      password: hash,
      scope: 'api offline_access',
      client_id: 'web',
      device_identifier: crypto.randomUUID(),
      device_name: 'smoke',
      device_type: '9',
    },
  })
  return { token: res.access_token, hash }
}

/** Unwraps the user's symmetric key and RSA private key from the profile, for decrypting the org key. */
export async function userKeys(email: string, password: string, token: string) {
  const profile = await http<{ key: string; privateKey: string; id: string }>('GET', '/api/accounts/profile', { token })
  const { stretched } = masterKeys(email, password)
  const user = symKey(decrypt(profile.key, stretched))
  const privateKey = crypto.createPrivateKey({ key: decrypt(profile.privateKey, user), format: 'der', type: 'pkcs8' })
  return { id: profile.id, user, privateKey }
}

export function rsaDecrypt(encString: string, privateKey: crypto.KeyObject): Buffer {
  const [type, ct] = encString.split('.', 2)
  if (type !== '4') throw new Error(`unsupported EncString type ${type}`)
  return crypto.privateDecrypt({ key: privateKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha1' }, Buffer.from(ct, 'base64'))
}
