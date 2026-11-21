---
name: nogps-roll
description: Work through the open NonGPS issues in parallel worktrees. Triage each issue, close the covered ones, take the rest up to a PR, and postpone the blocked ones. Use when the user runs /nogps-roll or asks to roll through, burn down or clear the issue backlog.
argument-hint: "[count | <issue numbers>] [--dry]"
---

# Issue roller

Input, all optional:
- `count` (default 4): how many issues go into implementation. Issues that triage closes, skips or postpones don't
  count, so their slot takes the next issue.
- Issue numbers instead of a count, e.g. `341 338 ELMandIMU#5`: roll only these, in this order.
- `--dry`: triage only. Nothing is written to GitHub and no worktree is made. `count` is then the number of issues
  triaged.

The user started the run, so it publishes without asking: comments, closes, labels, pushes and PRs. Don't ask for
confirmation at any step.

1. **Paths.** `ws` is the folder that holds `app/` and `firmware/`. Run `git -C <ws>/app fetch -q origin` and
   `git -C <ws>/firmware fetch -q origin`.
2. **Queue.** Issues by koloboid or Ramzess-II, open, oldest first, in both repos. Leave out issues labeled
   `postponed`, firmware issues whose last comment is a roller postpone (koloboid can't label in `ELMandIMU`), and
   issues that an open PR fixes:

   ```bash
   for r in Ramzess-II/NoNGPS-Maps Ramzess-II/ELMandIMU; do
     gh pr list -R $r --state open --limit 200 --json closingIssuesReferences \
       --jq "{repo: \"$r\", fixed: [.[].closingIssuesReferences[].number]}"
     gh issue list -R $r --state open --limit 300 --json number,title,labels,author,createdAt,comments --jq '[.[]
       | select(.author.login == "koloboid" or .author.login == "Ramzess-II")
       | select([.labels[].name] | index("postponed") | not)
       | select("'$r'" != "Ramzess-II/ELMandIMU"
           or ((.comments | last | .body // "") | startswith("**Roller: postponed.**") | not))
       | {repo: "'$r'", number, title, createdAt,
          ios: ((([.labels[].name] | index("ios")) != null) or (.title | test("\\[ios\\]")))}]'
   done | jq -s '(map(select(type == "object")) | map(.repo as $r | .fixed[] | "\($r)#\(.)")) as $fixed
     | map(select(type == "array")) | add
     | map(select("\(.repo)#\(.number)" as $k | $fixed | index($k) | not)) | sort_by(.createdAt)'
   ```

   For given numbers, take those issues in the given order, with the same fields, and `count` is their number.
3. **Replay data.** On macOS the slots replay the trips of a change to how the mark moves instead of postponing it.
   They need the maps of one version and the app's `settings.ini`: `maps` and `settings` are the paths the user
   gave, else `<ws>/replay/maps` and `<ws>/replay/settings.ini` when both exist. Pass them only when the OS is
   macOS (`uname` is Darwin), both paths exist and `find <ws>/app/trip-logs/ -name '*.log'` finds a file. Otherwise
   leave both out: a change that needs a replay is postponed, and a PR of a core change says "Not replayed".
4. **Disk.** `df -g <ws>`: a slot starts an implementation only with 15 GB free. With less, say so: the run will
   wait for slots and may stop early.
5. **Run.** Show the queue size, the count and the first issues in one line, then start the saved workflow by its
   path, which works from both `<ws>` and `app/`:
   `Workflow({scriptPath: "<ws>/app/.claude/workflows/nogps-roll.js", args: {ws, queue, count, dry, maps, settings}})`, with
   `queue` as a JSON array, not a string. It runs 4 slots, at most one of them on a change that touches iOS. Per
   issue: triage, implement in its own worktree, review in a fresh context, then fix and publish. A postpone
   comments on the issue with what is missing, labels it `postponed`, pushes the WIP branch if it has commits, and
   removes the worktree.
6. **Report.** Print the table it returns: issue → PR / closed / postponed / skipped, with the reason and links,
   and the number of issues not taken. Then run
   `<ws>/app/tools/unix/nogps_worktree.sh list` and `git -C <ws>/firmware worktree list`. Name any worktree a
   failed agent left behind, and don't remove it: it may hold work.

A postponed issue comes back to the queue when someone removes its `postponed` label, or in `ELMandIMU` adds a
comment after the roller's.
