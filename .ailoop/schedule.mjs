#!/usr/bin/env node
// ailoop scheduler — the deterministic half of the loop. The coordinator never
// computes readiness, batches, or cap breaches by eye; it runs this and judges
// only what the output MEANS. Dependency-free; Node >= 18.
// Usage: node .ailoop/schedule.mjs [path-to-backlog.json]
import { readFileSync } from 'node:fs'

// Allowlisted for every ticket (dependency adds) and excluded from the
// disjointness key — integration resolves them mechanically (union
// package.json, regenerate lockfile), so they don't serialize batches.
const MANIFESTS = new Set([
  'package.json', 'package-lock.json', 'bun.lock', 'bun.lockb',
  'yarn.lock', 'pnpm-lock.yaml',
])

const path = process.argv[2] ?? '.ailoop/backlog.json'
const { tickets = [], caps = {} } = JSON.parse(readFileSync(path, 'utf8'))
const maxAttempts = caps.maxAttempts ?? 3

const byId = new Map()
const problems = []
for (const t of tickets) {
  if (byId.has(t.id)) problems.push(`duplicate ticket id ${t.id}`)
  byId.set(t.id, t)
}
for (const t of tickets)
  for (const d of t.depends_on ?? [])
    if (!byId.has(d)) problems.push(`${t.id} depends on unknown ticket ${d}`)

const color = new Map() // 1 = on current DFS path, 2 = fully explored
const cycles = []
const visit = (id, stack) => {
  if (color.get(id) === 2) return
  if (color.get(id) === 1) {
    cycles.push([...stack.slice(stack.indexOf(id)), id].join(' -> '))
    return
  }
  color.set(id, 1)
  for (const d of byId.get(id)?.depends_on ?? [])
    if (byId.has(d)) visit(d, [...stack, id])
  color.set(id, 2)
}
for (const t of tickets) visit(t.id, [])

const isDone = id => byId.get(id)?.status === 'done'
const breached = t => (t.attempts?.length ?? 0) >= maxAttempts
// Breached tickets are walls awaiting escalation — never dispatchable, so they
// are excluded from ready/batches (they still surface in capBreaches).
const ready = tickets.filter(t =>
  t.status === 'todo' && !breached(t) && (t.depends_on ?? []).every(isDone))

// Greedy file-disjoint grouping over the ready set, in backlog (dependency)
// order. batches[0] is the next fan-out candidate; later batches wait.
const keyFiles = t => (t.files ?? []).filter(f => !MANIFESTS.has(f.split('/').pop()))
const batches = []
for (const t of ready) {
  const mine = new Set(keyFiles(t))
  const slot = batches.find(b => !b.some(o => keyFiles(o).some(f => mine.has(f))))
  if (slot) slot.push(t)
  else batches.push([t])
}

const count = s => tickets.filter(t => t.status === s).length
console.log(JSON.stringify({
  counts: {
    total: tickets.length,
    done: count('done'),
    todo: count('todo'),
    inProgress: count('in-progress'),
    blocked: count('blocked'),
    decomposed: count('decomposed'),
  },
  problems,
  cycles,
  staleInProgress: tickets.filter(t => t.status === 'in-progress').map(t => t.id),
  capBreaches: tickets
    .filter(t => t.status !== 'done' && breached(t))
    .map(t => t.id),
  ready: ready.map(t => ({ id: t.id, title: t.title, files: t.files ?? [] })),
  batches: batches.map(b => b.map(t => t.id)),
}, null, 2))
