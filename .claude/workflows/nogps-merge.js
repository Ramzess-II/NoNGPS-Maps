export const meta = {
  name: 'nogps-merge',
  description: 'NonGPS merge train: prep the independent PRs in parallel, then merge them one at a time',
  whenToUse: 'Started by /nogps-merge, which builds the two sets: args {ws, parallel, serial, rounds, slots, maxReviews}',
  phases: [
    { title: 'Setup', detail: 'the merge gate worktree, and one per prep slot when a PR needs it' },
    { title: 'Update', detail: 'merge current master into the PR branch, push fast-forward' },
    { title: 'Review', detail: 'correctness only, the findings posted on the PR', model: 'opus' },
    { title: 'Fix', detail: 'check each finding, fix the ones that hold, push', model: 'sonnet' },
    { title: 'Confirm', detail: 'a PR clean on the first pass, read once more before the gate', model: 'fable' },
    { title: 'Merge', detail: 'the serial gate: did master move, the pair tested together, CI, merge commit' },
    { title: 'Clean', detail: 'remove the train worktrees' },
  ],
}

// Prep is parallel, the merge serial. Up to SLOTS workers each take one PR of the parallel set -- the PRs whose
// files no other queued PR touches and that are in no dependency chain with one -- bring master into it, review and
// fix it in the worker's own worktree, and push: from there on the PRs' CI runs overlap instead of one waiting for
// the other. The merge gate then takes one ready PR at a time: it checks that master gained no file this PR touches
// since its prep, merges the PR into current master locally and runs the core tests on the two together (no CI run
// tests that pair: each PR's checks ran before the other one landed), and merges on GitHub. The serial set goes
// after, one PR at a time in the gate worktree, the way the whole train worked before.
// The train never rewrites a branch: it merges master into the PR branch, so every push is a fast-forward. No
// rebase and no force push, not even with a lease.
const A = args || {}
const WS = A.ws
if (!WS) throw new Error('args.ws is required: the folder that holds app/')
const APP = `${WS}/app`
const FIRMWARE = `${WS}/firmware`
const APP_REPO = 'Ramzess-II/NoNGPS-Maps'
const FW_REPO = 'Ramzess-II/ELMandIMU'
const GATE = 'merge-train'
const ROUNDS = A.rounds ?? 3
// --rounds bounds one run; this bounds a PR over all runs. Every review is Opus or Fable, and a PR that keeps
// coming back to the train spent 5 to 7 of them in two or three runs (#470, #601). The count is the PR's
// "Merge-train review" comments, which the skill passes in as pr.reviews; the confirmation counts as one.
const MAX_REVIEWS = A.maxReviews ?? 5
const MIN_FREE_GB = 15

// The train lands the PRs of both repos. Each one has its own checkout, its own default branch -- the firmware repo
// has no master, its default branch is main -- and its own way of being built and checked: a firmware PR gets the S3
// and C3 builds of `.github/workflows/build.yml`, and the gate's local build stays as well, it is not optional: it
// is the only one that uses the chip-specific sdkconfig of the main checkout.
// `keys/` and `sdkconfig` are gitignored in the firmware repo, so a fresh worktree has neither and both come from
// the main checkout: the signing key, because sdkconfig.defaults signs the image with
// keys/nogps_signing_key.pem, and sdkconfig, because sdkconfig.defaults alone does not reproduce it -- it leaves
// the target at esp32 and the scheme at secure boot v1 (ECDSA), while the box is an esp32s3 signed with the v2 RSA
// scheme, and the build then dies on "Incorrect ECDSA private key". sdkconfig is copied, not linked: idf.py
// rewrites it, and it has to be in place before the first build, which caches the target in CMakeCache.txt.
const REPOS = {
  [APP_REPO]: { dir: APP, base: 'master', suffix: '', what: 'the app' },
  [FW_REPO]: { dir: FIRMWARE, base: 'main', suffix: '-fw', what: 'the box firmware' },
}
const repoName = (pr) => pr.repo || APP_REPO
const R = (pr) => {
  const r = REPOS[repoName(pr)]
  if (!r) throw new Error(`PR #${pr.number}: unknown repo ${pr.repo}, not ${APP_REPO} or ${FW_REPO}`)
  return r
}

const WT = (name) => `${WS}/worktrees/${name}`
const BUILD = (name) => `${WT(name)}/build-${name}` // absolute, for cmake -B
const BUILD_REL = (name) => `build-${name}` // relative, `just test` takes the dir name
const slotName = (i) => `merge-${i}`
// A worktree belongs to one repo, so a slot that takes a firmware PR gets a second one next to its app worktree.
const wtName = (slot, pr) => `${slot}${R(pr).suffix}`
// The app's worktrees come from the helper, which clones the submodules from the main checkout with no network and
// links the gitignored inputs. The firmware repo has no submodules, so plain git plus the keys/ link is enough.
const ADD_WT = (pr, name) =>
  R(pr).suffix
    ? `git -C ${FIRMWARE} worktree add --no-track -b feature/${name} ${WT(name)} origin/main && \
ln -sfn ${FIRMWARE}/keys ${WT(name)}/keys && cp ${FIRMWARE}/sdkconfig ${WT(name)}/sdkconfig`
    : `${APP}/tools/unix/nogps_worktree.sh add ${name}`
