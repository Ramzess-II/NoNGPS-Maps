---
name: nogps-merge
description: Merge the open NonGPS pull requests one by one. Merge master into each, review it with Fable, post the findings on the PR, let Opus fix them, and merge when the review is clean. Use when the user runs /nogps-merge or asks to merge, land or clear the open PRs, or to take the backlog all the way to master.
argument-hint: "[<PR numbers>] [--no-roll] [--rounds N] [--dry]"
---

# Merge train

Input, all optional:
- PR numbers, e.g. `479 478 471`: take only these, in the order given, and don't run the roller.
- `--no-roll`: don't run the issue roller first.
- `--rounds N` (default 3): review/fix rounds per PR. A PR still having findings after them stays open.
- `--dry`: report the order and the exclusions. Nothing is pushed, commented or merged.

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
3. **Order.** For each PR left: `gh pr view <n> --json files,additions,deletions,body`. Then order them:
   1. a PR another one depends on goes first: its body says "Depends on #N", or its head is an ancestor of the
      other's head (`git -C <ws>/app merge-base --is-ancestor <head> <other head>`);
   2. then the PRs whose files no other queued PR touches, smallest diff first: nothing the train merges can break
      them;
   3. then the rest, oldest first, and a PR that touches the files of several others last, so it rebases over them
      and not the other way round.

   Print the order with one line each: number, title, why it is there. With `--dry` stop here.
4. **Run.** Start the saved workflow by its path, which works from both `<ws>` and `app/`:
   `Workflow({scriptPath: "<ws>/app/.claude/workflows/nogps-merge.js", args: {ws, queue, rounds}})`, with `queue` as
   a JSON array of the PR objects in the order of step 3, not a string. It works one PR at a time in one worktree:
   merge current master into the PR branch, review with Fable, post the findings, fix with Opus, review again, then
   merge when the review is clean and CI is green. A PR it can't merge stays open and the train goes on to the next one.
5. **Report.** Print the table it returns: PR → merged (with the merge commit) / open (with the reason) / blocked,
   the rounds it took and the number of findings. Then `git -C <ws>/app log origin/master --oneline -<merged count>`
   for what landed, and `<ws>/app/tools/unix/nogps_worktree.sh list`: name a worktree the train left behind and
   don't remove it, it may hold work. Last, the PRs left out in step 2 and who has to act on them.
