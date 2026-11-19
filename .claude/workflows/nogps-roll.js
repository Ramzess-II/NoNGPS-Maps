export const meta = {
  name: 'nogps-roll',
  description: 'NonGPS issue roller: triage open issues, implement each in its own worktree up to a PR, postpone the blocked ones',
  whenToUse: 'Started by the /nogps-roll skill, which builds the queue: args {ws, queue, count, dry}',
  phases: [
    { title: 'Triage', detail: 'close covered issues, postpone outdated or blocked ones' },
    { title: 'Implement', detail: 'own worktree, nogps-pr steps 1-4' },
    { title: 'Review', detail: 'fresh context, correctness only' },
    { title: 'Publish', detail: 'fix findings, push, PR labeled roller, remove the worktree' },
  ],
}

// Slots: SLOTS workers take issues from one queue; at most one of them works on a change that touches iOS, which
// builds Xcode from scratch in its worktree. A worker starts an implementation only with MIN_FREE_GB on the disk.
const A = args || {}
const WS = A.ws
const APP = `${WS}/app`
const FW = `${WS}/firmware`
const DRY = !!A.dry
const COUNT = A.count ?? 4
const SLOTS = 4
const MIN_FREE_GB = 15
const APP_REPO = 'Ramzess-II/NoNGPS-Maps'
const FW_REPO = 'Ramzess-II/ELMandIMU'
const MAPS = A.maps || ''
const SETTINGS = A.settings || ''
const REPLAY = !!(MAPS && SETTINGS)
const LOGS = `${APP}/trip-logs`
const queue = [...(A.queue || [])]
if (!WS) throw new Error('args.ws is required: the folder that holds app/ and firmware/')

const ENV = `NonGPS Maps workspace: ${WS}. App repo ${APP_REPO}, main checkout ${APP}. Firmware repo ${FW_REPO} \
(ESP-IDF 5.5, C) in ${FW}; koloboid has read access there: firmware branches are pushed to the remote "koloboid" \
(the fork) and the PR goes from it; you can't add labels there, and close only issues koloboid opened.
Don't change the main checkouts ${APP} and ${FW}: other sessions work in them. The shell's working directory can \
reset between commands: use absolute paths, git -C <path>, or "cd <path> && ..." in each command.
You are one of up to ${SLOTS} parallel agents of the issue roller (/nogps-roll). Nobody answers questions during the \
run: never wait for a confirmation, decide or postpone. Write English only on GitHub. Other agents run git in the \
same repos: a git command that fails on a lock (index.lock, "cannot lock ref") is run again after a few seconds.`

const POSTPONE = `To postpone: comment on the issue with a body that starts with "**Roller: postponed.**" and says \
what is missing and what a person has to do or decide; if a WIP branch was pushed, name it. In ${APP_REPO} also add \
the label: gh issue edit <n> -R ${APP_REPO} --add-label postponed. In ${FW_REPO} the comment is the mark.`

const WORKTREES = `App worktree: git -C ${APP} fetch -q origin && ${APP}/tools/unix/nogps_worktree.sh add <name>; it \
prints the path (${WS}/worktrees/<name>), the branch is feature/<name>. Firmware worktree: git -C ${FW} fetch -q \
origin && git -C ${FW} worktree add --no-track -b feature/<name> ${WS}/worktrees/fw-<name> origin/main. Remove: \
${APP}/tools/unix/nogps_worktree.sh remove <path> (it refuses uncommitted changes: commit or drop them first), and \
git -C ${FW} worktree remove <path> for firmware.`