// The gate's worktree is made at launch and can be removed under a running train. Its branch outlives the directory:
// prune the stale registration and reuse the branch, as `add -b` fails on one that exists.
const REMAKE_GATE = (pr, wt) => {
  const name = GATE + R(pr).suffix
  const repo = R(pr).suffix ? FIRMWARE : APP
  // A directory that is no registered worktree (only build-${name} left, or a remove that failed midway) is not a
  // worktree either: clear it, or `add` refuses the path.
  const clear = `git -C ${repo} worktree prune && git -C ${repo} fetch -q origin && (git -C ${repo} worktree list --porcelain | \
grep -qx 'worktree ${wt}' || rm -rf ${wt})`
  return R(pr).suffix
    ? `${clear} && (git -C ${FIRMWARE} worktree add --no-track -b feature/${name} ${wt} origin/main || \
git -C ${FIRMWARE} worktree add ${wt} feature/${name}) && ln -sfn ${FIRMWARE}/keys ${wt}/keys && \
cp ${FIRMWARE}/sdkconfig ${wt}/sdkconfig`
    : `${clear}, then, as the helper refuses a branch that exists: if git -C ${APP} rev-parse -q --verify \
feature/${name} succeeds, delete the branch (git -C ${APP} branch -D feature/${name}) only when \
git -C ${APP} rev-list feature/${name} --not --remotes prints nothing, and otherwise rename it \
(git -C ${APP} branch -m feature/${name} feature/${name}-old-$(date +%s)) so nobody's commits are lost; then \
${APP}/tools/unix/nogps_worktree.sh add ${name}`
}
// True when the worktree is missing or only a leftover directory: the check of every step that works in the gate.
const GONE = (repo, wt) => `${wt} isn't listed by git -C ${repo} worktree list --porcelain, or is listed there as prunable \
(its directory was deleted) (missing, or a leftover directory)`
const RM_WT = (name) =>
  name.endsWith('-fw')
    ? `git -C ${FIRMWARE} worktree remove --force ${WT(name)}`
    : `${APP}/tools/unix/nogps_worktree.sh remove ${WT(name)}`
// The firmware build of the PR merged into main: the only build that uses the main checkout's sdkconfig. A missing toolchain or
// signing key is not a test failure: nothing was built, so the gate refuses to merge the PR ("blocked") and says why.
// Relative to the worktree (or its android/ for the gradle calls): the main checkout may not have the script on its branch.
const QUIET = 'tools/unix/nogps_quiet.sh'
const FW_BUILD = (name) => `cd ${WT(name)} && . ~/esp/esp-idf/export.sh >/dev/null && ${QUIET} idf.py build`
// Why every build and test command below goes through QUIET: it prints the tail on success and the error lines plus the
// tail on failure, so a build log doesn't fill the agent's context. The full output is in the log file it names.

// The skill splits the queue in step 3. args.queue, the single queue of the serial train, is taken as the serial
// set, so a call written by hand still works.
const pending = [...(A.parallel || [])]
// Keyed by repo and number: the two repos number their PRs apart, so ELMandIMU#19 is not NoNGPS-Maps#19.
const key = (pr) => `${repoName(pr)}#${pr.number}`
const taken = new Set(pending.map(key))
const serial = (A.serial || A.queue || []).filter((pr) => !taken.has(key(pr)))

// Nothing in the train builds iOS: the gate leaves iphone/ and xcode/ to each PR's own CI, and that ran before the
// other PRs of the parallel set landed. Disjoint files are not disjoint code -- a method changed in MWMNoGps.h, its
// caller in a Swift file the other PR never touches -- so a pair that breaks only the iOS build would land and
// leave master red. At most one PR that touches iOS is prepped at a time; the rest go to the front of the serial
// set, where each is reviewed on the master the one before it made.
const touchesIos = (pr) => (pr.files || []).some((f) => f.startsWith('iphone/') || f.startsWith('xcode/'))
const movedIos = pending.filter(touchesIos).slice(1)
movedIos.forEach((pr) => pending.splice(pending.indexOf(pr), 1))
serial.unshift(...movedIos)
const SLOTS = pending.length ? Math.max(1, Math.min(A.slots ?? 4, pending.length)) : 0
const STEPS = Math.max(SLOTS, 1) // steps of the train running at once: one per prep slot, or the single serial one
pending.forEach((pr) => Object.assign(pr, { set: 'parallel', round: 0, reviews: pr.reviews || 0 }))
serial.forEach((pr) => Object.assign(pr, { set: 'serial', round: 0, reviews: pr.reviews || 0 }))
// R() throws on a repo the train doesn't know: the queue is checked before any agent runs, not per step.
const QUEUE = [...pending, ...serial] // pending and serial are drained as the run goes: keep the whole queue
const SUFFIXES = [...new Set(QUEUE.map((pr) => R(pr).suffix))]
// One gate and one prep slot per repo in the queue: a worktree belongs to one repo, and the gate merges the PRs of
// both. A slot's worktree is made only when a PR of that repo reaches it, so a run of one repo makes none of the
// other's.
const NAMES = SUFFIXES.flatMap((s) => [GATE + s, ...Array.from({ length: SLOTS }, (_, i) => slotName(i + 1) + s)])

const ENV = `NonGPS Maps workspace: ${WS}. ${APP_REPO} (the app) in ${APP}, ${FW_REPO} (the box firmware) in \
${FIRMWARE}. Each PR says which of the two it belongs to; the firmware repo's default branch is main, not master.
Don't change either main checkout (${APP}, ${FIRMWARE}): another session works in them. Every step of the train \
works in the worktree the step names, under ${WS}/worktrees/ (the firmware's worktrees end in -fw). The shell's \
working directory can reset between commands: use absolute paths, git -C <path>, or "cd <path> && ..." in each \
command.
You are one step of the merge train (/nogps-merge), which runs up to ${STEPS} ${STEPS === 1 ? 'step' : 'steps'} \
at once. The user \
started the run and nobody answers questions during it: never wait for a confirmation. When you can't finish your \
step, change nothing more, report it, and leave the PR open. Write English only on GitHub.
Other agents run git in the same repo: a git command that fails on a lock (index.lock, "cannot lock ref", or the \
worktree lock of the main checkout the worktree belongs to) is run again after a few seconds.`

