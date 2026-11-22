export const meta = {
  name: 'nogps-merge',
  description: 'NonGPS merge train: merge master into each open PR, review it with Fable, fix with Opus, merge when clean',
  whenToUse: 'Started by the /nogps-merge skill, which builds the order: args {ws, queue, rounds}',
  phases: [
    { title: 'Setup', detail: 'the train worktree, reused by every PR' },
    { title: 'Update', detail: 'merge current master into the PR branch, push fast-forward' },
    { title: 'Review', detail: 'correctness only, the findings posted on the PR', model: 'fable' },
    { title: 'Fix', detail: 'check each finding, fix the ones that hold, push', model: 'opus' },
    { title: 'Merge', detail: 'authors, CI green, merge commit' },
    { title: 'Clean', detail: 'remove the train worktree' },
  ],
}

// One PR at a time: master moves under the queue with every merge, so the next PR gets the new master merged into
// it, is reviewed again, and is merged only when the review is clean and CI is green. A PR that can't be merged
// stays open and the train goes on.
// The train never rewrites a branch: it merges master into the PR branch, so every push is a fast-forward. No
// rebase and no force push, not even with a lease.
const A = args || {}
const WS = A.ws
if (!WS) throw new Error('args.ws is required: the folder that holds app/')
const APP = `${WS}/app`
const REPO = 'Ramzess-II/NoNGPS-Maps'
const NAME = 'merge-train'
const WT = `${WS}/worktrees/${NAME}`
const BUILD = `${WT}/build-${NAME}`
const ROUNDS = A.rounds ?? 3
const MIN_FREE_GB = 15
const queue = [...(A.queue || [])]

const ENV = `NonGPS Maps workspace: ${WS}. Repo ${REPO}, main checkout ${APP}.
Don't change the main checkout ${APP}: another session works in it. Every step of the train works in the one \
worktree ${WT}, which is reused by every PR. The shell's working directory can reset between commands: use \
absolute paths, git -C <path>, or "cd <path> && ..." in each command.
You are one step of the merge train (/nogps-merge). The user started the run and nobody answers questions during \
it: never wait for a confirmation. When you can't finish your step, change nothing more, report it, and leave the \
PR open. Write English only on GitHub.`

// The PR's own branch is never checked out: it may be checked out in the main checkout or another worktree, and
// git refuses that. The train works on train/<n> and pushes it to the PR's branch by its full refname.
const CHECKOUT = (pr) => `git -C ${WT} fetch -q origin && git -C ${WT} checkout --force -B train/${pr.number} \
refs/remotes/origin/${pr.branch} && git -C ${WT} submodule update --init --recursive`
const PUSH = (pr) => `git -C ${WT} push origin HEAD:refs/heads/${pr.branch}`

const SETUP_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean', description: 'the worktree is there and clean' },
    reason: { type: 'string', description: 'why not, one line' },
    freeGb: { type: 'number', description: 'free GB on the disk of the workspace, from df -g' },
  },
  required: ['ok', 'freeGb'],
}

const UPDATE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['ok', 'conflict', 'moved', 'failed'] },
    reason: { type: 'string', description: 'one line for the report table' },
    head: { type: 'string', description: 'the sha of the head after the merge' },
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
    status: { type: 'string', enum: ['merged', 'blocked', 'ci', 'conflict', 'failed'] },
    reason: { type: 'string', description: 'one line for the report table, with the failing checks when ci' },
    mergeCommit: { type: 'string' },
  },
  required: ['status'],
}

function setupPrompt() {
  return `${ENV}

Prepare the train worktree ${WT}.
1. git -C ${APP} fetch -q origin.
2. If ${WT} doesn't exist: ${APP}/tools/unix/nogps_worktree.sh add ${NAME} (it makes the branch feature/${NAME} \
from origin/master, clones the submodules from the main checkout with no network, and prints the path).
3. If it does exist, from an earlier run: git -C ${WT} status --short. Clean: use it as it is. Dirty with changes \
nobody pushed, report ok false and say what is in it; the train then stops and a person looks at it.
4. Run df -g ${WS} and report the free GB (the "Avail" column).
Nothing else: no builds, no GitHub writes.`
}

