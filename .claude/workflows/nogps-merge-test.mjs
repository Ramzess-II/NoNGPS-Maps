// The scheduler of the merge train (nogps-merge.js), run with stubbed agents: the prep of the parallel set has to
// overlap, the merge gate has to stay one PR at a time, a PR whose master moved has to come back for one more round
// but not for ever, and every PR has to end up in the report. No dependencies: node .claude/workflows/nogps-merge-test.mjs
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const SCRIPT = process.argv[2] || join(dirname(fileURLToPath(import.meta.url)), 'nogps-merge.js')
// The workflow runtime gives the script its globals and wraps it, so it ends in a top-level return: wrap it the
// same way here, with stubs in place of the globals.
const SRC = readFileSync(SCRIPT, 'utf8').replace('export const meta', 'const meta')

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function runScript({ args, reply, quiet = true }) {
  const live = new Map() // label prefix -> current count
  const peak = new Map()
  const order = []
  const bump = (k, d) => {
    const n = (live.get(k) || 0) + d
    live.set(k, n)
    if (d > 0) peak.set(k, Math.max(peak.get(k) || 0, n))
  }
  let calls = 0
  const agent = async (prompt, opts = {}) => {
    const label = opts.label || '?'
    const kind = label.split(':')[0]
    calls++
    if (calls > 500) throw new Error('runaway: more than 500 agent calls')
    bump(kind, 1)
    order.push(`+${label}`)
    try {
      await sleep(1 + Math.floor(Math.random() * 4))
      return reply(label, opts, prompt)
    } finally {
      bump(kind, -1)
      order.push(`-${label}`)
    }
  }
  const logs = []
  const ctx = {
    args,
    agent,
    parallel: (fns) => Promise.all(fns.map((f) => f())),
    phase: () => {},
    log: (m) => {
      logs.push(m)
      if (!quiet) console.log('   log:', m)
    },
  }
  const keys = Object.keys(ctx)
  const fn = new Function(...keys, `return (async () => { ${SRC} })()`)
  const out = await fn(...keys.map((k) => ctx[k]))
  return { out, peak: Object.fromEntries(peak), order, logs, calls }
}

// The prep steps of one PR: whichever of them a worker is in, it holds that PR's slot.
const prepPeak = (peak) => Math.max(peak.disk || 0, peak.update || 0, peak.review || 0, peak.fix || 0)

const pr = (n, extra = {}) => ({ number: n, title: `PR ${n}`, branch: `feature/p${n}`, head: `h${n}`, url: `u${n}`, ...extra })

let failures = 0
function check(name, cond, info) {
  if (cond) console.log(`  ok   ${name}`)
  else {
    console.log(`  FAIL ${name}`, info === undefined ? '' : JSON.stringify(info))
    failures++
  }
}

const base = (label) => {
  if (label === 'setup') return { ok: true, freeGb: 100 }
  if (label.startsWith('disk')) return { freeGb: 100 }
  if (label.startsWith('update')) return { status: 'ok', head: 'nh', prepMaster: 'm0' }
  if (label.startsWith('review')) return { findings: [] }
  if (label.startsWith('fix')) return { status: 'pushed', fixed: 1, rejected: 0, head: 'fh' }
  if (label.startsWith('merge')) return { status: 'merged', mergeCommit: 'c' + label.slice(7) }
  if (label === 'clean') return 'cleaned'
  throw new Error('unexpected label ' + label)
}

// --- 1. parallel prep, serial gate ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2), pr(3), pr(4)], slots: 2 },
    reply: base,
  })
  console.log('1. four independent PRs, 2 slots')
  check('all four merged', r.out.merged === 4, r.out.results.map((x) => [x.pr, x.outcome]))
  check('every result is in the parallel set', r.out.results.every((x) => x.set === 'parallel'))
  check('two preps ran at once', prepPeak(r.peak) === 2, r.peak)
  check('the gate never ran twice at once', (r.peak.merge || 0) === 1, r.peak)
  check('one setup and one clean', r.order.filter((o) => o === '+setup').length === 1 && r.order.filter((o) => o === '+clean').length === 1)
}