// The PR's own branch is never checked out: it may be checked out in the main checkout or another worktree, and
// git refuses that. The train works on train/<n> and pushes it to the PR's branch by its full refname.
// --ignore-other-worktrees: a PR the gate sends back as stale is prepped by whichever worker takes it next, while
// the slot that prepped it before still has train/<n> checked out, and git refuses that branch without the flag
// (--force doesn't cover it). Only one worker holds a PR at a time, so the two never write the branch at once.
// Both of us open a PR from a branch of the repo and from our own fork. A fork's branch is in no remote of the
// checkout, so the head comes from a remote named after the fork's owner, and the update's and the fix's push go
// back to that fork's branch -- the one the PR is open from. The remote is added to the main checkout, the only
// place git keeps them: its worktrees all see it, and adding one touches no working tree. A fork of anyone but the
// two of us never reaches the train: the skill leaves it out of the queue, and REMOTE throws on it.
const OWNERS = ['koloboid', 'Ramzess-II']
const repoOwner = (pr) => repoName(pr).split('/')[0]
const headOwner = (pr) => pr.headOwner || repoOwner(pr)
const REMOTE = (pr) => {
  const owner = headOwner(pr)
  if (owner === repoOwner(pr)) return 'origin'
  if (!OWNERS.includes(owner))
    throw new Error(`PR #${pr.number}: head is in a fork of ${owner}, not of ${OWNERS.join(' or ')}`)
  return owner
}
const ADD_REMOTE = (pr) =>
  `(git -C ${R(pr).dir} remote get-url ${REMOTE(pr)} >/dev/null 2>&1 || git -C ${R(pr).dir} remote add \
${REMOTE(pr)} git@github.com:${headOwner(pr)}/${repoName(pr).split('/')[1]}.git)`
// The base always comes from origin, the head from its own remote: both are fetched when they differ.
const FETCH = (pr, wt) =>
  REMOTE(pr) === 'origin'
    ? `git -C ${wt} fetch -q origin`
    : `${ADD_REMOTE(pr)} && git -C ${wt} fetch -q origin && git -C ${wt} fetch -q ${REMOTE(pr)}`
const HEAD_REF = (pr) => `refs/remotes/${REMOTE(pr)}/${pr.branch}`
const CHECKOUT = (pr, wt) => `${FETCH(pr, wt)} && git -C ${wt} checkout --force \
--ignore-other-worktrees -B train/${pr.number} ${HEAD_REF(pr)} && git -C ${wt} submodule update \
--init --recursive`
const PUSH = (pr, wt) => `git -C ${wt} push ${REMOTE(pr)} HEAD:refs/heads/${pr.branch}`
// Like R() above: the whole queue is checked before any agent runs, not when a step first builds its prompt.
;[...pending, ...serial].forEach((pr) => REMOTE(pr))
// The label of a step, and of the PR in the log: the firmware's numbers are its own, so they are told apart.
const tag = (pr) => `${R(pr).suffix ? 'fw' : ''}#${pr.number}`

const SETUP_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean', description: 'the gate worktree is there and every worktree of the train is clean' },
    reason: { type: 'string', description: 'why not, one line' },
    freeGb: { type: 'number', description: 'free GB on the disk of the workspace, from df -g' },
  },
  required: ['ok', 'freeGb'],
}

const DISK_SCHEMA = {
  type: 'object',
  properties: { freeGb: { type: 'number', description: 'free GB on the disk of the workspace' } },
  required: ['freeGb'],
}

const UPDATE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['ok', 'conflict', 'moved', 'failed'] },
    reason: { type: 'string', description: 'one line for the report table' },
    head: { type: 'string', description: 'the sha of the head after the merge' },
    prepMaster: { type: 'string', description: 'the sha of origin/master this update merged, for the merge gate' },
    updated: { type: 'boolean', description: 'the branch was behind master and now has it merged in' },
    diffStat: { type: 'string', description: 'git diff --shortstat origin/master...HEAD' },
    remade: { type: 'boolean', description: 'the gate worktree was missing and step 1 made it again' },
  },
  required: ['status'],
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
          summary: { type: 'string', description: 'one sentence: the defect' },
          scenario: { type: 'string', description: 'concrete input or state and the wrong result' },
          cycle: {
            type: 'object',
            description: 'only when the finding undoes an earlier fix or repeats a rejected finding',
            properties: {
              round: { type: 'number', description: 'the round of the earlier review, as its comment heading says' },
              kind: { type: 'string', enum: ['undo', 'again'] },
            },
            required: ['round', 'kind'],
          },
        },
        required: ['file', 'summary', 'scenario'],
      },
    },
    comment: { type: 'string', description: 'URL of the comment posted on the PR' },
  },
  required: ['findings'],
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['pushed', 'nothing', 'failed'] },
    fixed: { type: 'number', description: 'findings fixed' },
    rejected: { type: 'number', description: 'findings judged wrong or out of this PR' },
    reply: { type: 'string', description: 'what was fixed and what was rejected, one line each' },
    head: { type: 'string', description: 'the new head sha' },
    issues: { type: 'array', items: { type: 'string' }, description: 'issues opened for work left out' },
    reason: { type: 'string', description: 'why it failed, one line' },
  },
  required: ['status', 'fixed', 'rejected'],
}

const MERGE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['merged', 'stale', 'test', 'blocked', 'ci', 'conflict', 'failed'] },
    reason: { type: 'string', description: 'one line for the report table, with the failing checks when ci' },
    staleFiles: { type: 'array', items: { type: 'string' }, description: 'files master gained that this PR touches' },
    combinedTest: { type: 'string', description: 'the core tests with this PR merged into current master, one line' },
    mergeCommit: { type: 'string' },
    remade: { type: 'boolean', description: 'the gate worktree was missing and step 0 made it again' },
  },
  required: ['status'],
}

function setupPrompt() {
  return `${ENV}

Prepare the worktrees of the train: ${NAMES.join(', ')} under ${WS}/worktrees/. ${SUFFIXES.map((s) => GATE + s).join(' and ')} \
${SUFFIXES.length > 1 ? 'are the merge gates, one per repo' : 'is the merge gate'}, which merges every PR and preps \
the ones the train takes one at a time; the others are the prep slots, one PR at a time in each. A name ending in \
-fw belongs to ${FW_REPO} in ${FIRMWARE}, the others to ${APP_REPO} in ${APP}.
1. git -C ${APP} fetch -q origin${SUFFIXES.includes('-fw') ? ` && git -C ${FIRMWARE} fetch -q origin` : ''}.
2. Make the gate worktree of each repo in the queue, the ones that don't exist yet:
${SUFFIXES.map((s) =>
  s
    ? `   - ${WT(GATE + s)}: git -C ${FIRMWARE} worktree add --no-track -b feature/${GATE + s} ${WT(GATE + s)} \
origin/main && ln -sfn ${FIRMWARE}/keys ${WT(GATE + s)}/keys && cp ${FIRMWARE}/sdkconfig \
${WT(GATE + s)}/sdkconfig (keys/ and sdkconfig are gitignored there: without the key the signed build fails, and \
without that sdkconfig the build takes the esp32 target and secure boot v1 instead of the box's esp32s3 and v2 \
RSA. Both before the first build, which caches the target)`
    : `   - ${WT(GATE)}: ${APP}/tools/unix/nogps_worktree.sh add ${GATE} (it makes the branch feature/${GATE} from \
origin/master, clones the submodules from the main checkout with no network, and prints the path)`,
).join('\n')}
   Don't make the prep slots: the first PR that needs one makes it, so a short run makes none.
