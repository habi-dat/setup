// The bw CLI refuses every server URL that is not https (InsecureUrlNotAllowedError), but the
// sync talks to Vaultwarden over the internal docker network via plain http. This loopback
// proxy terminates TLS with a self-signed certificate that only the bw subprocess trusts
// (NODE_EXTRA_CA_CERTS) and forwards everything to VW_URL.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import type { AddressInfo } from 'node:net'
import path from 'node:path'

export interface TlsProxy {
  url: string
  caFile: string
  close(): Promise<void>
}

function ensureCertificate(dir: string): { key: string; cert: string } {
  const key = path.join(dir, 'proxy-key.pem')
  const cert = path.join(dir, 'proxy-cert.pem')
  if (!existsSync(key) || !existsSync(cert)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    execFileSync(
      'openssl',
      [
        'req', '-x509', '-nodes', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
        '-days', '36500', '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
        '-keyout', key, '-out', cert,
      ],
      { stdio: ['ignore', 'ignore', 'pipe'] },
    )
  }
  return { key, cert }
}

export async function startTlsProxy(target: string, certDir: string, port = 0): Promise<TlsProxy> {
  const files = ensureCertificate(certDir)
  const upstream = new URL(target)

  const server = https.createServer({ key: readFileSync(files.key), cert: readFileSync(files.cert) }, (req, res) => {
    const forward = http.request(
      {
        protocol: upstream.protocol,
        hostname: upstream.hostname,
        port: upstream.port || 80,
        method: req.method,
        path: req.url,
        headers: { ...req.headers, host: upstream.host, 'x-forwarded-proto': 'https' },
      },
      (upRes) => {
        res.writeHead(upRes.statusCode ?? 502, upRes.headers)
        upRes.pipe(res)
      },
    )
    forward.on('error', (err) => {
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' })
      res.end(`upstream error: ${err.message}`)
    })
    req.pipe(forward)
  })

  try {
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(port, '127.0.0.1', () => resolve())
    })
  } catch (err) {
    // `--once` executed inside the running container: the daemon's proxy (same target, same
    // certificate from the shared state dir) already listens on the fixed port.
    if (port !== 0 && (err as NodeJS.ErrnoException).code === 'EADDRINUSE')
      return { url: `https://127.0.0.1:${port}`, caFile: files.cert, close: async () => {} }
    throw err
  }
  const { port: bound } = server.address() as AddressInfo
  return {
    url: `https://127.0.0.1:${bound}`,
    caFile: files.cert,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  }
}
