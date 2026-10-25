// Environment contract of the sync container. sync.env carries the non-secret settings,
// credentials.env (written by `habidat.sh configure vaultwarden`) the API keys.

export interface Config {
  ldapUrl: string
  ldapBindDn: string
  ldapBindPassword: string
  ldapUsersDn: string
  ldapGroupsDn: string

  vwUrl: string
  vwAdminToken: string
  vwOwnerEmail: string
  vwOrgId: string
  vwOrgClientId: string
  vwOrgClientSecret: string
  vwBotClientId: string
  vwBotClientSecret: string
  vwBotMasterPassword: string

  intervalSeconds: number
  dryRun: boolean
  maxRemovalRatio: number
  stateDir: string
}

const REQUIRED = {
  ldapUrl: 'LDAP_URL',
  ldapBindDn: 'LDAP_BIND_DN',
  ldapBindPassword: 'LDAP_BIND_PASSWORD',
  ldapUsersDn: 'LDAP_USERS_DN',
  ldapGroupsDn: 'LDAP_GROUPS_DN',
  vwUrl: 'VW_URL',
  vwAdminToken: 'VW_ADMIN_TOKEN',
  vwOwnerEmail: 'VW_OWNER_EMAIL',
  vwOrgId: 'VW_ORG_ID',
  vwOrgClientId: 'VW_ORG_CLIENT_ID',
  vwOrgClientSecret: 'VW_ORG_CLIENT_SECRET',
  vwBotClientId: 'VW_BOT_CLIENT_ID',
  vwBotClientSecret: 'VW_BOT_CLIENT_SECRET',
  vwBotMasterPassword: 'VW_BOT_MASTER_PASSWORD',
} as const

export type LoadResult = { ok: true; config: Config } | { ok: false; missing: string[]; invalid: string[] }

function parseBool(value: string | undefined, fallback: boolean): boolean | null {
  if (value == null || value.trim() === '') return fallback
  const v = value.trim().toLowerCase()
  if (['1', 'true', 'yes', 'on'].includes(v)) return true
  if (['0', 'false', 'no', 'off'].includes(v)) return false
  return null
}

function parseNumber(value: string | undefined, fallback: number): number {
  if (value == null || value.trim() === '') return fallback
  return Number(value.trim())
}

export function loadConfig(env: NodeJS.ProcessEnv, argv: string[] = []): LoadResult {
  const missing: string[] = []
  const invalid: string[] = []
  const values: Record<string, string> = {}
  for (const [key, name] of Object.entries(REQUIRED)) {
    const value = env[name]?.trim()
    if (!value) missing.push(name)
    else values[key] = value
  }

  const intervalSeconds = parseNumber(env.SYNC_INTERVAL_SECONDS, 300)
  if (!Number.isInteger(intervalSeconds) || intervalSeconds < 30) invalid.push('SYNC_INTERVAL_SECONDS (integer >= 30)')
  const maxRemovalRatio = parseNumber(env.SYNC_MAX_REMOVAL_RATIO, 0.3)
  if (!Number.isFinite(maxRemovalRatio) || maxRemovalRatio < 0 || maxRemovalRatio > 1)
    invalid.push('SYNC_MAX_REMOVAL_RATIO (number between 0 and 1)')
  const dryRunEnv = parseBool(env.SYNC_DRY_RUN, false)
  if (dryRunEnv == null) invalid.push('SYNC_DRY_RUN (true/false)')

  if (missing.length > 0 || invalid.length > 0) return { ok: false, missing, invalid }

  return {
    ok: true,
    config: {
      ...(values as Record<keyof typeof REQUIRED, string>),
      vwUrl: values.vwUrl.replace(/\/+$/, ''),
      vwOwnerEmail: values.vwOwnerEmail.toLowerCase(),
      intervalSeconds,
      dryRun: dryRunEnv === true || argv.includes('--dry-run'),
      maxRemovalRatio,
      stateDir: env.STATE_DIR?.trim() || '/state',
    },
  }
}