function updatePrompt(pr) {
  return `${ENV}

Bring current master into PR #${pr.number} "${pr.title}" (branch ${pr.branch}, head ${pr.head}), in ${WT}.
IMPORTANT: never rebase this branch and never force-push it, with or without a lease. The branch is only ever \
moved forward: master is merged into it, so the push is a fast-forward. A push that would need a force is a \
"moved" report, not a force push.
1. ${CHECKOUT(pr)}
   If the PR's head on GitHub is no longer ${pr.head} (gh pr view ${pr.number} -R ${REPO} --json headRefOid), \
somebody pushed to it while the train was running: report "moved" and stop.
2. git -C ${WT} merge --no-edit origin/master. Already has master in it ("Already up to date"): report "ok" with \
updated false and push nothing.
3. A conflict: resolve it only where both sides make the resolution plain (both added a line to the same list, a \
constant moved, a string table). Read the code around it, not only the conflict markers. Anything else, or a \
conflict in a generated file: git -C ${WT} merge --abort, report "conflict" with the files, and stop. The PR \
stays open for a person.
4. After a resolved conflict, check that nothing of the PR was dropped and nothing of master was undone: \
git -C ${WT} diff origin/master...HEAD against the PR's own diff on GitHub (gh pr diff ${pr.number} -R ${REPO}).
5. Push the branch: ${PUSH(pr)}
   Rejected as non-fast-forward: somebody pushed meanwhile, report "moved". Don't force it.
6. Report the new head (git -C ${WT} rev-parse HEAD) and git -C ${WT} diff --shortstat origin/master...HEAD.
Don't build and don't write on GitHub beyond this push.`
}

function reviewPrompt(pr, round, before) {
  const again = before
    ? `\nThis is round ${round}. Your findings of the round before and what the fixer did with them: \
${JSON.stringify(before)}. Check each of them in the code again: a fix that doesn't hold is a finding again, and so \
is a new bug the fix brought. Don't repeat a finding you now agree was wrong.`
    : ''
  return `${ENV}

Review PR #${pr.number} "${pr.title}" in ${WT}, with current master just merged in: git -C ${WT} diff \
 origin/master...HEAD. \
You didn't write it. Read the PR and its issue (gh pr view ${pr.number} -R ${REPO} --comments), and the code around \
the diff, not only the diff.${again}
Correctness bugs only: wrong behavior, a missed corner case, a behavior both apps show changed on one platform \
only, the shared interface changed in one bridge only (see "Shared interface" in .claude/rules/nogps-workflow.md), \
a test that doesn't test the change, living docs (docs/nogps/navigation-rules.md, esp32-firmware-spec.md) that no \
longer match the code, a generated file edited by hand, and a merge of master that dropped a change or undid \
something of master.
Leave out style preferences, defensive code for cases that can't happen, and whatever CI already gates: \
formatting, lint, translation keys, the other-platform check.
Give every finding a file, a line and a concrete failing scenario. Say nothing about the PR that isn't a finding.
Then post exactly one comment on the PR: gh pr comment ${pr.number} -R ${REPO} --body-file - with a first line \
"**Merge-train review, round ${round} (Fable).**" and then the findings as a list, \`file:line\` — summary, and the \
scenario under it; or "No findings." when there are none. Report the comment's URL.
Change nothing else: no edits, no commits, no other GitHub writes.`
}