// --- 2. gate seriality really excludes, measured across awaits ---
{
  let gateLive = 0
  let maxGate = 0
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2), pr(3), pr(4), pr(5)], slots: 4 },
    // The gate's reply has to span an await: counted up and down in one synchronous reply, gateLive is back to 0
    // before any other worker can run, and the count would be 1 even with the gate's lock taken out.
    reply: async (label) => {
      if (label.startsWith('merge')) {
        gateLive++
        await sleep(4)
        maxGate = Math.max(maxGate, gateLive)
        gateLive--
      }
      return base(label)
    },
  })
  console.log('2. five PRs, 4 slots')
  check('all merged', r.out.merged === 5)
  check('gate strictly one at a time', maxGate === 1, { maxGate })
  check('four preps at once', prepPeak(r.peak) === 4, r.peak)
}

// --- 3. stale once, then merged ---
{
  const seen = {}
  const updates = []
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2)], slots: 2, rounds: 3 },
    reply: (label, opts, prompt) => {
      if (label.startsWith('update')) updates.push(prompt)
      if (label.startsWith('merge')) {
        const n = label.slice(7)
        seen[n] = (seen[n] || 0) + 1
        if (n === '1' && seen[n] === 1) return { status: 'stale', staleFiles: ['libs/map/nogps/engine.cpp'] }
      }
      return base(label)
    },
  })
  console.log('3. one PR goes back for a stale master')
  check('both merged in the end', r.out.merged === 2, r.out.results.map((x) => [x.pr, x.outcome]))
  const one = r.out.results.find((x) => x.pr === 1)
  check('the extra round is counted', one.rounds === 2, one)
  check('staleRounds recorded', one.staleRounds === 1, one)
  check('#1 went through the gate twice', seen['1'] === 2, seen)
  check('#1 was updated twice', r.order.filter((o) => o === '+update:#1').length === 2)
  // The second prep of #1 can land in the other slot, whose worktree still has train/1 checked out.
  check(
    'the prep checks out past another worktree holding the branch',
    updates.every((p) => /checkout --force --ignore-other-worktrees -B train\/\d/.test(p)),
    updates.length,
  )
}

// --- 4. stale for ever: bounded by rounds ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1)], slots: 2, rounds: 2 },
    reply: (label) => (label.startsWith('merge') ? { status: 'stale', staleFiles: ['a.cpp'] } : base(label)),
  })
  console.log('4. master keeps moving under the PR')
  check('left open, not looping', r.out.merged === 0 && r.out.results[0].outcome === 'open', r.out.results)
  check('stopped at the round limit', r.out.results[0].rounds === 2, r.out.results[0])
  check('the reason names the rounds', /rounds are used up/.test(r.out.results[0].reason), r.out.results[0].reason)
}

// --- 5. findings that never clear ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1)], slots: 1, rounds: 2 },
    reply: (label) =>
      label.startsWith('review')
        ? { findings: [{ file: 'a.cpp', summary: 's', scenario: 'x' }] }
        : label.startsWith('fix')
          ? { status: 'pushed', fixed: 1, rejected: 1, head: 'h' }
          : base(label),
  })
  console.log('5. findings survive every round')
  check('open after the rounds', r.out.results[0].outcome === 'open' && r.out.results[0].rounds === 2, r.out.results[0])
  check('never reached the gate', !r.order.some((o) => o.startsWith('+merge')), r.order.filter((o) => o[0] === '+'))
}