3. For each of ${NAMES.join(', ')} that does exist, from an earlier run: git -C <path> status --short. Clean: leave \
it as it is, it gets reused. Dirty with changes nobody pushed: report ok false with the worktree and what is in it; \
the train then stops and a person looks at it.
4. Run df -g ${WS} and report the free GB (the "Avail" column).
Nothing else: no builds, no GitHub writes.`
}

function updatePrompt(pr, name) {
  const wt = WT(name)
  const { base } = R(pr)
  const repo = repoName(pr)
  return `${ENV}

Bring current ${base} into PR #${pr.number} "${pr.title}" of ${repo} (branch ${pr.branch}, head ${pr.head}), in \
${wt}.
IMPORTANT: never rebase this branch and never force-push it, with or without a lease. The branch is only ever \
moved forward: ${base} is merged into it, so the push is a fast-forward. A push that would need a force is a \
"moved" report, not a force push.
1. If ${GONE(R(pr).suffix ? FIRMWARE : APP, wt)}: ${name.startsWith(GATE) ? `${REMAKE_GATE(pr, wt)} Report remade true.` : ADD_WT(pr, name)}
   Another step of the train may hold the worktree lock of the main checkout: run it again after a few seconds.
2. ${CHECKOUT(pr, wt)}
   If the PR's head on GitHub is no longer ${pr.head} (gh pr view ${pr.number} -R ${repo} --json headRefOid), \
somebody pushed to it while the train was running: report "moved" and stop.
3. Report prepMaster, the ${base} this prep is made on: git -C ${wt} rev-parse origin/${base}, after the fetch of \
step 2. The merge gate compares it with ${base} at merge time to see whether this review still covers the code.
4. git -C ${wt} merge --no-edit origin/${base}. Already has it in ("Already up to date"): report "ok" with \
updated false and push nothing.
5. A conflict: resolve it only where both sides make the resolution plain (both added a line to the same list, a \
constant moved, a string table). Read the code around it, not only the conflict markers. Anything else, or a \
conflict in a generated file: git -C ${wt} merge --abort, report "conflict" with the files, and stop. The PR \
stays open for a person.
6. After a resolved conflict, check that nothing of the PR was dropped and nothing of ${base} was undone: \
git -C ${wt} diff origin/${base}...HEAD against the PR's own diff on GitHub (gh pr diff ${pr.number} -R ${repo}).
7. Push the branch: ${PUSH(pr, wt)}
   Rejected as non-fast-forward: somebody pushed meanwhile, report "moved". Don't force it.
8. Report the new head (git -C ${wt} rev-parse HEAD) and git -C ${wt} diff --shortstat origin/${base}...HEAD.
Don't build and don't write on GitHub beyond this push.`
}

function reviewPrompt(pr, round, history, name, confirm) {
  const wt = WT(name)
  const { base } = R(pr)
  const repo = repoName(pr)
  const again = history.length
    ? `\nThis is round ${round}. The findings of every earlier round of this run -- yours, or the confirming \
reviewer's -- and what the fixer did with each: ${JSON.stringify(history)}. Check each of them in the code again: a \
fix that doesn't hold is a finding again, and so is a new bug the fix brought. Don't repeat a finding you now agree \
was wrong.`
    : confirm
      ? `\nAnother reviewer has just read this PR and found nothing, and you are the last read before the gate \
merges it: nobody else looks at it. Read the diff yourself and judge it on what you see -- that the review before \
you came back empty is no reason to come back empty, and no reason to find something either.`
      : ''
  return `${ENV}

Review PR #${pr.number} "${pr.title}" of ${repo} in ${wt}, with current ${base} just merged in: git -C ${wt} diff \
 origin/${base}...HEAD. \
You didn't write it. Read the PR and its issue (gh pr view ${pr.number} -R ${repo} --comments), and the code around \
the diff, not only the diff.${again}
Earlier runs of the train may have reviewed it too: their "**Merge-train review" and "**Merge-train fixes" \
comments are in that output. A review and a fixer that keep undoing each other spend the rounds and settle nothing, \
so mark a finding with cycle {round, kind} when it is one of these, against any earlier round of this run or of an \
earlier one:
- undo: it asks to undo, in whole or in part, a fix made in an earlier round;
- again: it raises again, with no new argument, a finding the fixer rejected.
round is the round of the earlier review, as its comment heading says. A finding whose fix didn't hold is not a \
cycle: it is a plain finding. Don't leave a finding out to avoid a cycle: mark it, the train then runs no fix and a \
person decides between the two rounds.
Correctness bugs only: wrong behavior, a missed corner case, a behavior both apps show changed on one platform \
only, the shared interface changed in one bridge only (see "Shared interface" in .claude/rules/nogps-workflow.md), \
a test that doesn't test the change, living docs (docs/nogps/navigation-rules.md, esp32-firmware-spec.md) that no \
longer match the code, a generated file edited by hand, and a merge of ${base} that dropped a change or undid \
something of ${base}.${
    R(pr).suffix
      ? ` This is a firmware PR: the box protocol it follows is \