function fixPrompt(pr, round, findings) {
  return `${ENV}

Fix what the review of PR #${pr.number} "${pr.title}" found, in ${WT} (branch train/${pr.number}, the PR's branch \
is ${pr.branch}). Findings of round ${round}: ${JSON.stringify(findings)}
1. Check every finding against the code first. Fix the ones that hold. Don't fix one that is wrong, or that is a \
problem older than this PR: say so in your reply instead, with what you read. For a real problem outside this PR, \
open an issue as "Work you don't do now goes to an issue" in .claude/rules/nogps-workflow.md says (look for an open \
one first, label it, assign it, name the PR), and report its link.
2. Keep the PR's scope: fix the finding, no refactors and no new features. A behavior change gets a unit test.
3. Commit each fix with git commit -s and the "Commit messages" format of CLAUDE.md. Run the formatters CI gates \
for the files you changed: clang-format 23 (uvx --from clang-format==23.1.3 clang-format -i <files>), swiftformat \
<files>, tools/unix/ktlint_format.sh.
4. A fix that changes a rule or a constant of the core goes into docs/nogps/navigation-rules.md too, in a separate \
[docs] commit; one that changes the box protocol into docs/nogps/esp32-firmware-spec.md and the box simulator. A \
fix to a behavior both apps show is made on both platforms.
5. Tests: when the fix touches the core, cmake --preset debug -B ${BUILD} -DSKIP_QT_GUI=ON (the dir is reused by \
every PR of the run, so this is mostly a no-op after the first) and then cd ${WT} && just test "NoGps_.*" \
build-${NAME}. Android Java: cd ${WT}/android && ./gradlew :app:compileGoogleDebugJavaWithJavac -Parm64. iOS code \
is checked by CI. Up to 3 attempts when a test fails, then report "failed" with the output and push nothing.
6. Push: ${PUSH(pr)} (no rewriting here, the fixes are new commits). Report the new head.
7. Then reply once on the PR: gh pr comment ${pr.number} -R ${REPO} --body-file - with a first line \
"**Merge-train fixes, round ${round} (Opus).**", what was fixed with the short shas of the commits, what was \
rejected and why, any issue you opened, and the result of the tests you ran.
If every finding is wrong, report "nothing" with your reasons in the reply, push nothing, and post the reply all \
the same: the train then merges the PR.`
}

function mergePrompt(pr) {
  return `${ENV}

Merge PR #${pr.number} "${pr.title}" of ${REPO}. It has current master merged in and its review is clean.
1. Authors, from "Flow of a change" in .claude/rules/nogps-workflow.md: \
gh api --paginate repos/${REPO}/pulls/${pr.number}/commits --jq '.[].author.login // "unknown"' | sort -u \
must print only koloboid and Ramzess-II. IMPORTANT: any other login, or "unknown", stops the merge. Report \
"blocked" with the logins; a person merges it on GitHub.
2. gh pr view ${pr.number} -R ${REPO} --json reviewDecision,reviewRequests,state,mergeStateStatus. A review \
requested from the other person, CHANGES_REQUESTED or REVIEW_REQUIRED: report "blocked" with who has to approve. \
mergeStateStatus DIRTY: report "conflict". Already MERGED or CLOSED: report "blocked" with that.
3. CI: gh pr checks ${pr.number} -R ${REPO} --watch --interval 60 --fail-fast, with a timeout of 9 minutes on the \
command; repeat it while checks are queued or running, up to 4 times (the iOS check takes about 8 minutes). A \
failing check: report "ci" with the names of the failing checks and the run's URL; the PR stays open. Skipped, \
neutral and the Claude review check are not failures. If three minutes after the push no check ran at all for the \
new head, the hooks missed it: gh pr close ${pr.number} -R ${REPO} && gh pr reopen ${pr.number} -R ${REPO}, then \
watch again.
4. Merge: gh pr merge ${pr.number} -R ${REPO} --merge --delete-branch. This repo merges with a merge commit, as \
master's history shows; don't squash and don't rebase-merge. A warning that the local branch can't be deleted is \
fine, the train's local branches are its own.
5. Check it: gh pr view ${pr.number} -R ${REPO} --json state,mergeCommit. Report the merge commit's sha.
Don't comment on the PR: the review and fix comments are the trail.`
}

function cleanPrompt(left) {
  return `${ENV}

The train is done. Take the worktree ${WT} away.
1. git -C ${WT} status --short and git -C ${WT} log --oneline origin/master..HEAD. A commit nobody pushed belongs \
to a PR the train left open (${left || 'none'}): push it to its PR's branch first (git -C ${WT} push origin \
HEAD:refs/heads/<branch>) and say so in the report.
2. git -C ${WT} checkout --force feature/${NAME} && git -C ${WT} reset --hard && git -C ${WT} clean -fdx (the \
build dir goes with the worktree anyway), then ${APP}/tools/unix/nogps_worktree.sh remove ${WT}.
3. Delete the train's local branches, after the worktree is gone: git -C ${APP} branch -D $(git -C ${APP} \
for-each-ref --format='%(refname:short)' 'refs/heads/train/*') if there are any.
4. If the worktree refuses to go, leave it: report its path and what is in it. It may hold work.
Report in one or two lines what you did. No GitHub writes beyond a push named in step 1.`
}

