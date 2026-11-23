export const meta = {
  name: 'nogps-merge',
  description: 'NonGPS merge train: prep the independent PRs in parallel, then merge them one at a time',
  whenToUse: 'Started by the /nogps-merge skill, which builds the two sets: args {ws, parallel, serial, rounds, slots}',
  phases: [
    { title: 'Setup', detail: 'the merge gate worktree, and one per prep slot when a PR needs it' },
    { title: 'Update', detail: 'merge current master into the PR branch, push fast-forward' },
    { title: 'Review', detail: 'correctness only, the findings posted on the PR', model: 'fable' },
    { title: 'Fix', detail: 'check each finding, fix the ones that hold, push', model: 'opus' },
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
const MIN_FREE_GB = 15

// The train lands the PRs of both repos. Each one has its own checkout, its own default branch -- the firmware repo
// has no master, its default branch is main -- and its own way of being built and checked: the firmware repo has no
// CI at all today, so the gate's local build is the only check a firmware PR gets, and it is not optional.
// `keys/` and `sdkconfig` are gitignored in the firmware repo, so a fresh worktree has neither and both come from
// the main checkout: the signing key, because sdkconfig.defaults signs the image with
// keys/nogps_signing_key.pem, and sdkconfig, because sdkconfig.defaults alone does not reproduce it -- it leaves
// the target at esp32 and the scheme at secure boot v1 (ECDSA), while the box is an esp32s3 signed with the v2 RSA
// scheme, and the build then dies on "Incorrect ECDSA private key". sdkconfig is copied, not linked: idf.py
// rewrites it, and it has to be in place before the first build, which caches the target in CMakeCache.txt.
const REPOS = {
  [APP_REPO]: { dir: APP, base: 'master', ci: true, suffix: '', what: 'the app' },
  [FW_REPO]: { dir: FIRMWARE, base: 'main', ci: false, suffix: '-fw', what: 'the box firmware' },
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
const RM_WT = (name) =>
  name.endsWith('-fw')
    ? `git -C ${FIRMWARE} worktree remove --force ${WT(name)}`
    : `${APP}/tools/unix/nogps_worktree.sh remove ${WT(name)}`
// The firmware build, the only check of a firmware PR. A missing toolchain or signing key is not a test failure:
// nothing was built, and the step says so.
const FW_BUILD = (name) => `cd ${WT(name)} && . ~/esp/esp-idf/export.sh >/dev/null && idf.py build`

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
pending.forEach((pr) => Object.assign(pr, { set: 'parallel', round: 0 }))
serial.forEach((pr) => Object.assign(pr, { set: 'serial', round: 0 }))
// R() throws on a repo the train doesn't know: the queue is checked before any agent runs, not per step.
const SUFFIXES = [...new Set([...pending, ...serial].map((pr) => R(pr).suffix))]
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
const CHECKOUT = (pr, wt) => `git -C ${wt} fetch -q origin && git -C ${wt} checkout --force \
--ignore-other-worktrees -B train/${pr.number} refs/remotes/origin/${pr.branch} && git -C ${wt} submodule update \
--init --recursive`
const PUSH = (pr, wt) => `git -C ${wt} push origin HEAD:refs/heads/${pr.branch}`
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
1. If ${wt} doesn't exist: ${ADD_WT(pr, name)}
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

function reviewPrompt(pr, round, before, name) {
  const wt = WT(name)
  const { base } = R(pr)
  const repo = repoName(pr)
  const again = before
    ? `\nThis is round ${round}. Your findings of the round before and what the fixer did with them: \
${JSON.stringify(before)}. Check each of them in the code again: a fix that doesn't hold is a finding again, and so \
is a new bug the fix brought. Don't repeat a finding you now agree was wrong.`
    : ''
  return `${ENV}

Review PR #${pr.number} "${pr.title}" of ${repo} in ${wt}, with current ${base} just merged in: git -C ${wt} diff \
 origin/${base}...HEAD. \
You didn't write it. Read the PR and its issue (gh pr view ${pr.number} -R ${repo} --comments), and the code around \
the diff, not only the diff.${again}
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
    R(pr).suffix ? ' That repo has no CI at all, so nothing of this PR is gated elsewhere.' : ''
  }
Give every finding a file, a line and a concrete failing scenario. Say nothing about the PR that isn't a finding.
Then post exactly one comment on the PR: gh pr comment ${pr.number} -R ${repo} --body-file - with a first line \
"**Merge-train review, round ${round} (Fable).**" and then the findings as a list, \`file:line\` — summary, and the \
scenario under it; or "No findings." when there are none. Report the comment's URL.
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
      ? `build the firmware, the only check this repo has -- it runs no CI: ${FW_BUILD(name)}
   A build that can't run at all (no ~/esp/esp-idf/export.sh, no keys/) is not a failure: say so in the reply and \
go on. A build that runs and fails is: up to 3 attempts, then report "failed" with the output and push nothing.`
      : `when the fix touches the core, cd ${wt} && cmake --preset debug -B ${BUILD(name)} -DSKIP_QT_GUI=ON \
(the cd comes first: --preset takes the source tree from the working directory, and configuring ${APP} into this \
build dir would build the other session's work; the dir is this slot's own and is reused by the PRs that come \
through it, so this is mostly a no-op after the first) and then cd ${wt} && just test "NoGps_.*" \
${BUILD_REL(name)}. Android Java: cd ${wt}/android && ./gradlew \
:app:compileGoogleDebugJavaWithJavac -Parm64. iOS code is checked by CI. Up to 3 attempts when a test fails, then \
report "failed" with the output and push nothing.`
  }
6. Push: ${PUSH(pr, wt)} (no rewriting here, the fixes are new commits). Report the new head.
7. Then reply once on the PR: gh pr comment ${pr.number} -R ${repo} --body-file - with a first line \
"**Merge-train fixes, round ${round} (Opus).**", what was fixed with the short shas of the commits, what was \
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
   git -C ${wt} fetch -q origin
   git -C ${wt} diff --name-only ${pr.prepMaster} origin/${base}   -- what ${base} gained since
   gh pr view ${pr.number} -R ${repo} --json files --jq '.files[].path'   -- the PR's own files
   A file in both lists: the review didn't see it. Report "stale" with those files in staleFiles and stop -- the \
train sends the PR back for one more update and review round. Nothing in both lists: go on, whatever else ${base} \
gained.`
    : `Its prep didn't report the ${base} it merged, so this can't be checked: git -C ${wt} fetch -q origin and go \
on. The local merge of step 4 and the tests of step 5 are then the only check of the two together.`
  return `${ENV}

Merge PR #${pr.number} "${pr.title}" of ${repo}. It has ${base} merged in, it is pushed, and its review came back \
clean. You are the merge gate: the PRs go through you one at a time, and this is the only step that moves ${base}.
Work in the gate worktree ${wt}. IMPORTANT: never push ${base}, never push the PR's branch, and never rebase or \
force-push anything. The only write to the repo is the gh pr merge of step 7.
1. Did ${base} move under this PR? ${staleStep}
2. Authors, from "Flow of a change" in .claude/rules/nogps-workflow.md: \
gh api --paginate repos/${repo}/pulls/${pr.number}/commits --jq '.[].author.login // "unknown"' | sort -u \
must print only koloboid and Ramzess-II. IMPORTANT: any other login, or "unknown", stops the merge. Report \
"blocked" with the logins; a person merges it on GitHub.
3. gh pr view ${pr.number} -R ${repo} --json reviewDecision,reviewRequests,state,mergeStateStatus. A review \
requested from the other person, CHANGES_REQUESTED or REVIEW_REQUIRED: report "blocked" with who has to approve. \
mergeStateStatus DIRTY: report "conflict". Already MERGED or CLOSED: report "blocked" with that.
4. Merge the PR into current ${base} locally, to have the two together: \
git -C ${wt} checkout --force -B train/gate refs/remotes/origin/${base} && git -C ${wt} submodule update --init \
--recursive && git -C ${wt} merge --no-edit refs/remotes/origin/${pr.branch}
   A conflict: git -C ${wt} merge --abort, report "conflict" with the files, and stop; the PR stays open. \
train/gate is local and thrown away after the run: don't push it.
5. Build and test the two together -- this is the only run that sees them together, as the PR's own checks ran \
before the other PRs were merged and theirs ran before this one. Look at what that merge's diff touches: \
git -C ${wt} diff --name-only origin/${base}...HEAD
${
  suffix
    ? `   - The firmware, whatever the diff touches: ${FW_BUILD(GATE + suffix)}
     This repo runs no CI, so this build is the only check the PR gets: it is not optional. The worktree needs \
${FIRMWARE}/keys linked and ${FIRMWARE}/sdkconfig copied in, which its setup did; a build that complains about an \
"Incorrect ECDSA private key" or a target mismatch is missing one of them, so put it there, run idf.py fullclean \
and build again before calling anything a failure. A build that cannot run at all -- no ~/esp/esp-idf/export.sh, \
no keys/ to link -- is not a failure of the PR: report "merged" after step 7 with "not built: <why>" in \
combinedTest, so the report says the PR landed unbuilt.`
    : `   - libs/: cd ${wt} && cmake --preset debug -B ${BUILD(GATE)} -DSKIP_QT_GUI=ON && \
just test "NoGps_.*" ${BUILD_REL(GATE)}
     The cd comes first: cmake --preset takes the source tree from the working directory, so running it from \
anywhere else configures that checkout -- ${APP}, the other session's work in progress -- into the gate's build dir.
   - android/: cd ${wt}/android && ./gradlew :app:compileGoogleDebugJavaWithJavac -Parm64
   - iOS code is left to the PR's own CI; say so in combinedTest when the merge touches iphone/ or xcode/.`
}
   A failure: report "test" with what failed in reason, the output in combinedTest, and post it on the PR -- \
gh pr comment ${pr.number} -R ${repo} --body-file - starting with "**Merge-train gate.** The build with current \
${base} merged in fails:" -- then stop; the PR stays open. All green, or nothing to build: say which in \
combinedTest and go on.
6. ${
    R(pr).ci
      ? `CI: gh pr checks ${pr.number} -R ${repo} --watch --interval 60 --fail-fast, with a timeout of 9 minutes \
on the command; repeat it while checks are queued or running, up to 4 times (the iOS check takes about 8 minutes). \
The checks of this PR have been running since its prep pushed, so they are often green already. A failing check: \
report "ci" with the names of the failing checks and the run's URL; the PR stays open. Skipped, neutral and the \
Claude review check are not failures. If three minutes after the push no check ran at all for the \
new head, the hooks missed it: gh pr close ${pr.number} -R ${repo} && gh pr reopen ${pr.number} -R ${repo}, then \
watch again.`
      : `No CI to wait for: ${repo} has no checks (no .github/workflows), so step 5's build is the whole \
verification. Go straight on to the merge.`
  }
7. Merge: gh pr merge ${pr.number} -R ${repo} --merge --delete-branch. Both repos merge with a merge commit, as \
their history shows; don't squash and don't rebase-merge. A warning that the local branch can't be deleted is \
fine, the train's local branches are its own.
8. Check it: gh pr view ${pr.number} -R ${repo} --json state,mergeCommit. Report the merge commit's sha.
Don't comment on the PR beyond the failing tests of step 5: the review and fix comments are the trail.`
}

function cleanPrompt(left) {
  return `${ENV}

The train is done. Take its worktrees away: ${NAMES.join(', ')} under ${WS}/worktrees/ -- the ones that exist, as \
a prep slot is made only when a PR needed it. A name ending in -fw is a worktree of ${FIRMWARE}, the others of \
${APP}; the default branch is main there and master here.
1. In each: git -C <path> status --short and git -C <path> log --oneline origin/<its default branch>..HEAD. A \
commit nobody pushed belongs to a PR the train left open (${left || 'none'}): push it to its PR's branch first \
(git -C <path> push origin HEAD:refs/heads/<branch>) and say so in the report. The exception is the branch \
train/gate: its commits are the gate's local merges of a PR into its default branch, nobody's work, and they go \
away with the branch.
2. In each: git -C <path> checkout --force feature/<the worktree's name> && git -C <path> reset --hard && \
git -C <path> clean -fdx (the build dir goes with the worktree anyway), then remove it:
   - a worktree whose name ends in -fw: git -C ${FIRMWARE} worktree remove --force <path>
   - the others: ${APP}/tools/unix/nogps_worktree.sh remove <path>
   The keys/ symlink of a firmware worktree points into ${FIRMWARE}: clean -fdx removes the link, never its target.
3. Delete the train's local branches, after the worktrees are gone, in each repo that had one: \
git -C <repo> branch -D $(git -C <repo> for-each-ref --format='%(refname:short)' 'refs/heads/train/*') if there \
are any. ${APP}/tools/unix/nogps_worktree.sh remove deletes the feature/<name> branch of an app worktree itself; \
git worktree remove doesn't, so delete those of the firmware worktrees by name\
${SUFFIXES.includes('-fw') ? ` (${NAMES.filter((n) => n.endsWith('-fw')).map((n) => 'feature/' + n).join(', ')})` : ''}, \
and nothing else: another session's branch may also start with feature/merge-.
4. A worktree that refuses to go: leave it, and report its path and what is in it. It may hold work.
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
    staleRounds: pr.staleRounds || 0,
    outcome,
    reason: reason || '',
    ...(extra || {}),
  })
  log(`${tag(pr)}: ${outcome}${reason ? ' (' + reason + ')' : ''}`)
}

// Update, then the review/fix rounds, in the worktree of `slot` that belongs to the PR's repo. True when the PR is
// clean and can go to the gate; false when it was recorded and is done with.
async function prep(pr, slot) {
  const tg = tag(pr)
  const name = wtName(slot, pr)
  log(`${tg}: prep in ${name}, from round ${pr.round + 1} of ${ROUNDS}`)
  const up = await agent(updatePrompt(pr, name), { label: `update:${tg}`, phase: 'Update', schema: UPDATE_SCHEMA })
  if (!up) {
    record(pr, 'open', 'the update agent stopped')
    return false
  }
  if (up.status !== 'ok') {
    record(pr, up.status === 'conflict' ? 'conflict' : 'open', up.reason || up.status)
    return false
  }
  pr.head = up.head || pr.head
  pr.prepMaster = up.prepMaster || pr.prepMaster

  let before = null
  let rejected = 0
  while (pr.round < ROUNDS) {
    const round = ++pr.round
    const rev = await agent(reviewPrompt(pr, round, before, name), {
      label: `review:${tg}/${round}`,
      phase: 'Review',
      model: 'fable',
      schema: REVIEW_SCHEMA,
    })
    if (!rev) {
      record(pr, 'open', 'the review agent stopped')
      return false
    }
    const findings = rev.findings.length
    if (!findings) return true
    const fix = await agent(fixPrompt(pr, round, rev.findings, name), {
      label: `fix:${tg}/${round}`,
      phase: 'Fix',
      model: 'opus',
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
    before = { findings: rev.findings, fixer: { fixed: fix.fixed, rejected: fix.rejected, reply: fix.reply } }
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
up to ${ROUNDS} rounds each`)
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