// Replay on macOS: the skill passes args.maps and args.settings only when this machine has them.
const REPLAY_RULES = REPLAY
  ? `A change to how the mark moves is replayed, not postponed: this machine replays the recorded trips. \
Maps: ${MAPS}, settings: ${SETTINGS}. Logs, <logs> below: the day files at the top of ${LOGS} (${LOGS}/*.log) when \
there are some, else the folder ${LOGS}/<phone> of the Android phone with the most days: the script reads a folder \
with its subfolders, logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log, and the lines of two phones must not be mixed. Build \
the tool as the docstring of tools/python/nogps_replay.py says, in <worktree>/build-<name>-o2: first from the worktree before your change (copy the binary to \
nogps_replay_tool.before), then after it. Drive the days of both with nogps_replay.py run <logs> --tool <tool> \
--data_path ${MAPS} --settings ${SETTINGS} -j 3 -o <folder in the scratchpad>. Put both tables, the held-out days \
and the others apart, into "tested". Fix a rule that is worse on the held-out days, or postpone when the numbers \
don't settle what to change. Say "Not replayed" only when the tool fails to build or run, and why.`
  : `This run has no replay data (args.maps, args.settings): a change to how the mark moves is replayed by nobody, \
so its PR says "Not replayed".`

const ref = (it) => `${it.repo}#${it.number}`
const isFw = (it) => it.repo === FW_REPO

const TRIAGE_SCHEMA = {
  type: 'object',
  properties: {
    decision: { type: 'string', enum: ['implement', 'closed', 'postponed', 'skipped'] },
    reason: { type: 'string', description: 'one line for the report table' },
    evidence: { type: 'string', description: 'links of the PRs, commits or issues that decided it' },
    name: { type: 'string', description: 'kebab-case branch name for feature/<name>, when implement' },
    app: { type: 'boolean', description: 'the change touches the app repo' },
    firmware: { type: 'boolean', description: 'the change touches the firmware repo' },
    ios: { type: 'boolean', description: 'the change touches iphone/ or xcode/' },
    freeGb: { type: 'number', description: 'free GB on the disk of the workspace, from df -g' },
  },
  required: ['decision', 'reason', 'ios', 'freeGb'],
}

const WORKTREE_LIST = {
  type: 'array',
  items: {
    type: 'object',
    properties: {
      repo: { type: 'string', enum: [APP_REPO, FW_REPO] },
      path: { type: 'string' },
      branch: { type: 'string' },
    },
    required: ['repo', 'path', 'branch'],
  },
}

const IMPL_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['ready', 'postponed'] },
    reason: { type: 'string', description: 'why it was postponed, one line' },
    worktrees: WORKTREE_LIST,
    title: { type: 'string', description: 'PR title: [subsystem] Summary in imperative mood' },
    why: { type: 'string', description: 'the problem and its evidence' },
    what: { type: 'string', description: 'behavior changes, with names of constants and functions' },
    tested: { type: 'string', description: 'commands run and their results' },
    otherPlatform: { type: 'string', description: 'links of the follow-up issues, or "Nothing to do: <why>"' },
    sharedInterface: { type: 'boolean', description: 'the change touches the shared interface' },
  },
  required: ['status', 'worktrees'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'number' },
          summary: { type: 'string' },
          scenario: { type: 'string', description: 'concrete input or state and the wrong result' },
        },
        required: ['file', 'summary', 'scenario'],
      },
    },
  },
  required: ['findings'],
}

const PUBLISH_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['pr', 'postponed'] },
    prs: { type: 'array', items: { type: 'string' }, description: 'PR URLs' },
    reason: { type: 'string', description: 'why it was postponed, one line' },
    leftWorktrees: { type: 'array', items: { type: 'string' }, description: 'worktrees that could not be removed' },
  },
  required: ['status', 'prs'],
}

const DISK_SCHEMA = { type: 'object', properties: { freeGb: { type: 'number' } }, required: ['freeGb'] }

