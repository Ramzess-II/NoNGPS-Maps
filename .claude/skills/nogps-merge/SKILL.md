---
name: nogps-merge
description: Merge the open NonGPS pull requests. Prepare the independent ones in parallel, review each with Opus, post the findings on the PR, let Sonnet fix them, and merge them one at a time when the review is clean. Use when the user runs /nogps-merge or asks to merge, land or clear the open PRs, or to take the backlog all the way to master.
argument-hint: "[<PR numbers>] [--no-roll] [--rounds N] [--max-reviews N] [--slots N] [--dry]"
---

# Merge train

Input, all optional:
- PR numbers, e.g. `479 478 471`: take only these and don't run the roller. They are still split by step 3, so the
  independent ones among them are prepped at once; the order given is the order of the serial set.
- `--no-roll`: don't run the issue roller first.
- `--rounds N` (default 3): review/fix rounds per PR. A PR still having findings after them stays open. A PR sent
  back because master moved under it spends one of them.
- `--max-reviews N` (default 5): train reviews a PR gets in all, over every run, the Fable confirmation included.
  A PR at the cap is left out. Raise it for a PR a person has reworked since.
- `--slots N` (default 4): PRs prepped at once. Each slot takes a worktree and a build dir, so lower it when the
  disk is tight; `1` prepares them one at a time, as the train did before.
- `--dry`: report the two sets and the exclusions. Nothing is pushed, commented or merged.

The user started the run, so it publishes without asking: pushes, comments and merges. Don't ask for
confirmation at any step. The train never rebases a PR branch and never force-pushes it: it merges current master
into the branch, so every push is a fast-forward. Step 2 still leaves out a branch somebody has checked out, so the
train doesn't push commits under the session working there.

1. **Roll first.** Unless `--no-roll` or PR numbers were given, invoke the `nogps-roll` skill and follow it to the
   end; the PRs it opens join the queue. Then `git -C <ws>/app fetch -q origin` and
   `git -C <ws>/firmware fetch -q origin`. `ws` is the folder that holds `app/` and `firmware/`.
2. **Queue.** Open PRs of both repos, oldest first. First `Ramzess-II/NoNGPS-Maps`:

   ```bash
   gh pr list -R Ramzess-II/NoNGPS-Maps --state open --limit 100 \
     --json number,title,headRefName,headRefOid,headRepositoryOwner,isDraft,createdAt,reviewDecision,reviewRequests,labels,url \
     --jq '[.[] | select(.isDraft | not)
           | {number, title, repo: "Ramzess-II/NoNGPS-Maps", branch: .headRefName, head: .headRefOid, createdAt,
              reviewDecision, url, headOwner: .headRepositoryOwner.login,
              reviewers: [.reviewRequests[].login], labels: [.labels[].name]}] | sort_by(.createdAt)'
   git -C <ws>/app worktree list --porcelain | sed -n 's|^branch refs/heads/||p'
   ```

   Leave a PR out, with a line in the report for each:
   - a commit of it is authored by anyone but koloboid or Ramzess-II, including an upstream sync PR. A person
     merges those, as `.claude/rules/nogps-workflow.md` says:
     `gh api --paginate repos/<its repo>/pulls/<n>/commits --jq '.[].author.login // "unknown"' | sort -u`
   - it waits for the other person's review: `reviewers` is not empty, or `reviewDecision` is `REVIEW_REQUIRED` or
     `CHANGES_REQUESTED`. They approve it;
   - its branch is one of those `git worktree list` printed: a session works in it, and the train would push
     commits under it;
   - `headOwner` is neither `koloboid` nor `Ramzess-II`: the head is in somebody else's fork and the train
     can't push to a branch of theirs. A fork of one of the two is taken, not left out: the train reads the head
     from a remote named after the fork's owner and pushes the update and the fixes back to that same branch, so
     `headOwner` goes into the PR object of step 4 whenever it differs from the repo's owner;
   - it has had `--max-reviews` train reviews (default 5) or more, counted over every run: the
     `**Merge-train review` comments on it, which go into the PR object of step 4 as `reviews` for every PR taken.
     Its line in the report says "review limit: N train reviews":

     ```bash
     gh api --paginate repos/<its repo>/issues/<n>/comments --jq '.[] | select((.user.login == "koloboid" or
       .user.login == "Ramzess-II") and (.body | startswith("**Merge-train review"))) | .id' | wc -l
     ```

   Then the same for `Ramzess-II/ELMandIMU`, the box firmware: the train lands its PRs too. Run the same two
   commands with `-R Ramzess-II/ELMandIMU`, `Ramzess-II` still the owner to compare against, and
   `git -C <ws>/firmware worktree list --porcelain` for the checked-out branches. Give every PR a `repo` field with
   its repo, the app's included, and keep the two lists in one queue sorted by `createdAt`: the train takes a PR of
   either repo in any slot.