${APP}/docs/nogps/esp32-firmware-spec.md in the app repo, which is not in this worktree -- read it there (don't \
change it) and report a firmware change that the spec doesn't describe, or that contradicts it.`
      : ''
  }
Leave out style preferences, defensive code for cases that can't happen, and whatever CI already gates: \
formatting, lint, translation keys, the other-platform check.${
    R(pr).suffix ? ' The CI of that repo only builds the firmware for S3 and C3, so nothing else of this PR is gated elsewhere.' : ''
  }
Give every finding a file, a line and a concrete failing scenario. Say nothing about the PR that isn't a finding.
Then post exactly one comment on the PR: gh pr comment ${pr.number} -R ${repo} --body-file - with a first line \
"**Merge-train review, round ${round} (${confirm ? 'Fable, confirming a clean first pass' : 'Opus'}).**" and then \
the findings as a list, \`file:line\` — summary, and the scenario under it; or "No findings." when there are none. \
Under a marked finding, name the earlier round it undoes or repeats, with the link of that round's comment and what \
the fix there did or why the fixer rejected it. Report the comment's URL.
Change nothing else: no edits, no commits, no other GitHub writes.`
}

function fixPrompt(pr, round, findings, name) {
  const wt = WT(name)
  const repo = repoName(pr)
  return `${ENV}

Fix what the review of PR #${pr.number} "${pr.title}" of ${repo} found, in ${wt} (branch train/${pr.number}, the \
PR's branch is ${pr.branch}). Findings of round ${round}: ${JSON.stringify(findings)}
1. Check every finding against the code first. Fix the ones that hold. Don't fix one that is wrong, or that is a \
problem older than this PR: say so in your reply instead, with what you read. For a real problem outside this PR, \
open an issue as "Work you don't do now goes to an issue" in .claude/rules/nogps-workflow.md says (look for an open \
one first, label it, assign it, name the PR), and report its link.
2. Keep the PR's scope: fix the finding, no refactors and no new features. A behavior change gets a unit test.
3. Commit each fix with git commit -s and the "Commit messages" format of ${
    R(pr).suffix ? `${FIRMWARE}/CLAUDE.md` : 'CLAUDE.md'
  }.${
    R(pr).suffix
      ? ''
      : ` Run the formatters CI gates for the files you changed: clang-format 23 \
(uvx --from clang-format==23.1.3 clang-format -i <files>), swiftformat <files>, tools/unix/ktlint_format.sh.`
  }
4. ${
    R(pr).suffix
      ? `A fix that changes the box protocol -- a line, a field, a command, a flag, a cap, an error -- also \
changes ${APP}/docs/nogps/esp32-firmware-spec.md and the box simulator in the app repo. You can't commit those \
from here: report what the spec needs in your reply and open an issue for it.`
      : `A fix that changes a rule or a constant of the core goes into docs/nogps/navigation-rules.md too, in a \
separate [docs] commit; one that changes the box protocol into docs/nogps/esp32-firmware-spec.md and the box \
simulator. A fix to a behavior both apps show is made on both platforms.`
  }
5. Tests: ${
    R(pr).suffix
      ? `build the firmware, as the CI of this repo does for S3 and C3: ${FW_BUILD(name)}
   A build that can't run at all (no ~/esp/esp-idf/export.sh, no keys/) is not a failure: say so in the reply and \
go on. A build that runs and fails is: up to 3 attempts, then report "failed" with the output and push nothing.`
      : `when the fix touches the core, cd ${wt} && ${QUIET} cmake --preset debug -B ${BUILD(name)} -DSKIP_QT_GUI=ON \
(the cd comes first: --preset takes the source tree from the working directory, and configuring ${APP} into this \
build dir would build the other session's work; the dir is this slot's own and is reused by the PRs that come \
through it, so this is mostly a no-op after the first) and then cd ${wt} && ${QUIET} just test "NoGps_.*" \
${BUILD_REL(name)}. Android Java: cd ${wt}/android && ../${QUIET} ./gradlew \
:app:compileGoogleDebugJavaWithJavac -Parm64. iOS code is checked by CI. Up to 3 attempts when a test fails, then \
report "failed" with the output and push nothing.`
  }
6. Push: ${PUSH(pr, wt)} (no rewriting here, the fixes are new commits). Report the new head.
7. Then reply once on the PR: gh pr comment ${pr.number} -R ${repo} --body-file - with a first line \
"**Merge-train fixes, round ${round} (Sonnet).**", what was fixed with the short shas of the commits, what was \
rejected and why, any issue you opened, and the result of the tests you ran.
If every finding is wrong, report "nothing" with your reasons in the reply, push nothing, and post the reply all \
the same: the train then merges the PR.`
}

function gatePrompt(pr) {
  const { base, suffix } = R(pr)
  const repo = repoName(pr)
  const wt = WT(GATE + suffix)
  const staleStep = pr.prepMaster
    ? `Its prep merged ${base} ${pr.prepMaster} into it and reviewed the result.
   ${FETCH(pr, wt)}
   git -C ${wt} diff --name-only ${pr.prepMaster} origin/${base}   -- what ${base} gained since
   gh pr view ${pr.number} -R ${repo} --json files --jq '.files[].path'   -- the PR's own files
   A file in both lists: the review didn't see it. Report "stale" with those files in staleFiles and stop -- the \
train sends the PR back for one more update and review round. Nothing in both lists: go on, whatever else ${base} \
gained.`
    : `Its prep didn't report the ${base} it merged, so this can't be checked: ${FETCH(pr, wt)} and go \
on. The local merge of step 4 and the tests of step 5 are then the only check of the two together.`
  return `${ENV}

Merge PR #${pr.number} "${pr.title}" of ${repo}. It has ${base} merged in, it is pushed, and its review came back \
clean. You are the merge gate: the PRs go through you one at a time, and this is the only step that moves ${base}.
Work in the gate worktree ${wt}. IMPORTANT: never push ${base}, never push the PR's branch, and never rebase or \
force-push anything. The only write to the repo is the gh pr merge of step 7.
0. If ${GONE(suffix ? FIRMWARE : APP, wt)}, somebody removed it during the run: remake it and report remade true. ${REMAKE_GATE(pr, wt)} \
${suffix ? `The keys/ link and the sdkconfig copy are part of it: a bare firmware worktree builds for the esp32 target \
with secure boot v1 and dies on "Incorrect ECDSA private key", which would read as a failure of the PR. ` : ''}Another \
step may hold the worktree lock: run it again after a few seconds. A worktree that exists is used as it is.
1. Did ${base} move under this PR? ${staleStep}
2. Authors, from "Flow of a change" in .claude/rules/nogps-workflow.md: \
gh api --paginate repos/${repo}/pulls/${pr.number}/commits --jq '.[].author.login // "unknown"' | sort -u \
must print only koloboid and Ramzess-II. IMPORTANT: any other login, or "unknown", stops the merge. Report \
"blocked" with the logins; a person merges it on GitHub.
3. gh pr view ${pr.number} -R ${repo} --json state,mergeStateStatus. \
mergeStateStatus DIRTY: report "conflict". Already MERGED or CLOSED: report "blocked" with that.
4. Merge the PR into current ${base} locally, to have the two together: \
git -C ${wt} checkout --force -B train/gate refs/remotes/origin/${base} && git -C ${wt} submodule update --init \
--recursive && git -C ${wt} merge --no-edit ${HEAD_REF(pr)}
   A conflict: git -C ${wt} merge --abort, report "conflict" with the files, and stop; the PR stays open. \
train/gate is local and thrown away after the run: don't push it.
5. Build and test the two together -- this is the only run that sees them together, as the PR's own checks ran \
before the other PRs were merged and theirs ran before this one. Look at what that merge's diff touches: \
git -C ${wt} diff --name-only origin/${base}...HEAD
${
  suffix
    ? `   - The firmware, whatever the diff touches: ${FW_BUILD(GATE + suffix)}
     The CI of this repo builds S3 and C3 from its own config, not from the main checkout's sdkconfig, so this build is not optional. The worktree needs \
${FIRMWARE}/keys linked and ${FIRMWARE}/sdkconfig copied in, which its setup did; a build that complains about an \
"Incorrect ECDSA private key" or a target mismatch is missing one of them, so put it there, run idf.py fullclean \
and build again before calling anything a failure. A build that cannot run at all -- no ~/esp/esp-idf/export.sh, \
no keys/ to link -- is not a failure of the PR but it is not a build either: the CI builds do not stand in \
for it, so don't merge it. Report "blocked" with "not built: <why>" in reason and combinedTest, and stop; the PR stays open \
and a machine that can build it (or a person) lands it.`
    : `   - libs/: cd ${wt} && ${QUIET} cmake --preset debug -B ${BUILD(GATE)} -DSKIP_QT_GUI=ON && \
