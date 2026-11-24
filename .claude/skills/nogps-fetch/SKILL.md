---
name: nogps-fetch
description: Fetch the NonGPS Maps trip logs and flags (screenshots, voice notes) from the phones plugged into this computer into trip-logs/, import the new days and summarize them. Use when the user asks to pull, fetch, get or download the logs or flags from a phone, or says they just drove.
argument-hint: "[--device <udid|name|serial>] [--from <folder>]"
---

# Fetch trip logs and flags from the phones

`tools/python/nogps_logs.py fetch` (or `just fetch`) copies `logs/` and `flags/` of both apps, release and debug,
from every phone plugged in: iOS through `xcrun devicectl` (macOS only), Android through `adb`. Run it from `app/`,
where `trip-logs/` is. It adds to the tree and never deletes: the phone keeps flags only 7 days, `trip-logs/` is the
archive. Its docstring tells the rules.

1. **Fetch.** `just fetch`, or `python3 tools/python/nogps_logs.py fetch [--device <id>] [--from <folder>]`.
   `--from` takes a folder of `logs/` and `flags/` already on disk, an unpacked copy.
2. **Read the summary.** A line per app: new and grown logs, new and changed flag files, files skipped (the names of
   the earlier versions, OSLog text without `LOGFMT`). Then the phone-days it imported into `trip-logs/db/`, the
   notes, the driven trips of those days and their flags. Tell the user what came in, and every note: a phone that
   refuses access to `Android/data`, an app without a container (installed from the App Store), a failed import. A
   flag with `UTC unknown` is on a day whose logs don't tell the phone's offset.
3. **Rules.** `python3 tools/python/nogps_log.py rules trip-logs/<phone>/<day> …` over the new days: how often each
   rule fired and what came next.
4. **Show.** Give the user `just logs --library trip-logs`: the viewer lists the phones, days and flags; a flag plays
   its voice note and opens its trip at its second.

For a question about a trip or a flag, hand over to `/nogps-log` with the day folders.

Held-out days (`nogps_replay.py days`): a day of 2026-11-22 or later whose day of the month divides by 4 is held out
by rule. Don't tune a rule on its trips; reading one to answer the user is fine, but say it is held out.

The logs and flags hold where the user drove and what they said. Keep coordinates, screenshots and voice notes out
of issues, PRs and commits.
