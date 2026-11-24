# NonGPS Maps: how we work

This repo is a fork of Organic Maps. Two people build the navigation without GPS, each with their own Claude Code:

- **Ramzess** (`Ramzess-II`, repo owner). Windows: no desktop or iOS build; core tests run on an Android phone and
  in CI.
- **koloboid**. macOS: can build desktop targets and run `map_tests`.

Everyone works on every part: the core `libs/map/nogps`, its road search (`libs/routing/index_router.*`,
`libs/map/routing_manager.*`), `android/` and `iphone/`, `xcode/`. A change to behavior that both apps show is made
on both platforms in the same PR. The author builds and verifies what their machine can; the rest is checked by CI
or by the other person on a device.

Keep upstream files (`CLAUDE.md`, nested `CLAUDE.md`, `.claude/settings.json`, upstream skills) unchanged so upstream
merges stay clean. Fork rules go in `.claude/rules/nogps-*.md`, fork skills in `.claude/skills/nogps-*`.

## Flow of a change

1. **Idea → issue.** Run `/nogps-plan <idea>`. It checks open issues and PRs for overlap and writes the plan into
   the issue. Skip the plan when the diff fits in one sentence.
2. **Implement in a fresh session** (`/clear`, then "implement #N") on `feature/<name>` from current `origin/master`.
   If the main checkout isn't on a clean `master`, another session probably works in it: implement in a worktree,
   see "Parallel work". An iOS change stays in the main checkout, so ask the user first.
3. **Finish with `/nogps-pr`**: tests, living docs, issue for the other platform, review in a fresh context, PR.
4. **Merge only through a PR.** When the repo variable `CLAUDE_REVIEW` is `on`, CI posts a Claude review when a PR
   opens. Comment `@claude <request>` on a PR to ask for a re-review or a fix. If the PR changes the shared
   interface, the other person approves it. Otherwise the author merges after CI passes.

   IMPORTANT: an agent never merges a PR, in either repo, that has a commit authored by anyone but koloboid or
   Ramzess-II, even when asked to. The commit's author counts; Co-Authored-By trailers don't. Before every merge,
   `gh api --paginate repos/<owner>/<repo>/pulls/<n>/commits --jq '.[].author.login // "unknown"' | sort -u` must
   print only `koloboid` and `Ramzess-II`. Any other login or `unknown` stops the merge: tell the user, and a person
   merges it on GitHub. An upstream sync PR has Organic Maps authors, so a person merges it too.

## Parallel work

A checkout has one working tree. When one of two sessions in it switches branches, its uncommitted changes go
along, and the other session commits them as its own. Run one session per checkout, and give a second session at
the same time its own worktree made by `tools/unix/nogps_worktree.sh`:

- `add <name> [base]` makes the branch `feature/<name>` from `base` (default `origin/master`: fetch first) in
  `<ws>/worktrees/<name>`, where `<ws>` is the folder that holds the main checkout. It clones the submodules from the
  main checkout with no network, links `credentials/` and `trip-logs/`, and prints the path. Build there in
  `build-<name>`.
- `remove <path>` refuses a worktree with uncommitted changes. It deletes the branch when all its commits are on a
  remote and it is merged or was never pushed. `list` shows the worktrees and the size of their build dirs.
- The first build in a new worktree is mostly ccache hits once ccache is set up on the machine:
  `ccache --set-config base_dir=<ws>`, `hash_dir=false` and `max_size=20G`. `add` warns when they aren't set. Also
  keep `cache_dir` out of `~/Library/Caches` (macOS reclaims it on a full disk): `mkdir -p ~/.cache`,
  `mv <old cache_dir> ~/.cache/ccache` when that directory exists (ccache creates it at the first compilation) and
  `ccache --set-config cache_dir="$HOME/.cache/ccache"` in any case. Not `~/.ccache`:
  that directory makes ccache read its legacy config file `~/.ccache/ccache.conf` instead and lose the three
  settings above. `add` warns about the cache_dir too.