${QUIET} just test "NoGps_.*" ${BUILD_REL(GATE)}
     The cd comes first: cmake --preset takes the source tree from the working directory, so running it from \
anywhere else configures that checkout -- ${APP}, the other session's work in progress -- into the gate's build dir.
   - android/: cd ${wt}/android && ../${QUIET} ./gradlew :app:compileGoogleDebugJavaWithJavac -Parm64
   - iOS code is left to the PR's own CI; say so in combinedTest when the merge touches iphone/ or xcode/.`
}
   A failure: report "test" with what failed in reason, the output in combinedTest, and post it on the PR -- \
gh pr comment ${pr.number} -R ${repo} --body-file - starting with "**Merge-train gate.** The build with current \
${base} merged in fails:" -- then stop; the PR stays open. All green, or nothing to build: say which in \
combinedTest and go on.
6. CI: gh pr checks ${pr.number} -R ${repo} --watch --interval 60 --fail-fast, with a timeout of 9 minutes \
on the command; repeat it while checks are queued or running, up to 4 times (the iOS check of an app PR takes about 8 minutes). \
The checks of this PR have been running since its prep pushed, so they are often green already. A failing check: \
report "ci" with the names of the failing checks and the run's URL; the PR stays open. Skipped, neutral and the \
Claude review check are not failures. If three minutes after the push no check ran at all for the \
new head, the hooks missed it: gh pr close ${pr.number} -R ${repo} && gh pr reopen ${pr.number} -R ${repo}, then \
watch again.
7. Merge: gh pr merge ${pr.number} -R ${repo} --merge --delete-branch. Both repos merge with a merge commit, as \
their history shows; don't squash and don't rebase-merge. A warning that the local branch can't be deleted is \
fine, the train's local branches are its own.
8. Check it: gh pr view ${pr.number} -R ${repo} --json state,mergeCommit. Report the merge commit's sha.
Don't comment on the PR beyond the failing tests of step 5: the review and fix comments are the trail.`
}

function cleanPrompt(left) {
  // The branches this run made: train/<number> for each PR of its queue and train/gate, in the PR's own repo.
  const TRAIN_BRANCHES = SUFFIXES.map((s) => {
    const repo = s ? FIRMWARE : APP
    const prs = QUEUE.filter((pr) => R(pr).suffix === s).map((pr) => 'train/' + pr.number)
    return `   - ${repo}: ${[...prs, 'train/gate'].join(', ')}`
  }).join('\n')
  return `${ENV}

The train is done. Take its worktrees away: ${NAMES.join(', ')} under ${WS}/worktrees/ -- the ones that exist, as \
a prep slot is made only when a PR needed it. A name ending in -fw is a worktree of ${FIRMWARE}, the others of \
${APP}; the default branch is main there and master here.
1. In each: git -C <path> status --short and git -C <path> log --oneline origin/<its default branch>..HEAD. A \
commit nobody pushed belongs to a PR the train left open (${left || 'none'}): push it to its PR's branch first \
(git -C <path> push <that PR's remote> HEAD:refs/heads/<branch>: origin for a PR opened from a branch of the repo, \
the remote named after the fork's owner for one opened from a fork) and say so in the report. The exception is the branch \
train/gate: its commits are the gate's local merges of a PR into its default branch, nobody's work, and they go \
away with the branch.
2. In each: git -C <path> checkout --force feature/<the worktree's name> && git -C <path> reset --hard && \
git -C <path> clean -fdx (the build dir goes with the worktree anyway), then remove it:
   - a worktree whose name ends in -fw: git -C ${FIRMWARE} worktree remove --force <path>
   - the others: ${APP}/tools/unix/nogps_worktree.sh remove <path>
   The keys/ symlink of a firmware worktree points into ${FIRMWARE}: clean -fdx removes the link, never its target.
3. Delete the train's local branches, after the worktrees are gone, by the exact names below and no others: \
git -C <repo> branch -D <names> for those that exist. Never glob refs/heads/train/*: a train running in the same \
repo at the same time has branches of that shape too.
${TRAIN_BRANCHES}
   ${APP}/tools/unix/nogps_worktree.sh remove deletes the feature/<name> branch of an app worktree itself; \
git worktree remove doesn't, so delete those of the firmware worktrees by name\
${SUFFIXES.includes('-fw') ? ` (${NAMES.filter((n) => n.endsWith('-fw')).map((n) => 'feature/' + n).join(', ')})` : ''}, \
and nothing else: another session's branch may also start with feature/merge-.
4. A worktree that refuses to go: leave it, and report its path and what is in it. It may hold work.
The closed list: this step touches only the paths of ${NAMES.join(', ')} that exist and the branches named in step \
3. It must not list worktrees to tidy, and must not inspect, reset, clean, push from or remove any other worktree \
or branch, in either repo, even one that looks like a train's leftover: it belongs to another run. A repo whose \
suffix is not in this run's queue is not touched at all.
Report in one or two lines what you did. No GitHub writes beyond a push named in step 1.`
}