// --- 6. the serial set runs after the parallel one, one at a time ---
{
  let maxAny = 0
  let live = 0
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2)], serial: [pr(3), pr(4)], slots: 2 },
    reply: (label) => base(label),
  })
  console.log('6. a parallel set and a serial set')
  check('all four merged', r.out.merged === 4, r.out.results.map((x) => [x.pr, x.outcome, x.set]))
  const sets = Object.fromEntries(r.out.results.map((x) => [x.pr, x.set]))
  check('the sets are reported', sets[1] === 'parallel' && sets[3] === 'serial', sets)
  const firstSerial = r.order.indexOf('+update:#3')
  const lastParallelMerge = Math.max(r.order.lastIndexOf('+merge:#1'), r.order.lastIndexOf('+merge:#2'))
  check('the serial set starts after the parallel merges', firstSerial > lastParallelMerge, { firstSerial, lastParallelMerge })
  const s3 = r.order.indexOf('+update:#3')
  const s4 = r.order.indexOf('+update:#4')
  const m3 = r.order.indexOf('+merge:#3')
  check('#4 starts only after #3 is merged', s4 > m3 && m3 > s3, { s3, m3, s4 })
}

// --- 7. args.queue, the old single queue, still works ---
{
  const r = await runScript({ args: { ws: '/ws', queue: [pr(1), pr(2)] }, reply: base })
  console.log('7. the old args.queue')
  check('both merged, one at a time', r.out.merged === 2 && prepPeak(r.peak) === 1, r.peak)
  check('counted as the serial set', r.out.results.every((x) => x.set === 'serial'))
  check('no prep slot was asked for', r.out.slots === 0, r.out.slots)
}

// --- 8. a PR in both sets is taken once ---
{
  const r = await runScript({ args: { ws: '/ws', parallel: [pr(1)], serial: [pr(1), pr(2)], slots: 2 }, reply: base })
  console.log('8. the same PR in both sets')
  check('merged once', r.out.results.filter((x) => x.pr === 1).length === 1, r.out.results)
  check('the other one still runs', r.out.merged === 2)
}

// --- 9. the disk fills up ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2), pr(3)], slots: 2 },
    reply: (label) => (label.startsWith('disk') ? { freeGb: 3 } : label === 'setup' ? { ok: true, freeGb: 3 } : base(label)),
  })
  console.log('9. under MIN_FREE_GB')
  check('nothing prepped', r.out.merged === 0 && !r.order.some((o) => o.startsWith('+update')), r.order.filter((o) => o[0] === '+'))
  check('every PR is in the report', r.out.results.length === 3, r.out.results.map((x) => [x.pr, x.reason]))
  check('the disk is named', r.out.results.every((x) => /GB free|disk filled up/.test(x.reason)), r.out.results.map((x) => x.reason))
  check('it still cleaned up', r.order.includes('+clean'))
}

// --- 10. the update fails / the branch moved ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2)], slots: 2 },
    reply: (label) =>
      label === 'update:#1' ? { status: 'moved', reason: 'somebody pushed to it' } : base(label),
  })
  console.log('10. a branch that moved under the train')
  const one = r.out.results.find((x) => x.pr === 1)
  check('#1 left open with the reason', one.outcome === 'open' && one.reason === 'somebody pushed to it', one)
  check('#1 never reached the gate', !r.order.includes('+merge:#1'))
  check('#2 still merged', r.out.results.find((x) => x.pr === 2).outcome === 'merged')
}

// --- 11. an agent that stops, and a thrown error ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1), pr(2)], slots: 2 },
    reply: (label) => {
      if (label === 'review:#1/1') return null
      if (label === 'merge:#2') throw new Error('boom')
      return base(label)
    },
  })
  console.log('11. an agent stops, another throws')
  check('#1 open: the review agent stopped', r.out.results.find((x) => x.pr === 1).reason === 'the review agent stopped', r.out.results)
  check('#2 open with the error', /boom/.test(r.out.results.find((x) => x.pr === 2).reason), r.out.results)
  check('the run still finished and cleaned', r.order.includes('+clean'))
}

// --- 12. setup refuses ---
{
  let err = null
  try {
    await runScript({ args: { ws: '/ws', parallel: [pr(1)] }, reply: (label) => (label === 'setup' ? { ok: false, reason: 'merge-1 is dirty', freeGb: 50 } : base(label)) })
  } catch (e) {
    err = e
  }
  console.log('12. a dirty worktree from an earlier run')
  check('the train stops', err !== null && /merge-1 is dirty/.test(String(err)), String(err))
}

