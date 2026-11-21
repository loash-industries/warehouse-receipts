#!/usr/bin/env node
// Claude Code PreToolUse hook (matcher: Bash): every commit in a repo with a
// Cortex manifest carries a .cortex/changelog.md entry. Shipped by cortex-config
// (standards/claude-hooks), installed per repo under .claude/hooks/ (CORTEX-23).
//
// Replaces the per-user agent hook that called chronicle_changes on `git
// commit`. A plain command hook:
//   - costs nothing on other Bash calls (it exits at once);
//   - judges the repo the commit actually runs in (`git -C dir`, `cd dir &&`),
//     not the session's working directory;
//   - runs git itself, outside Claude's permission system, so don't-ask mode
//     can't deny `git diff --cached` and block the commit.
//
// What it does for a commit in a repo with .cortex/manifest.yaml:
//   1. Drops changelog entries older than 30 days (the window cortex-relay
//      ingests), puts back the blank line a union merge drops between
//      entries, and re-stages the changelog if it changed anything.
//   2. Blocks (exit 2, reason on stderr for Claude) when files outside .cortex/
//      are staged but .cortex/changelog.md isn't. chronicle_changes drafts the
//      entry; the agent writes it.
// Skipped: merges, commits that touch only .cortex/, an empty index, and a
// message containing [skip changelog].

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const WINDOW_DAYS = 30
export const SKIP_TOKEN = '[skip changelog]'

// ── Pure helpers ──────────────────────────────────────────────────────────

/**
 * If `command` runs `git commit`, the directory it runs in (relative to the
 * hook's cwd, or absolute) and the flags that matter; otherwise null.
 */