function triagePrompt(it) {
  const repoDir = isFw(it) ? FW : APP
  const base = isFw(it) ? 'origin/main' : 'origin/master'
  return `${ENV}

Triage ${ref(it)} "${it.title}" (opened ${it.createdAt}) for the issue roller.
${DRY ? 'DRY RUN: write nothing to GitHub. Report the decision you would take, and do nothing else.\n' : ''}
1. Read it: gh issue view ${it.number} -R ${it.repo} --comments. git -C ${repoDir} fetch -q origin.
2. Find work newer than the issue on the same thing: merged PRs (gh pr list -R ${it.repo} --state merged --search \
"<keywords> merged:>=${it.createdAt.slice(0, 10)}"), commits on ${base} since then (git -C ${repoDir} log ${base} \
--since=${it.createdAt.slice(0, 10)} -- <paths the issue names>), and newer issues, open or closed. Read the code \
the issue points to as it is on ${base} (git -C ${repoDir} show ${base}:<path>): is the problem still there?
3. "skipped" when someone works on it already: an open PR that names it or changes the same code (gh pr list -R \
${it.repo} --state open), a branch for it (git -C ${repoDir} branch -a), or a worktree (git -C ${repoDir} worktree \
list). Write nothing on GitHub for a skip.
4. "closed" when a merged PR, a commit or a newer issue covers it: comment with the links, then gh issue close \
${it.number} -R ${it.repo} --reason completed, or --reason "not planned" when a newer issue supersedes it (say \
"Superseded by #M"). In ${FW_REPO} you can close only issues opened by koloboid: otherwise comment and report \
"postponed" with the reason "covered, Ramzess closes it".
5. "postponed" when it only looks outdated (the code moved, its plan names things that changed) and nothing \
clearly covers it; when only a drive, a phone, a flashed box or a trip replay can show what to change or that the \
change works; when it needs a decision of a person or the expected behavior is unclear; or when the work is outside \
both repos (e.g. the web site). A core change that unit tests can show is not postponed for a missing replay. ${REPLAY_RULES} \
${POSTPONE}
6. Otherwise "implement". Give a short kebab-case name for the branch feature/<name> that no branch (git -C ${APP} \
branch -a, git -C ${FW} branch -a) or ${WS}/worktrees/<name> uses yet. Say which repos it touches, and whether it \
touches iOS: iphone/ or xcode/, which includes a behavior both apps show, a change of a bridge, and a new file in \
libs/map/nogps (it goes into the Xcode project).
Always run df -g ${WS} and report the free GB (the "Avail" column).`
}

function implementPrompt(it, t) {
  return `${ENV}

Implement ${ref(it)} "${it.title}" for the issue roller, up to commits ready for review.
Triage notes: ${JSON.stringify(t)}

- Worktrees: name ${t.name}. ${WORKTREES} A change of the box protocol changes both repos: make both worktrees.
- Follow .claude/rules/nogps-workflow.md and steps 1-4 of .claude/skills/nogps-pr/SKILL.md (read it in the \
worktree): scope, verification, living docs in a separate [docs] commit, both platforms, follow-up issues for \
everything left. Build in <worktree>/build-${t.name}. Core tests: cmake --preset debug -B build-${t.name} \
-DSKIP_QT_GUI=ON, then just test "NoGps_.*" build-${t.name}. iOS: build with -derivedDataPath \
<worktree>/build-${t.name}-ios, so removing the worktree frees it. Firmware: build it with ESP-IDF the way \
${FW}/README.md says (". ~/esp/esp-idf/export.sh" on the Mac); build unsigned when the signing key is missing.
- Commits: the "Commit messages" format of CLAUDE.md, git commit -s. Run the formatters and checks CI gates for \
the files you changed (clang-format 23: uvx --from clang-format==23.1.3 clang-format -i <files>; swiftformat; \
ktlint).
- ${REPLAY_RULES}
- When tests fail, make up to 3 attempts to fix them, then postpone.
- Postpone when you can't finish: it needs a drive, a phone, a flashed box or a replay you can't run to know what to change; the \
expected behavior turns out unclear; tests still fail after 3 attempts. Then: commit the WIP, push the branch \
(app: git push -u origin feature/${t.name}; firmware: git push -u koloboid feature/${t.name}) if it has commits, \
${POSTPONE} Then remove the worktrees and report "postponed".
- Don't open a PR: a fresh reviewer checks the branch, then a publisher pushes it and opens the PR.
Report the worktrees with their branches, and the PR text parts: title, why, what, tested (commands and results, \
"Not replayed" and "Xcode project not verified" where they apply), otherPlatform (follow-up issue links, or \
"Nothing to do: <why>").`
}

