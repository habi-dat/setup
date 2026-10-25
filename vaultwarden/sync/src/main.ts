import { randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { hostname } from 'node:os'
import path from 'node:path'
import { Bw, defaultBwBin } from './bw.ts'
import { type Config, loadConfig } from './config.ts'
import { readLdap } from './ldap.ts'
import {
  type DisabledRecord,
  type VwCollection,
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
} from './plan.ts'
import { startTlsProxy } from './tlsproxy.ts'
import { VwClient } from './vw.ts'

// ---------------------------------------------------------------- logging

function log(level: 'info' | 'warn' | 'error', message: string): void {
  const line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} ${message}`
  if (level === 'error') console.error(line)
  else console.log(line)
}

// ---------------------------------------------------------------- state files

function readJson<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(file, 'utf8')) as T
  } catch {
    return fallback
  }
}

function writeJson(file: string, value: unknown): void {
  const tmp = `${file}.tmp`
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  renameSync(tmp, file)
}

function deviceId(stateDir: string): string {
  const file = path.join(stateDir, 'device-id')
  if (existsSync(file)) return readFileSync(file, 'utf8').trim()
  const id = randomUUID()
  writeFileSync(file, `${id}\n`, { mode: 0o600 })
  return id
}

/** One run at a time per state dir (the daemon and a `--once` run share /state/bw). */
async function acquireLock(stateDir: string, waitMs: number): Promise<(() => void) | null> {
  const file = path.join(stateDir, 'sync.lock')
  const deadline = Date.now() + waitMs
  for (;;) {
    try {
      writeFileSync(file, JSON.stringify({ pid: process.pid, host: hostname() }), { flag: 'wx' })
      return () => rmSync(file, { force: true })
    } catch {
      const holder = readJson<{ pid?: number; host?: string }>(file, {})
      let stale = false
      try {
        stale = Date.now() - statSync(file).mtimeMs > 30 * 60_000
      } catch {
        continue // removed in the meantime
      }
      if (!stale && holder.host === hostname() && holder.pid != null) {
        try {
          process.kill(holder.pid, 0)
        } catch {
          stale = true
        }
      }
      if (stale) {
        rmSync(file, { force: true })
        continue
      }
      if (Date.now() >= deadline) return null
      await new Promise((r) => setTimeout(r, 2000))
    }
  }
}

// ---------------------------------------------------------------- one run

class Aborted extends Error {}

interface Summary {
  imported: number
  revoked: number
  restored: number
  groupsDeleted: number
  groupsRenamed: number
  collectionsCreated: number
  collectionsUpdated: number
  confirmed: number
  unknownSkipped: number
  promoted: number
  disabled: number
  enabled: number
  errors: number
}

async function runOnce(config: Config, vw: VwClient, bw: Bw, dryRun: boolean): Promise<Summary> {
  const s: Summary = {
    imported: 0, revoked: 0, restored: 0, groupsDeleted: 0, groupsRenamed: 0, collectionsCreated: 0, collectionsUpdated: 0,
    confirmed: 0, unknownSkipped: 0, promoted: 0, disabled: 0, enabled: 0, errors: 0,
  }
  const would = dryRun ? '[dry-run] would ' : ''
  const attempt = async (what: string, fn: () => Promise<unknown>): Promise<boolean> => {
    log('info', `${would}${what}`)
    if (dryRun) return true
    try {
      await fn()
      return true
    } catch (err) {
      s.errors++
      log('error', `${what} failed: ${(err as Error).message}`)
      return false
    }
  }

  // 1. LDAP
  const ldap = await readLdap(config)
  const dir = buildDirectory(ldap.users, ldap.groups)
  log('info', `LDAP: ${dir.users.length} users with mail, ${dir.groups.length} groups`)
  for (const dn of dir.usersWithoutMail) log('warn', `LDAP user without mail is not synced: ${dn}`)

  const botEmail = await vw.botEmail()
  const excluded = new Set([botEmail, config.vwOwnerEmail])
  const [members, groups, users] = await Promise.all([vw.members(), vw.groups(), vw.users()])
  const disabledFile = path.join(config.stateDir, 'disabled.json')
  const disabledRecords = readJson<DisabledRecord[]>(disabledFile, [])

  const importPlan = planImport(dir, members, excluded)
  const groupPlan = planGroups(dir, groups)
  const accountPlan = planAccounts(dir, users, disabledRecords, excluded)
  const check = checkRemovals(
    dir,
    removalCounts(members, groups, users, importPlan, groupPlan, accountPlan, excluded),
    config.maxRemovalRatio,
  )
  if (!check.ok) throw new Aborted(`aborted without changes: ${check.reasons.join('; ')}`)

  // 2. import members and groups
  for (const u of importPlan.add) log('info', `${would}add member ${u.email}`)
  for (const m of importPlan.revoke) log('info', `${would}revoke member ${m.email} (no longer in LDAP)`)
  for (const m of importPlan.restore) log('info', `${would}restore member ${m.email} (back in LDAP)`)
  const imported = await attempt(
    `import ${importPlan.payload.members.length} members and ${importPlan.payload.groups.length} groups`,
    () => vw.importOrganization(importPlan.payload),
  )
  if (!imported) throw new Error('organization import failed, skipping the remaining steps')
  s.imported = importPlan.add.length
  s.revoked = importPlan.revoke.length
  s.restored = importPlan.restore.length

  // 3. delete / rename groups
  for (const g of groupPlan.delete) {
    if (await attempt(`delete group "${g.name}" (no longer in LDAP)`, () => vw.deleteGroup(g.id))) s.groupsDeleted++
  }
  for (const { group, name } of groupPlan.rename) {
    const ok = await attempt(`rename group "${group.name}" -> "${name}"`, async () => {
      const memberIds = await vw.groupMemberIds(group.id)
      await vw.updateGroup(group.id, groupUpdateBody(group, name, memberIds))
    })
    if (ok) s.groupsRenamed++
  }

  // 4. group collections
  await bw.ready()
  const groupsNow = dryRun ? groups : await vw.groups()
  const names = await bw.collectionNames()
  const collections: VwCollection[] = (await vw.collectionAccess()).map((c) => ({ ...c, name: names.get(c.id) ?? '' }))
  let membersNow = dryRun ? members : await vw.members()
  const fullAccess = new Set(
    membersNow.filter((m) => m.type === MemberType.Owner || m.type === MemberType.Admin).map((m) => m.id),
  )
  const collectionPlan = planCollections(dir, groupsNow, collections, fullAccess)
  for (const c of collectionPlan.create) {
    if (!c.groupId) {
      log('info', `${would}create group collection "${c.body.name}" once its group exists`)
      continue
    }
    if (await attempt(`create group collection "${c.body.name}"`, () => bw.createCollection(c.body))) s.collectionsCreated++
  }
  for (const u of collectionPlan.update) {
    const what = `update group collection "${u.body.name}": ${u.reasons.join(', ')}`
    if (await attempt(what, () => bw.editCollection(u.collection.id, u.body))) s.collectionsUpdated++
  }

  // 5. confirm accepted members known to LDAP
  const confirmPlan = planConfirm(dir, membersNow, excluded)
  for (const m of confirmPlan.unknown) log('warn', `not confirming ${m.email}: email is not known in LDAP`)
  s.unknownSkipped = confirmPlan.unknown.length
  for (const m of confirmPlan.confirm) {
    if (await attempt(`confirm member ${m.email}`, () => bw.confirmMember(m.id))) s.confirmed++
  }

  // 6. promote confirmed users to Manager
  if (!dryRun && confirmPlan.confirm.length > 0) membersNow = await vw.members()
  for (const { member, body } of planPromote(dir, membersNow, excluded)) {
    if (await attempt(`promote ${member.email} to Manager`, () => vw.updateMember(member.id, body))) s.promoted++
  }

  // 7. disable accounts gone from LDAP, re-enable returning ones
  const disabledNow = []
  const enabledNow = []
  for (const u of accountPlan.disable) {
    if (await attempt(`disable account ${u.email} (not in LDAP)`, () => vw.disableUser(u.id))) disabledNow.push(u)
  }
  for (const u of accountPlan.enable) {
    if (await attempt(`re-enable account ${u.email} (back in LDAP)`, () => vw.enableUser(u.id))) enabledNow.push(u)
  }
  if (!dryRun) {
    writeJson(disabledFile, nextDisabledRecords(disabledRecords, users, disabledNow, enabledNow, new Date().toISOString()))
  }
  s.disabled = disabledNow.length
  s.enabled = enabledNow.length

  return s
}

// ---------------------------------------------------------------- health check (docker HEALTHCHECK)

function health(stateDir: string, intervalSeconds: number): number {
  const last = readJson<{ ok?: boolean; finishedAt?: string } | null>(path.join(stateDir, 'last-run.json'), null)
  if (!last?.finishedAt) return 1
  const age = Date.now() - Date.parse(last.finishedAt)
  return last.ok && age < (intervalSeconds * 3 + 300) * 1000 ? 0 : 1
}

// ---------------------------------------------------------------- main

async function main(): Promise<number> {
  const argv = process.argv.slice(2)
  const stateDir = process.env.STATE_DIR?.trim() || '/state'
  if (argv.includes('--health')) return health(stateDir, Number(process.env.SYNC_INTERVAL_SECONDS) || 300)

  const once = argv.includes('--once')
  mkdirSync(stateDir, { recursive: true })

  // As PID 1, node ignores SIGTERM unless a handler is installed.
  let stopping = false
  let running = false
  let wake: (() => void) | null = null
  for (const signal of ['SIGTERM', 'SIGINT'] as const) {
    process.on(signal, () => {
      stopping = true
      wake?.()
      if (!running) process.exit(0)
    })
  }
  const lastRunFile = path.join(stateDir, 'last-run.json')

  const loaded = loadConfig(process.env, argv)
  if (!loaded.ok) {
    const problems = [
      ...(loaded.missing.length ? [`missing: ${loaded.missing.join(', ')}`] : []),
      ...(loaded.invalid.length ? [`invalid: ${loaded.invalid.join(', ')}`] : []),
    ].join('; ')
    log('error', `not configured yet, run ./habidat.sh configure vaultwarden (${problems})${once ? '' : '; idling until then'}`)
    if (!once) writeJson(lastRunFile, { ok: false, finishedAt: new Date().toISOString(), error: `not configured: ${problems}` })
    if (once) return 1
    // Idle instead of crash-looping; `configure` restarts the container. The timer keeps node alive.
    setInterval(() => {}, 1 << 30)
    return new Promise(() => {})
  }
  const config = loaded.config

  const proxy = await startTlsProxy(config.vwUrl, path.join(stateDir, 'tls'), Number(process.env.BW_PROXY_PORT) || 8087)
  const vw = new VwClient(config, deviceId(stateDir), {
    load: () => readJson<{ cookie?: string }>(path.join(stateDir, 'admin-session.json'), {}).cookie ?? null,
    save: (cookie) => writeJson(path.join(stateDir, 'admin-session.json'), { cookie }),
  })
  const bwDir = path.join(stateDir, 'bw')
  mkdirSync(bwDir, { recursive: true, mode: 0o700 })
  chmodSync(bwDir, 0o700)
  const bw = new Bw({
    bin: process.env.BW_BIN?.trim() || defaultBwBin,
    appDataDir: bwDir,
    serverUrl: proxy.url,
    caFile: proxy.caFile,
    clientId: config.vwBotClientId,
    clientSecret: config.vwBotClientSecret,
    masterPassword: config.vwBotMasterPassword,
    orgId: config.vwOrgId,
  })

  log('info', `starting${once ? ' single run' : `, interval ${config.intervalSeconds}s`}${config.dryRun ? ' (dry run)' : ''}`)
  let exitCode = 0
  while (!stopping) {
    const release = await acquireLock(stateDir, once ? 10 * 60_000 : 0)
    if (!release) {
      log('warn', 'another sync run holds the lock, skipping this run')
    } else {
      running = true
      const startedAt = new Date().toISOString()
      let result: Record<string, unknown>
      try {
        const summary = await runOnce(config, vw, bw, config.dryRun)
        result = { ok: summary.errors === 0, summary }
        log(summary.errors ? 'warn' : 'info', `run finished: ${JSON.stringify(summary)}`)
        exitCode = summary.errors ? 1 : 0
      } catch (err) {
        const aborted = err instanceof Aborted
        result = { ok: false, aborted, error: (err as Error).message }
        log('error', aborted ? (err as Error).message : `run failed: ${(err as Error).stack ?? err}`)
        exitCode = aborted ? 3 : 1
      } finally {
        release()
        running = false
      }
      // A dry run (e.g. from `habidat.sh configure`) must not hide the state of the real runs.
      if (!config.dryRun) writeJson(lastRunFile, { ...result, dryRun: false, startedAt, finishedAt: new Date().toISOString() })
    }
    if (once || stopping) break
    await new Promise<void>((resolve) => {
      wake = resolve
      setTimeout(resolve, config.intervalSeconds * 1000)
    })
    wake = null
  }
  await proxy.close()
  return once ? exitCode : 0
}

main().then(
  (code) => process.exit(code),
  (err) => {
    log('error', `fatal: ${(err as Error).stack ?? err}`)
    process.exit(1)
  },
)