const results = []
function record(pr, outcome, reason, extra) {
  results.push({
    pr: pr.number,
    repo: repoName(pr),
    title: pr.title,
    url: pr.url,
    set: pr.set,
    rounds: pr.round,
    reviews: pr.reviews,
    staleRounds: pr.staleRounds || 0,
    outcome,
    reason: (pr.gateRemade ? '(gate worktree was gone and remade) ' : '') + (reason || ''),
    ...(extra || {}),
  })
  log(`${tag(pr)}: ${outcome}${reason ? ' (' + reason + ')' : ''}`)
}

const limit = (pr) => `review limit: ${pr.reviews} train reviews`

// Update, then the review/fix rounds, in the worktree of `slot` that belongs to the PR's repo. True when the PR is
// clean and can go to the gate; false when it was recorded and is done with.
async function prep(pr, slot) {
  const tg = tag(pr)
  const name = wtName(slot, pr)
  // Checked before the update too: a PR at the cap gets no push.
  if (pr.reviews >= MAX_REVIEWS) {
    record(pr, 'open', limit(pr))
    return false
  }
  log(`${tg}: prep in ${name}, from round ${pr.round + 1} of ${ROUNDS}`)
  const up = await agent(updatePrompt(pr, name), { label: `update:${tg}`, phase: 'Update', schema: UPDATE_SCHEMA })
  if (!up) {
    record(pr, 'open', 'the update agent stopped')
    return false
  }
  if (up.remade) pr.gateRemade = true
  if (up.status !== 'ok') {
    record(pr, up.status === 'conflict' ? 'conflict' : 'open', up.reason || up.status)
    return false
  }
  pr.head = up.head || pr.head
  pr.prepMaster = up.prepMaster || pr.prepMaster

  // Every round of this run, kept across a send-back by the gate: a cycle can go back further than the round before.
  pr.history = pr.history || []
  let rejected = 0
  while (pr.round < ROUNDS) {
    if (pr.reviews >= MAX_REVIEWS) {
      record(pr, 'open', pr.history.length ? `${limit(pr)}, the round ${pr.round} fixes pushed unreviewed` : limit(pr))
      return false
    }
    const round = ++pr.round
    pr.reviews++
    const rev = await agent(reviewPrompt(pr, round, pr.history, name, false), {
      label: `review:${tg}/${round}`,
      phase: 'Review',
      model: 'opus',
      schema: REVIEW_SCHEMA,
    })
    if (!rev) {
      record(pr, 'open', 'the review agent stopped')
      return false
    }
    let found = rev.findings
    // Opus reviews and Sonnet fixes. Fable, the most capable model and four times the price of Sonnet, reads a PR
    // that came back clean on the first pass: nothing found in one pass is weak evidence the diff was read at all,
    // and the gate merges a clean review with nobody else looking. It is not a round of its own -- a round is a
    // review and a fix -- so it costs the PR none of its rounds, and it happens once: a later clean round already
    // re-read the fixes of the round before it, and a prep the gate sent back starts past round 1. It is a review
    // all the same and counts towards MAX_REVIEWS; with none left, the one clean pass doesn't reach the gate.
    if (!found.length && round === 1) {
      if (pr.reviews >= MAX_REVIEWS) {
        record(pr, 'open', `${limit(pr)}, none left to confirm a clean first pass`)
        return false
      }
      log(`${tg}: round 1 found nothing, Fable reads it before the gate takes it`)
      pr.reviews++
      const conf = await agent(reviewPrompt(pr, round, pr.history, name, true), {
        label: `confirm:${tg}/${round}`,
        phase: 'Confirm',
        model: 'fable',
        schema: REVIEW_SCHEMA,
      })
      if (!conf) {
        record(pr, 'open', 'the confirming review agent stopped')
        return false
      }
      found = conf.findings
    }
    if (!found.length) return true
    const findings = found.length
    // A fix would only flip the code back or reject the finding again: the two rounds need a person.
    const cycles = found.filter((f) => f.cycle)
    if (cycles.length) {
      const what = cycles.map((f) => `\`${f.file}:${f.line ?? '?'}\` ${f.cycle.kind} of round ${f.cycle.round}`)
      record(pr, 'open', `review/fix cycle: ${what.join(', ')}`)
      return false
    }
    const fix = await agent(fixPrompt(pr, round, found, name), {
      label: `fix:${tg}/${round}`,
      phase: 'Fix',
      model: 'sonnet',
      schema: FIX_SCHEMA,
    })
    if (!fix) {
      record(pr, 'open', `${findings} findings, the fix agent stopped`)
      return false
    }
    if (fix.status === 'failed') {
      record(pr, 'open', `${findings} findings, fixes not pushed: ${fix.reason || 'tests failed'}`)
      return false
    }
    // Every finding judged wrong: another review round would only find them again.
    if (fix.status === 'nothing') {
      log(`${tg}: round ${round}, all ${findings} findings rejected by the fixer`)
      return true
    }
    pr.head = fix.head || pr.head
    rejected = fix.rejected
    pr.history.push({ round, findings: found, fixer: { fixed: fix.fixed, rejected: fix.rejected, reply: fix.reply } })
  }
  record(pr, 'open', `still ${rejected} open findings after ${ROUNDS} rounds`)
  return false
}