function reviewPrompt(it, impl) {
  const trees = impl.worktrees.map((w) => `${w.path} (${w.repo}, diff against ${w.repo === FW_REPO ? 'origin/main' : 'origin/master'})`)
  return `${ENV}

Review the change for ${ref(it)} "${it.title}" in ${trees.join(' and ')}: git -C <path> diff <base>...HEAD. You \
didn't write it. Read the issue (gh issue view ${it.number} -R ${it.repo} --comments) and the code around the diff.
Look for correctness bugs only: wrong behavior, missed corner cases, a behavior both apps show changed on one \
platform only, a shared interface changed in one bridge only, tests that don't test the change, living docs \
(docs/nogps/navigation-rules.md, esp32-firmware-spec.md) that no longer match the code, generated files edited by \
hand. Give each finding a file, a line and a concrete failing scenario. Leave out style preferences and defensive \
code for cases that can't happen. Change nothing: no edits, commits or GitHub writes.`
}

function publishPrompt(it, impl, review) {
  const reviewer = `the other of koloboid and Ramzess-II (gh api user -q .login is you)`
  return `${ENV}

Finish ${ref(it)} "${it.title}" and open its PR. Implementation report: ${JSON.stringify(impl)}
Review findings: ${JSON.stringify(review ? review.findings : [])}

1. Check each finding against the code. Fix the ones that hold, skip the wrong ones. Commit the fixes (git commit -s) \
and run the tests of the report again. Up to 3 attempts when they fail, then postpone.
2. git fetch origin. If the branch no longer merges cleanly into the base, merge the base in and resolve; if the \
resolution isn't clear, postpone.
3. Push: git -C <worktree> push -u origin <branch> (firmware: push -u koloboid <branch>).
4. PR, without asking: gh pr create -R ${APP_REPO} --base master --head <branch> --label roller --title "<title>" \
--body-file -. Firmware: gh pr create -R ${FW_REPO} --base main --head koloboid:<branch> (no label there). The body \
is bold-label paragraphs, no ## headings (CI's other-platform check reads only a "**Other platform**" line): \
"Fixes ${it.repo === APP_REPO ? '#' + it.number : ref(it)}", **Why**:, **What**:, **Tested**:, **Other platform**:, \
then "Opened by the issue roller (/nogps-roll). Written with Claude Code." and the model name. With PRs in both \
repos, link each from the other, and the PR in the other repo says "Related ${ref(it)}" instead of Fixes. If the change touches the shared interface, request ${reviewer}: gh pr edit <n> \
--add-reviewer <login>.
5. Remove the worktrees (${WORKTREES}).
If you postpone: push the branch, ${POSTPONE} Remove the worktrees, report "postponed".`
}

// Scheduler state, shared by the workers. JS runs them on one thread, so plain counters are safe between awaits.
let reserved = 0 // issues being triaged, waiting for the iOS slot, or implemented
let implementing = 0
let implDone = 0
let iosBusy = false
let diskStop = false
const deferred = [] // triaged for implementation, waiting for the iOS slot
const results = []
let waiters = []
const changed = () => new Promise((resolve) => waiters.push(resolve))
function notify() {
  const w = waiters
  waiters = []
  w.forEach((resolve) => resolve())
}

function take() {
  if (!iosBusy && deferred.length) return deferred.shift()
  if (diskStop || reserved >= COUNT) return null
  const i = queue.findIndex((q) => !(q.ios && iosBusy))
  if (i < 0) return null
  reserved++
  return { it: queue.splice(i, 1)[0] }
}

function record(it, outcome, reason, links) {
  results.push({ issue: ref(it), title: it.title, outcome, reason: reason || '', links: links || [] })
  log(`${ref(it)}: ${outcome}${reason ? ' (' + reason + ')' : ''}`)
}