- Build iOS in the main checkout: Xcode's DerivedData is per path, so a worktree builds it from scratch.
- Claude Code's `--worktree`, EnterWorktree and `isolation: "worktree"` use the script through hooks in
  `.claude/settings.local.json` of the folder you start Claude in (drop `app/` from the path when that is `app/`):

  ```json
  {
    "hooks": {
      "WorktreeCreate": [{"hooks": [{"type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR\"/app/tools/unix/nogps_worktree.sh hook-create"}]}],
      "WorktreeRemove": [{"hooks": [{"type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR\"/app/tools/unix/nogps_worktree.sh hook-remove"}]}]
    }
  }
  ```

  Claude doesn't remove the worktree of a subagent: run `remove` when it is done.

## Issue roller

`/nogps-roll [count | <issue numbers>] [--dry]` works through the open issues of koloboid and Ramzess-II in both
repos, oldest first, in 4 parallel worktrees, at most one of them on iOS. It closes an issue that a merged PR or a
newer issue covers. It takes the rest through this flow up to a PR labeled `roller`, without asking. It postpones
what needs a car, a phone, a box or a person's decision: it comments on the issue with what is missing and
labels it `postponed`. Remove the label when the answer is there. `--dry` only triages and writes nothing. The
script is `.claude/workflows/nogps-roll.js`. Unlike a session, its iOS slot builds Xcode in its worktree, from
scratch, into a build dir that removing the worktree deletes. When the maps and `settings.ini` for a replay are
given (`<ws>/replay/maps` and `<ws>/replay/settings.ini`, or the paths in the command), a slot replays a change to
how the mark moves before and after with `nogps_replay_tool`, as in "Verification", instead of postponing it. Without
them such a PR says "Not replayed".

## Merge train

`/nogps-merge [<PR numbers>] [--no-roll] [--rounds N] [--max-reviews N] [--slots N] [--dry]` lands the open PRs of
both repos. It runs the issue roller first, unless `--no-roll` or PR numbers are given, then splits what is left
into two sets and takes each PR through: merge the PR's own default branch into it and push, review with Opus which
posts its findings on the PR, fix with Sonnet which replies on the same PR, review again, and merge with a merge
commit once a review comes back clean and CI is green. Up to `--rounds` rounds (default 3). A review that finds
nothing on the first pass is confirmed by Fable, the most capable model, before the PR reaches the gate: one pass
that found nothing is weak evidence the diff was read, and nobody else looks at the PR. The confirmation is not a
round of its own, and a PR that had findings doesn't get one -- the clean round that followed them re-read the
fixes. A PR gets at most `--max-reviews` train reviews in all (default 5), counted over every run from its
`**Merge-train review` comments, the confirmation included; at the cap it stays open untouched. A review that asks
to undo an earlier round's fix, or raises again a finding the fixer rejected, marks the finding as a cycle: the
train runs no fix and leaves the PR open for a person to decide between the two rounds.

Only the merge is serial. The PRs whose files no other queued PR touches and that are in no dependency chain with
one are prepped in parallel, up to `--slots` of them at once (default 4), each in its own worktree
`<ws>/worktrees/merge-<slot>`: they are pushed while the others are still being reviewed, so their CI runs overlap
instead of one PR waiting out another's checks. The merge gate, in `<ws>/worktrees/merge-train`, then takes one
prepped PR at a time:

- a PR whose files master gained since its prep goes back for one more update and review round, which spends one of
  the `--rounds`: the review it has was made without those files;
- the gate merges the PR into current master locally and runs the core tests on the two together. No CI run makes
  that check: each PR's own checks ran before the other one landed.

The rest -- the PRs that touch another queued PR's files, and the dependency chains -- follow after, one at a time in
the gate worktree, as the whole train worked before. The script is `.claude/workflows/nogps-merge.js` and its
scheduler is tested by `node .claude/workflows/nogps-merge-test.mjs` (stubbed agents, no network); the worktrees go
away at the end of the run.