3. **Two sets.** For each PR left: `gh pr view <n> -R <its repo> --json files,additions,deletions,body`. Files
   and dependencies are compared only within one repo: a path of the app and the same path of the firmware are
   different files, and neither repo's history reaches the other's. Then split them:
   - **parallel**: the PRs whose files no other queued PR of the same repo touches and that are in no dependency pair with another
     queued PR -- neither depended on by one nor depending on one, smallest diff first. Nothing the train merges can
     break them, so their prep and their CI runs go at the same time. A PR depends on another when its body says
     "Depends on #N" for a queued PR, or when that PR's head is an ancestor of its head
     (`git -C <ws>/app merge-base --is-ancestor <other head> <head>`). Both PRs of such a pair go to **serial**:
     the whole parallel set is merged before the serial one, so a dependent PR left in parallel would land before
     what it depends on.
   - **serial**: the rest, in the order the train takes them one at a time: a PR others depend on before the ones
     that depend on it, then the others oldest first, and a PR that touches the files of several others last, so
     master is merged into it and not the other way round.

   At most one PR that touches `iphone/` or `xcode/` goes into **parallel**; the others go to **serial**, however
   disjoint their files are. Nothing in the train builds iOS -- the gate leaves it to each PR's own CI, which ran
   before the other PRs of the parallel set landed -- so a pair that breaks only the iOS build would land unseen
   (#513). The script enforces this too, and says so in its log.

   Print both sets with one line each: number, title, its set and why, and its train reviews so far. With `--dry`
   stop here.
4. **Run.** Start the saved workflow by its path, which works from both `<ws>` and `app/`:
   `Workflow({scriptPath: "<ws>/app/.claude/workflows/nogps-merge.js", args: {ws, parallel, serial, rounds, slots,
   maxReviews}})`, with `parallel` and `serial` as JSON arrays of the PR objects of step 3, each carrying its `repo`
   and `reviews`, not strings.
   The script refuses a `repo` that is neither of the two before any agent runs. Up to `slots` workers each prep one
   PR of the parallel set in their own worktree `<ws>/worktrees/merge-<slot>` -- its default branch merged in,
   reviewed by Opus, fixed by Sonnet, pushed -- so the PRs' checks run together. A PR whose first review found
   nothing is read once more by Fable before it goes to the gate, and that confirmation spends none of its rounds.
   The merge gate then takes one prepped PR at a time, in `<ws>/worktrees/merge-train`: it sends a PR back for one
   more round when its branch gained a file the PR touches since its prep, merges the PR into that branch locally
   and runs the tests on the two together, and merges on GitHub when CI is green. The serial set follows, one PR at
   a time in the gate worktree. A PR the train can't merge stays open and it goes on to the next one.

   Every review sees the findings of the earlier rounds of this run and the train's comments of earlier runs. It
   marks a finding that undoes an earlier fix, or raises again a finding the fixer rejected with no new argument, as
   a cycle: the train then runs no fix and leaves the PR open with "review/fix cycle", for a person to decide. Each
   review and confirmation adds to `reviews`; a PR that reaches `maxReviews` during its prep stops there.

   A firmware PR runs the same way in a worktree of `<ws>/firmware` whose name ends in `-fw`, made by plain
   `git worktree add` from `origin/main` with `keys/` linked and `sdkconfig` copied from the main checkout -- both
   are gitignored there, and without them the build is unsigned or built for the wrong chip. The CI of a firmware PR
   builds S3 and C3 (`.github/workflows/build.yml`) and the gate waits for it like for an app PR; its own
   `idf.py build` stays, as the only build with the main checkout's `sdkconfig`. Where it cannot run (no
   ESP-IDF, no signing key) the PR is reported `blocked` with `not built: <why>` and is not merged.
5. **Report.** Print the table it returns: PR → merged (with the merge commit) / open (with the reason) / blocked,
   with its set, the rounds it took, its train reviews in all (`reviews`) and the number of findings; name the PRs
   stopped by a review/fix cycle or by the review limit, the PRs that went back for another round
   because master moved under them (`staleRounds`), and any whose core tests failed only once merged into master
   (`combinedTest`). Name the repo of each row: the two repos number their PRs apart. Then
   `git -C <ws>/app log origin/master --oneline -<merged count>` and, when a firmware PR landed,
   `git -C <ws>/firmware log origin/main --oneline -<count>` for what landed. Then
   `<ws>/app/tools/unix/nogps_worktree.sh list` and `git -C <ws>/firmware worktree list`: name a worktree the train
   left behind and don't remove it, it may hold work. Last, the PRs left out in step 2 and who has to act on them.