// The merge gate, one PR at a time, in the gate worktree of the PR's repo. True when the repo's default branch
// moved under the PR and it has to be prepped once more.
async function gate(pr) {
  const base = R(pr).base
  const m = await agent(gatePrompt(pr), { label: `merge:${tag(pr)}`, phase: 'Merge', schema: MERGE_SCHEMA })
  if (!m) {
    record(pr, 'open', 'the merge agent stopped')
    return false
  }
  if (m.remade) pr.gateRemade = true
  if (m.remade) log(`${tag(pr)}: the gate worktree was gone and was remade`)
  if (m.status === 'stale') {
    const files = (m.staleFiles || []).join(', ') || m.reason || 'a file it touches'
    pr.staleRounds = (pr.staleRounds || 0) + 1
    if (pr.round >= ROUNDS) {
      record(pr, 'open', `${base} gained ${files} and the ${ROUNDS} rounds are used up`)
      return false
    }
    log(`${tag(pr)}: ${base} gained ${files}, back for one more round`)
    return true
  }
  if (m.status === 'merged') {
    record(pr, 'merged', `${pr.round} round(s)`, { mergeCommit: m.mergeCommit, combinedTest: m.combinedTest })
    return false
  }
  if (m.status === 'test') {
    record(pr, 'open', `the tests fail with ${base} merged in: ${m.reason || ''}`, { combinedTest: m.combinedTest })
    return false
  }
  const outcome = m.status === 'blocked' ? 'blocked' : m.status === 'conflict' ? 'conflict' : 'open'
  record(pr, outcome, m.reason || m.status)
  return false
}

// Scheduler of the parallel prep, the shape of the roller's. JS runs the workers on one thread, so plain counters
// are safe between awaits. `mergeBusy` is the gate's exclusive lock, the way the roller guards its iOS slot: a PR
// whose prep is clean goes to `ready` and its worker goes back to prepping, so no worker idles behind the gate.
const ready = []
let prepping = 0
let prepDone = 0
let mergeBusy = false
let diskStop = false
let held = 0 // workers busy with a PR
let waiters = []
const changed = () => new Promise((resolve) => waiters.push(resolve))
function notify() {
  const w = waiters
  waiters = []
  w.forEach((resolve) => resolve())
}

function take() {
  if (!mergeBusy && ready.length) return { pr: ready.shift(), gate: true }
  if (diskStop || !pending.length) return null
  return { pr: pending.shift() }
}

async function freeDisk(pr) {
  const d = await agent(`Run df -g ${WS} and report the free GB (the "Avail" column). Nothing else.`, {
    label: `disk:${tag(pr)}`,
    phase: 'Update',
    effort: 'low',
    schema: DISK_SCHEMA,
  })
  return d ? d.freeGb : 0
}

async function run(job, name) {
  const pr = job.pr
  if (job.gate) {
    mergeBusy = true
    try {
      if (await gate(pr)) pending.unshift(pr)
    } finally {
      mergeBusy = false
    }
    return
  }
  let free = await freeDisk(pr)
  while (free < MIN_FREE_GB && prepping > 0) {
    const was = prepDone
    while (prepDone === was) await changed()
    free = await freeDisk(pr)
  }
  if (free < MIN_FREE_GB) {
    diskStop = true
    record(pr, 'open', `${free} GB free, needs ${MIN_FREE_GB}: not prepped`)
    return
  }
  prepping++
  try {
    if (await prep(pr, name)) ready.push(pr)
  } finally {
    prepping--
    prepDone++
  }
}

async function worker(name) {
  for (;;) {
    const job = take()
    if (!job) {
      // Only a running PR can free the gate or put one in `ready`; with none, nothing more can start.
      if (held === 0) return
      await changed()
      continue
    }
    held++
    try {
      await run(job, name)
    } catch (e) {
      record(job.pr, 'open', `${e}; check the worktree ${WT(wtName(name, job.pr))}`)
    } finally {
      held--
      notify()
    }
  }
}

log(`${pending.length} PRs prepped in parallel in up to ${SLOTS} slots, ${serial.length} one at a time, \
up to ${ROUNDS} rounds each and ${MAX_REVIEWS} train reviews in all`)
if (movedIos.length)
  log(`${movedIos.map((pr) => '#' + pr.number).join(', ')} moved to the serial set: nothing builds iOS, so two \
PRs that touch iphone/ or xcode/ are never prepped at once`)
phase('Setup')
const setup = await agent(setupPrompt(), { label: 'setup', phase: 'Setup', effort: 'low', schema: SETUP_SCHEMA })
if (!setup || !setup.ok)
  throw new Error(`the train worktrees are not ready: ${setup ? setup.reason : 'the setup agent stopped'}`)
if (setup.freeGb < MIN_FREE_GB) log(`only ${setup.freeGb} GB free, builds of the fix rounds may fail`)

if (pending.length) await parallel(Array.from({ length: SLOTS }, (_, i) => () => worker(slotName(i + 1))))
// Left in `pending` only when the disk filled up: `take()` hands out nothing more then.
while (pending.length) {
  const pr = pending.shift()
  const why = pr.staleRounds
    ? 'master moved under it and the disk was too full to prep it again'
    : 'not prepped: the disk filled up'
  record(pr, 'open', why)
}

// The serial set: the PRs whose files another queued PR touches and the dependency chains, one at a time in the
// gate worktree, so each one is reviewed on the master the one before it made.
const left = [...serial]
while (left.length) {
  const pr = left.shift()
  if (!(await prep(pr, GATE))) continue
  if (await gate(pr)) left.unshift(pr)
}

phase('Clean')
const open = results.filter((r) => r.outcome !== 'merged').map((r) => `#${r.pr}`).join(', ')
const clean = await agent(cleanPrompt(open), { label: 'clean', phase: 'Clean', effort: 'low' })
const merged = results.filter((r) => r.outcome === 'merged').length
log(`${merged} of ${results.length} PRs merged`)
return { results, merged, slots: SLOTS, worktree: clean }