IMPORTANT: nothing here rebases a PR branch or force-pushes it, with or without a lease. A branch of an open PR is
only moved forward: master is merged into it, so every push is a fast-forward. This holds for the train, for a
session and for an agent, and a push that would need a force is a reason to stop and tell the user.

A PR it can't land stays open and the train goes on to the next one: a merge conflict that isn't plain, a failing
check, findings still open after the last round. It never takes a PR with a commit of anyone but koloboid or
Ramzess-II, one waiting for the other person's review, one from a fork of anyone but the two of us, or one whose
branch is checked out in the main checkout or a worktree -- the train would push commits under the session working
there.

The train lands the PRs of both repos: each PR of its queue carries its repo, and a firmware PR is prepped in a
worktree of `firmware/` whose name ends in `-fw`, off `origin/main` (that repo has no `master`). `ELMandIMU` gets a
CI build of a PR for S3 and C3 (`.github/workflows/build.yml`, a throwaway signing key) in ELMandIMU#28, but GitHub
Actions has started no run in that repo yet (ELMandIMU#29), so the gate's `idf.py build` of the PR merged into `main`
is still the only check a firmware PR gets and the train waits for no check there; the worktree needs `keys/` linked
and `sdkconfig` copied from the main checkout, both gitignored there, or the build is unsigned or built for the wrong
chip. Two PRs that touch `iphone/` or `xcode/` are never prepped at once: nothing in the train builds iOS, so only
one of them goes into the parallel set.

## Versions

Nobody raises a version by hand. Each build takes them from git: `tools/unix/version.sh` gives the app version
`YYYY.MM.DD` (on Android `versionName` is `YYYY.MM.DD-N`) and the build number `yyMMddNN`, from the UTC date of the
last commit and the number of commits of that day. On iOS the "NonGPS versions" Run Script phases put them into the
Info.plist through `tools/unix/nogps_version.sh ios_plist`. A rebuild of the same commit has the same version; the
commit hash tells builds apart. About and the trip log show
`2026.11.08 (26110807, abcdef12), Organic Maps 2026.10.27-10`.

`tools/unix/nogps_upstream_version.txt` is the Organic Maps version the build is based on. After an upstream merge,
run `tools/unix/nogps_version.sh upstream` and commit the file in the merge PR.

The day's number counts the commits of the branch that is built, so a branch build can have a bigger build number
than a later `master` build of the same day. Android then refuses to install the `master` build over it: uninstall
first or use `adb install -r -d`.

`NN` stops at 99: the Android `versionCode` keeps two digits for it, and a third one carries the Wear OS code, ten
times the phone one, past the int Gradle holds a versionCode in. Past the 99th commit of a day every build repeats
99: Android `versionName` still counts them, the version line tells them apart only by the commit hash, and App
Store Connect refuses a second upload of that day.

## Work you don't do now goes to an issue

IMPORTANT: anything you notice that this session won't finish goes into a GitHub issue before the session ends or
its PR opens: a platform part left for later, a bug or risk you noticed, a TODO, a step left for later. Not into
docs, PR text, code comments or memory: nobody tracks those.

Don't open an issue to check or test a PR on a device, before or after it merges. Write in the PR's **Tested** what
was not checked on a device. Whoever drives it opens a bug issue when something is wrong.

- Look for an open issue first (`gh issue list --state open`) and comment there instead of opening a duplicate.
- Label it `core`, `ios`, `android` or `firmware`, and assign whoever will do it (`@me` if it is you). Say what to do
  and where, and which PR caused it.
- Link it from the PR's **Other platform** section. CI fails a PR whose **Other platform** section has neither an
  issue link nor "Nothing to do" and why. When the PR changes both platforms, write "Nothing to do: both platforms
  are changed here".
- Give the user the links of the issues you opened.

## Shared interface

Both platforms see the core through `libs/map/nogps/engine.hpp` (public methods, `Status`, `Event`), `delegate.hpp`,
and the order of values in their enums. The bridges are `android/sdk/src/main/cpp/app/organicmaps/sdk/NoGps.cpp` with
`NoGps.java`, and `iphone/Maps/Core/NoGps/MWMNoGps.h/.mm`. When the interface changes:

- change both bridges in the same PR;
- a new file in `libs/map/nogps` goes into `libs/map/CMakeLists.txt` and `xcode/map/map.xcodeproj/project.pbxproj`.
  If the author can't build iOS, the PR says "Xcode project not verified".

The box protocol is a shared interface too: `docs/nogps/esp32-firmware-spec.md` is what the app, the firmware and the
box simulator (`tools/python/nogps_box_sim.py`, #468) all follow. A change to it — a line, a field, a command, a flag,
a cap, an error — touches the spec in this repo, and the simulator changes in the same PR:

- a line the box sends: the simulator sends it too, with the fields the panel can set;
- a command the app sends: the simulator answers it, and can answer with the refusals the box would give
  (`ERR,BUSY`, `ERR,VALUE`), so the app's handling of them can be seen without the box;
- a cap in `NGI`: reported only once the simulator does what it promises, as the app gates its commands on the caps;
- what the simulator can't do, because CoreBluetooth or BlueZ won't, goes in its docstring and in the PR.

A test in `tools/python/nogps_box_sim_test.py` comes with it. A firmware change that leaves the protocol alone — a
driver, OBD, the power rules — doesn't touch the simulator.

## Living docs

Update these in the same PR, in a separate `[docs]` commit:

- `docs/nogps/navigation-rules.md`: the current rules of the core and their constants. Read the section you need
  before changing core behavior, not the whole file. If you change a rule or a threshold, change it here too.
- `docs/nogps/esp32-firmware-spec.md`: the box protocol and firmware.

Docs say what is true now. Why it got that way stays in commits and PRs: `git log -- <file>`, `gh pr view <n>`.
Work left to do lives in issues, not in markdown lists.

## Language

Don't write in Russian: not in issues, PRs, comments, commits, docs, or the firmware repo `Ramzess-II/ELMandIMU`.
Write in English. Where a text needs a local language, e.g. a new section of a doc written in Russian, use
Ukrainian. The app's Russian translations in `data/strings/` stay as they are.

## Verification

- Core: unit tests `NoGps_*` in `map_tests`. macOS: `cmake --build build-<name> --target map_tests` then
  `build-<name>/map_tests --filter="NoGps_.*"`. Windows: the `C++ tests` CI check on the PR.
- A change to how the mark moves: replay the recorded trips with `tools/python/nogps_replay.py` and put the
  before/after numbers in the PR. If nobody replayed it, the PR says so.
  - macOS and Linux, the default: `nogps_replay.py run <logs> --tool build-<name>-o2/nogps_replay_tool --data_path
    <maps> --settings <settings.ini> -o <folder>` drives all days in parallel, 13 days in about 80 s. The script's
    docstring tells how to build the tool and where to take the maps and the settings.
  - Windows: the Android debug build (`-PnativeOptimized` for speed) drives one day at a time on a phone.
  - Before and after are built the same way and driven on the same maps and settings.
- Replay the days of both sets: the held-out days listed in `tools/python/nogps_held_out_days.txt` (never used to set
  a rule) and the others (`nogps_replay.py days <logs>` tells each day's set). Give the numbers of each set apart: a
  rule better on the days it was made from and not on the held-out ones fits its case only. Never move a day into the
  held-out list after a rule was made from it.
- `nogps_log.py rules <logs>` counts how often each rule fired over the trips and what came next within 300 m. Run it
  before and after a change of a rule; a rule that fired in one or two trips, or is followed by a loss or a tap
  more often than not, is a candidate to drop or merge.
- Every behavior change gets a unit test.
- Strings: tag a string in `data/strings/strings.txt` only for the platforms whose code uses it. On iOS, write the
  key inside `L("key")`, not in a variable. Check with `python3 tools/python/validate_translation_keys.py`.