export function parseCommit(command) {
  if (typeof command !== 'string') return null
  // Split on shell separators; the commit is one segment, an earlier `cd` another.
  const segments = command.split(/&&|\|\||;|\n/).map((s) => s.trim())
  let dir = null
  for (const seg of segments) {
    const cd = seg.match(/^cd\s+("[^"]+"|'[^']+'|\S+)\s*$/)
    if (cd) {
      dir = cd[1].replace(/^["']|["']$/g, '')
      continue
    }
    const git = seg.match(/^(?:\S+=\S+\s+)*git((?:\s+-C\s+(?:"[^"]+"|'[^']+'|\S+)|\s+-c\s+\S+)*)\s+commit\b(.*)$/s)
    if (!git) continue
    const dashC = [...git[1].matchAll(/-C\s+("[^"]+"|'[^']+'|\S+)/g)].map((m) =>
      m[1].replace(/^["']|["']$/g, ''),
    )
    for (const d of dashC) dir = dir && !isAbsolute(d) ? join(dir, d) : d
    const args = git[2]
    return {
      dir,
      all: /(^|\s)(-a|--all|-[a-zA-Z]*a[a-zA-Z]*)(\s|$)/.test(args.replace(/(-m|--message)(\s+|=)("[^"]*"|'[^']*'|\S+)/g, '')),
      amend: /(^|\s)--amend(\s|$)/.test(args),
      skip: args.includes(SKIP_TOKEN),
    }
  }
  return null
}

/**
 * The changelog with entries older than the window removed and a blank line
 * restored before any entry heading that lost it, or null if neither applies.
 * A union merge (`.cortex/changelog.md merge=union` in .gitattributes) keeps
 * both PRs' entries but drops the blank line between them.
 */
export function trimChangelog(text, today = new Date()) {
  const cutoffDate = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()))
  cutoffDate.setUTCDate(cutoffDate.getUTCDate() - WINDOW_DAYS)
  const cutoff = cutoffDate.toISOString().slice(0, 10)
  const preamble = []
  const entries = []
  let inFence = false
  for (const line of text.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence
    if (!inFence && line.startsWith('## ')) entries.push([line])
    else if (entries.length) entries.at(-1).push(line)
    else preamble.push(line)
  }
  const keep = entries.filter((e) => {
    const m = e[0].match(/\d{4}-\d{2}-\d{2}/)
    return !m || m[0] >= cutoff
  })
  const out = [...preamble]
  let respaced = false
  for (const [i, entry] of keep.entries()) {
    if (i > 0 && out.at(-1) !== '') {
      out.push('')
      respaced = true
    }
    out.push(...entry)
  }
  if (keep.length === entries.length && !respaced) return null
  return out.join('\n').replace(/\n+$/, '') + '\n'
}

/**
 * Whether to let the commit through. `staged` is the list of files the
 * commit will include.
 */
export function decide(staged, flags) {
  if (flags.skip) return { block: false, reason: 'skip token' }
  if (staged.length === 0) return { block: false, reason: 'nothing staged' }
  const outside = staged.filter((f) => !f.startsWith('.cortex/'))
  if (outside.length === 0) return { block: false, reason: 'only .cortex' }
  if (staged.includes('.cortex/changelog.md')) return { block: false, reason: 'has entry' }
  return { block: true }
}

export const BLOCK_MESSAGE = [
  'This repo keeps a Cortex changelog, and this commit has no .cortex/changelog.md entry.',
  'Before committing: call the cortex MCP tool chronicle_changes (service_id from .cortex/manifest.yaml, a summary, the changed files) for a draft,',
  'add the entry at the top of .cortex/changelog.md (and update .cortex/overview.md if behaviour changed), stage it, then commit again.',
  `For a commit that needs no entry (a typo, a revert of an unpushed commit), put ${SKIP_TOKEN} in the message.`,
].join(' ')

// ── Hook ──────────────────────────────────────────────────────────────────

function git(cwd, args) {
  return execFileSync('git', args, { cwd, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] })
}

const lines = (out) => out.split('\n').map((l) => l.trim()).filter(Boolean)

export function run(input) {
  const commit = parseCommit(input?.tool_input?.command)
  if (!commit) return { code: 0 }
  const base = input.cwd || process.cwd()
  const dir = commit.dir ? resolve(base, commit.dir) : base
  let root
  try {
    root = git(dir, ['rev-parse', '--show-toplevel']).trim()
  } catch {
    return { code: 0 }
  }
  if (!existsSync(join(root, '.cortex', 'manifest.yaml'))) return { code: 0 }
  // A merge commit records someone else's changes; its changelog entries
  // came with them.
  if (existsSync(resolve(root, git(root, ['rev-parse', '--git-path', 'MERGE_HEAD']).trim()))) {
    return { code: 0 }
  }

  const changelog = join(root, '.cortex', 'changelog.md')
  if (existsSync(changelog)) {
    const trimmed = trimChangelog(readFileSync(changelog, 'utf-8'))
    if (trimmed != null) {
      writeFileSync(changelog, trimmed)
      // Re-stage only if the changelog is part of this commit already, so a
      // trim never sneaks into an unrelated commit on its own.
      const stagedNow = lines(git(root, ['diff', '--cached', '--name-only']))
      if (stagedNow.includes('.cortex/changelog.md')) git(root, ['add', '.cortex/changelog.md'])
    }
  }

  const staged = new Set(lines(git(root, ['diff', '--cached', '--name-only'])))
  if (commit.all) for (const f of lines(git(root, ['diff', '--name-only']))) staged.add(f)
  const verdict = decide([...staged], commit)
  return verdict.block ? { code: 2, stderr: BLOCK_MESSAGE } : { code: 0 }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  let raw = ''
  process.stdin.setEncoding('utf-8')
  process.stdin.on('data', (c) => (raw += c))
  process.stdin.on('end', () => {
    let result = { code: 0 }
    try {
      result = run(JSON.parse(raw || '{}'))
    } catch {
      // A broken hook must never block work; the commit goes ahead.
      result = { code: 0 }
    }
    if (result.stderr) process.stderr.write(result.stderr + '\n')
    process.exit(result.code)
  })
}
