#!/usr/bin/env node
// Claude Code SessionStart hook: inject a short Cortex digest for this repo's
// service, so the agent starts out knowing which services it touches and what
// changed in them. Shipped by cortex-config (standards/claude-hooks), installed
// per repo under .claude/hooks/ (CORTEX-23).
//
// Reads the service name from .cortex/manifest.yaml and fetches
// GET /context/services/:id/digest?format=text from cortex-relay (≤ 2 KB).
//
// Env:
//   CORTEX_MCP_KEY (or CORTEX_API_KEY)  your Cortex API key (mint one on the
//                                       docs app's /api-keys page)
//   CORTEX_RELAY_URL                    default https://cortex-relay-dev-api.trinary.exchange
//
// Silent (no output, exit 0) without a key or manifest, or when the relay is
// slow or failing: a missing digest must never get in the way of a session.

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const DEFAULT_RELAY_URL = 'https://cortex-relay-dev-api.trinary.exchange'
const TIMEOUT_MS = 4000
const MAX_CHARS = 4000

/** The nearest .cortex/manifest.yaml at or above `dir`, or null. */
export function findManifest(dir) {
  let current = dir
  for (;;) {
    const candidate = join(current, '.cortex', 'manifest.yaml')
    if (existsSync(candidate)) return candidate
    const parent = dirname(current)
    if (parent === current) return null
    current = parent
  }
}

/** The manifest's top-level `name`, without a YAML parser. */
export function manifestName(text) {
  const m = text.match(/^name:\s*["']?([^"'\s#]+)["']?\s*(#.*)?$/m)
  return m ? m[1] : null
}

/** The SessionStart output Claude Code adds to the session's context. */
export function hookOutput(markdown) {
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext: markdown.slice(0, MAX_CHARS),
    },
  })
}

export async function run(input, env = process.env, fetchImpl = fetch) {
  const key = env.CORTEX_MCP_KEY || env.CORTEX_API_KEY
  if (!key) return null
  const manifest = findManifest(input?.cwd || process.cwd())
  if (!manifest) return null
  const name = manifestName(readFileSync(manifest, 'utf-8'))
  if (!name) return null
  const base = (env.CORTEX_RELAY_URL || DEFAULT_RELAY_URL).replace(/\/+$/, '')
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    const res = await fetchImpl(
      `${base}/context/services/${encodeURIComponent(name)}/digest?format=text`,
      { headers: { Authorization: `Bearer ${key}` }, signal: controller.signal },
    )
    if (!res.ok) return null
    const text = (await res.text()).trim()
    return text ? hookOutput(text) : null
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  let raw = ''
  process.stdin.setEncoding('utf-8')
  process.stdin.on('data', (c) => (raw += c))
  process.stdin.on('end', async () => {
    let input = {}
    try {
      input = JSON.parse(raw || '{}')
    } catch {}
    const out = await run(input).catch(() => null)
    if (out) process.stdout.write(out + '\n')
    process.exit(0)
  })
}
