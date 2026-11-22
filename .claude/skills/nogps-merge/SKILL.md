---
name: nogps-merge
description: Merge the open NonGPS pull requests. Prepare the independent ones in parallel, review each with Fable, post the findings on the PR, let Opus fix them, and merge them one at a time when the review is clean. Use when the user runs /nogps-merge or asks to merge, land or clear the open PRs, or to take the backlog all the way to master.
argument-hint: "[<PR numbers>] [--no-roll] [--rounds N] [--slots N] [--dry]"
---

# Merge train

Input, all optional:
- PR numbers, e.g. `479 478 471`: take only these and don't run the roller. They are still split by step 3, so the
  independent ones among them are prepped at once; the order given is the order of the serial set.
- `--no-roll`: don't run the issue roller first.
- `--rounds N` (default 3): review/fix rounds per PR. A PR still having findings after them stays open. A PR sent
  back because master moved under it spends one of them.
- `--slots N` (default 4): PRs prepped at once. Each slot takes a worktree and a build dir, so lower it when the
  disk is tight; `1` prepares them one at a time, as the train did before.
- `--dry`: report the two sets and the exclusions. Nothing is pushed, commented or merged.

The user started the run, so it publishes without asking: pushes, comments and merges. Don't ask for
confirmation at any step. The train never rebases a PR branch and never force-pushes it: it merges current master
into the branch, so every push is a fast-forward. Step 2 still leaves out a branch somebody has checked out, so the
train doesn't push commits under the session working there.

1. **Roll first.** Unless `--no-roll` or PR numbers were given, invoke the `nogps-roll` skill and follow it to the
   end; the PRs it opens join the queue. Then `git -C <ws>/app fetch -q origin`. `ws` is the folder that holds
   `app/`.
2. **Queue.** Open PRs of `Ramzess-II/NoNGPS-Maps`, oldest first:

   ```bash
   gh pr list -R Ramzess-II/NoNGPS-Maps --state open --limit 100 \
     --json number,title,headRefName,headRefOid,headRepositoryOwner,isDraft,createdAt,reviewDecision,reviewRequests,labels,url \
     --jq '[.[] | select(.isDraft | not)
           | {number, title, branch: .headRefName, head: .headRefOid, createdAt, reviewDecision, url,
              fork: (.headRepositoryOwner.login != "Ramzess-II"), reviewers: [.reviewRequests[].login],
              labels: [.labels[].name]}] | sort_by(.createdAt)'
   git -C <ws>/app worktree list --porcelain | sed -n 's|^branch refs/heads/||p'
   ```

   Leave a PR out, with a line in the report for each:
   - a commit of it is authored by anyone but koloboid or Ramzess-II, including an upstream sync PR. A person
     merges those, as `.claude/rules/nogps-workflow.md` says:
     `gh api --paginate repos/Ramzess-II/NoNGPS-Maps/pulls/<n>/commits --jq '.[].author.login // "unknown"' | sort -u`
   - it waits for the other person's review: `reviewers` is not empty, or `reviewDecision` is `REVIEW_REQUIRED` or
     `CHANGES_REQUESTED`. They approve it;
   - its branch is one of those `git worktree list` printed: a session works in it, and the train would push
     commits under it;
   - `fork` is true: the train can't push to another owner's branch.

   PRs of `Ramzess-II/ELMandIMU` don't go into the queue: the train works in one repo (#504). Both of us can merge
   there, so list the open ones for the user (`gh pr list -R Ramzess-II/ELMandIMU --state open`) as ready to merge
   by hand, with the same author check.
3. **Two sets.** For each PR left: `gh pr view <n> --json files,additions,deletions,body`. Then split them:
   - **parallel**: the PRs whose files no other queued PR touches and that are in no dependency pair with another
     queued PR -- neither depended on by one nor depending on one, smallest diff first. Nothing the train merges can
     break them, so their prep and their CI runs go at the same time. A PR depends on another when its body says
     "Depends on #N" for a queued PR, or when that PR's head is an ancestor of its head
     (`git -C <ws>/app merge-base --is-ancestor <other head> <head>`). Both PRs of such a pair go to **serial**:
     the whole parallel set is merged before the serial one, so a dependent PR left in parallel would land before
     what it depends on.
   - **serial**: the rest, in the order the train takes them one at a time: a PR others depend on before the ones
     that depend on it, then the others oldest first, and a PR that touches the files of several others last, so
     master is merged into it and not the other way round.

   Print both sets with one line each: number, title, its set and why. With `--dry` stop here.
4. **Run.** Start the saved workflow by its path, which works from both `<ws>` and `app/`:
   `Workflow({scriptPath: "<ws>/app/.claude/workflows/nogps-merge.js", args: {ws, parallel, serial, rounds, slots}})`,
   with `parallel` and `serial` as JSON arrays of the PR objects of step 3, not strings. Up to `slots` workers each
   prep one PR of the parallel set in their own worktree `<ws>/worktrees/merge-<slot>` -- master merged in, reviewed
   by Fable, fixed by Opus, pushed -- so the PRs' checks run together. The merge gate then takes one prepped PR at a
   time, in `<ws>/worktrees/merge-train`: it sends a PR back for one more round when master gained a file the PR
   touches since its prep, merges the PR into current master locally and runs the core tests on the two together,
   and merges on GitHub when CI is green. The serial set follows, one PR at a time in the gate worktree. A PR the
   train can't merge stays open and it goes on to the next one.
5. **Report.** Print the table it returns: PR → merged (with the merge commit) / open (with the reason) / blocked,
   with its set, the rounds it took and the number of findings; name the PRs that went back for another round
   because master moved under them (`staleRounds`), and any whose core tests failed only once merged into master
   (`combinedTest`). Then `git -C <ws>/app log origin/master --oneline -<merged count>` for what landed, and
   `<ws>/app/tools/unix/nogps_worktree.sh list`: name a worktree the train left behind and don't remove it, it may
   hold work. Last, the PRs left out in step 2 and who has to act on them.