async function freeDisk(it) {
  const d = await agent(`Run df -g ${WS} and report the free GB (the "Avail" column). Nothing else.`, {
    label: `disk:${it.number}`,
    phase: 'Triage',
    effort: 'low',
    schema: DISK_SCHEMA,
  })
  return d ? d.freeGb : 0
}

async function implement(it, t) {
  const tag = `${isFw(it) ? 'fw' : ''}#${it.number}`
  const impl = await agent(implementPrompt(it, t), { label: `implement:${tag}`, phase: 'Implement', schema: IMPL_SCHEMA })
  if (!impl) return record(it, 'failed', 'the implementing agent stopped; check its worktree')
  if (impl.status !== 'ready') return record(it, 'postponed', impl.reason)
  const review = await agent(reviewPrompt(it, impl), { label: `review:${tag}`, phase: 'Review', schema: REVIEW_SCHEMA })
  const pub = await agent(publishPrompt(it, impl, review), {
    label: `publish:${tag}`,
    phase: 'Publish',
    schema: PUBLISH_SCHEMA,
  })
  if (!pub) return record(it, 'failed', 'the publishing agent stopped; check its worktree')
  const left = pub.leftWorktrees && pub.leftWorktrees.length ? `; left ${pub.leftWorktrees.join(', ')}` : ''
  if (pub.status !== 'pr') return record(it, 'postponed', (pub.reason || '') + left)
  record(it, 'PR', (review ? `${review.findings.length} review findings` : 'review failed') + left, pub.prs)
}

// One issue of a worker. Returns after it is recorded, or after it went to `deferred` for the iOS slot.
async function run(job) {
  const it = job.it
  let t = job.t
  let free
  if (t) {
    free = await freeDisk(it) // waited for the iOS slot: the triage's number is old
  } else {
    t = await agent(triagePrompt(it), { label: `triage:${ref(it)}`, phase: 'Triage', schema: TRIAGE_SCHEMA })
    if (!t || t.decision !== 'implement' || DRY) {
      if (!t) record(it, 'failed', 'the triage agent stopped')
      else {
        const reason = [t.reason, DRY && t.name].filter(Boolean).join('; ')
        record(it, DRY ? `dry: ${t.decision}` : t.decision, reason, t.evidence ? [t.evidence] : [])
      }
      if (!t || !DRY) reserved-- // a dry run counts the issues it triaged
      return
    }
    it.ios = it.ios || t.ios
    t.name = t.name || `roll-${it.number}`
    free = t.freeGb
  }
  while (free < MIN_FREE_GB && implementing > 0) {
    const before = implDone
    while (implDone === before) await changed()
    free = await freeDisk(it)
  }
  if (free < MIN_FREE_GB) {
    diskStop = true
    return record(it, 'not started', `${free} GB free, needs ${MIN_FREE_GB}`)
  }
  // No await between this check and taking the slot, so two workers can't both take it.
  if (it.ios && iosBusy) return deferred.push({ it, t })
  implementing++
  if (it.ios) iosBusy = true
  try {
    await implement(it, t)
  } finally {
    implementing--
    implDone++
    if (it.ios) iosBusy = false
  }
}

let held = 0 // issues a worker is busy with
async function worker() {
  for (;;) {
    const job = take()
    if (!job) {
      // Only a running issue can free a reservation or the iOS slot; with none, nothing more can start.
      if (held === 0) return
      await changed()
      continue
    }
    held++
    try {
      await run(job)
    } catch (e) {
      record(job.it, 'failed', `${e}; check its worktree`)
    } finally {
      held--
      notify()
    }
  }
}

log(`${queue.length} issues in the queue, ${DRY ? 'dry run: triage ' + COUNT : 'up to ' + COUNT + ' into implementation'}`)
await parallel(Array.from({ length: SLOTS }, () => worker))
const left = queue.length + deferred.length
if (left) log(`${left} issues not taken: count reached${diskStop ? ' or the disk is full' : ''}`)
return { results, notTaken: queue.concat(deferred.map((d) => d.it)).map(ref) }