// --- 13. no ws ---
{
  let err = null
  try {
    await runScript({ args: { parallel: [pr(1)] }, reply: base })
  } catch (e) {
    err = e
  }
  console.log('13. args.ws missing')
  check('it says so', err !== null && /args.ws is required/.test(String(err)), String(err))
}

// --- 14. slots is capped by the queue, and the gate is reached with slots=1 ---
{
  const r = await runScript({ args: { ws: '/ws', parallel: [pr(1)], slots: 8 }, reply: base })
  console.log('14. more slots than PRs')
  check('one slot only', r.out.slots === 1, r.out.slots)
  check('merged', r.out.merged === 1)
}

// --- 15. two PRs that touch iOS are never prepped at once ---
{
  const r = await runScript({
    args: {
      ws: '/ws',
      parallel: [
        pr(1, { files: ['iphone/Maps/Core/NoGps/MWMNoGps.mm'] }),
        pr(2, { files: ['libs/map/nogps/engine.cpp'] }),
        pr(3, { files: ['xcode/map/map.xcodeproj/project.pbxproj'] }),
        pr(4, { files: ['iphone/Maps/UI/Help/AboutController/AboutController.swift'] }),
      ],
      slots: 4,
    },
    reply: base,
  })
  console.log('15. three of four PRs touch iphone/ or xcode/')
  check('all four merged', r.out.merged === 4, r.out.results.map((x) => [x.pr, x.outcome, x.set]))
  const sets = Object.fromEntries(r.out.results.map((x) => [x.pr, x.set]))
  check('the first iOS PR stays parallel', sets[1] === 'parallel', sets)
  check('the one PR with no iOS files stays parallel', sets[2] === 'parallel', sets)
  check('the other iOS PRs moved to serial', sets[3] === 'serial' && sets[4] === 'serial', sets)
  check('only two slots were asked for', r.out.slots === 2, r.out.slots)
  check('the log says why', r.logs.some((m) => /#3, #4 moved to the serial set/.test(m)), r.logs)
  // The moved ones run one at a time, after the parallel merges: that is the point of moving them.
  const m3 = r.order.indexOf('+merge:#3')
  const u4 = r.order.indexOf('+update:#4')
  check('#4 starts only after #3 merged', u4 > m3 && m3 > 0, { m3, u4 })
}

// --- 16. one iOS PR alone still goes in parallel ---
{
  const r = await runScript({
    args: { ws: '/ws', parallel: [pr(1, { files: ['iphone/Maps/Core/NoGps/MWMNoGps.mm'] }), pr(2, { files: ['libs/a.cpp'] })], slots: 2 },
    reply: base,
  })
  console.log('16. a single iOS PR in the parallel set')
  check('both stay parallel', r.out.results.every((x) => x.set === 'parallel'), r.out.results.map((x) => [x.pr, x.set]))
  check('two preps at once', prepPeak(r.peak) === 2, r.peak)
  check('nothing was moved', !r.logs.some((m) => /moved to the serial set/.test(m)), r.logs)
}

// --- 17. a bigger mixed run, repeated: it always terminates and merges everything ---
{
  let bad = 0
  for (let i = 0; i < 25; i++) {
    const r = await runScript({
      args: {
        ws: '/ws',
        parallel: [pr(1), pr(2), pr(3), pr(4), pr(5), pr(6)],
        serial: [pr(7), pr(8)],
        slots: 3,
        rounds: 3,
      },
      reply: (label) => {
        if (label.startsWith('review') && Math.random() < 0.35)
          return { findings: [{ file: 'a.cpp', summary: 's', scenario: 'x' }] }
        if (label.startsWith('merge') && Math.random() < 0.2) return { status: 'stale', staleFiles: ['a.cpp'] }
        return base(label)
      },
    })
    if (r.out.results.length !== 8) bad++
  }
  console.log('17. 25 runs of 8 PRs with random findings and stale masters')
  check('every PR is accounted for in every run', bad === 0, { bad })
}

console.log(failures ? `\n${failures} check(s) FAILED` : '\nall checks passed')
process.exit(failures ? 1 : 0)