const results = []
function record(pr, outcome, reason, extra) {
  results.push({ pr: pr.number, title: pr.title, url: pr.url, outcome, reason: reason || '', ...(extra || {}) })
  log(`#${pr.number}: ${outcome}${reason ? ' (' + reason + ')' : ''}`)
}

log(`${queue.length} PRs in the train, up to ${ROUNDS} review rounds each`)
phase('Setup')
const setup = await agent(setupPrompt(), { label: 'setup', phase: 'Setup', effort: 'low', schema: SETUP_SCHEMA })
if (!setup || !setup.ok) throw new Error(`the train worktree is not ready: ${setup ? setup.reason : 'the setup agent stopped'}`)
if (setup.freeGb < MIN_FREE_GB) log(`only ${setup.freeGb} GB free, builds of the fix rounds may fail`)

for (const pr of queue) {
  const reb = await agent(updatePrompt(pr), { label: `update:#${pr.number}`, phase: 'Update', schema: UPDATE_SCHEMA })
  if (!reb) {
    record(pr, 'open', 'the update agent stopped')
    continue
  }
  if (reb.status !== 'ok') {
    record(pr, reb.status === 'conflict' ? 'conflict' : 'open', reb.reason || reb.status)
    continue
  }
  pr.head = reb.head || pr.head

  let round = 0
  let before = null
  let outcome = null
  let findings = 0
  while (round < ROUNDS) {
    round++
    const rev = await agent(reviewPrompt(pr, round, before), {
      label: `review:#${pr.number}/${round}`,
      phase: 'Review',
      model: 'fable',
      schema: REVIEW_SCHEMA,
    })
    if (!rev) {
      outcome = ['open', 'the review agent stopped']
      break
    }
    findings = rev.findings.length
    if (!findings) break
    const fix = await agent(fixPrompt(pr, round, rev.findings), {
      label: `fix:#${pr.number}/${round}`,
      phase: 'Fix',
      model: 'opus',
      schema: FIX_SCHEMA,
    })
    if (!fix) {
      outcome = ['open', `${findings} findings, the fix agent stopped`]
      break
    }
    if (fix.status === 'failed') {
      outcome = ['open', `${findings} findings, fixes not pushed: ${fix.reason || 'tests failed'}`]
      break
    }
    // Every finding judged wrong: another review round would only find them again.
    if (fix.status === 'nothing') {
      log(`#${pr.number}: round ${round}, all ${findings} findings rejected by the fixer`)
      break
    }
    pr.head = fix.head || pr.head
    before = { findings: rev.findings, fixer: { fixed: fix.fixed, rejected: fix.rejected, reply: fix.reply } }
    if (round === ROUNDS) outcome = ['open', `still ${fix.rejected} open findings after ${ROUNDS} rounds`]
  }
  if (outcome) {
    record(pr, outcome[0], outcome[1], { rounds: round })
    continue
  }
  const m = await agent(mergePrompt(pr), { label: `merge:#${pr.number}`, phase: 'Merge', schema: MERGE_SCHEMA })
  if (!m) record(pr, 'open', 'the merge agent stopped', { rounds: round })
  else if (m.status === 'merged') record(pr, 'merged', `${round} round(s)`, { rounds: round, mergeCommit: m.mergeCommit })
  else record(pr, m.status === 'blocked' ? 'blocked' : 'open', m.reason || m.status, { rounds: round })
}

phase('Clean')
const left = results.filter((r) => r.outcome !== 'merged').map((r) => `#${r.pr}`).join(', ')
const clean = await agent(cleanPrompt(left), { label: 'clean', phase: 'Clean', effort: 'low' })
const merged = results.filter((r) => r.outcome === 'merged').length
log(`${merged} of ${results.length} PRs merged`)
return { results, merged, worktree: clean }
