---
name: nogps-log
description: Analyse NonGPS Maps trip logs (the logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log tree or logs.zip of iOS and Android; older log-dd-MM-yy-<phone>.log, iOS log.txt/log.zip, Android app*.log) to explain what the navigation did on a drive. Use when the user gives logs or asks why the mark went wrong, what happened at a time, or how a trip or a replay went.
argument-hint: "<log files or folder> [question, trip or time]"
---

# Analyse NoGPS trip logs

`tools/python/nogps_log.py` reads the logs and prints what the viewer shows, as text. Run it from the repo root.
Each call reads the logs again: a day of Android logs takes a few seconds.

1. **Trips.** `python3 tools/python/nogps_log.py trips <logs>` lists them, with ids. `<logs>` is the `logs` folder
   (the zips of any phones and days unpacked into one folder), a `logs.zip` or log files; the folder of a file tells
   its phone. `--all` also lists the stationary ones. If the user named a time, take the trip that holds it. Android times are the local time of the
   phone; iOS times are UTC.
2. **Overview.** `nogps_log.py trip <logs> --trip N` prints the stats, what the navigation had learned about the car
   when the trip started (`calibration:`, the last `CALIBRATION` line before the car moves), the error from GPS per source, the
   counts `nogps_replay.py compare` uses, the events by name and every anomaly with its time.
   It also counts the rules of the core that fired (`rules:`) with what came next within 300 m; `nogps_log.py rules
   <logs>` does it over all the trips.
3. **Narrow down** to the moments that matter:
   - `state <logs> --trip N --at HH:MM:SS`: every TRIP field (`*` = changed since the line before), the box flags
     decoded, the anomalies at that moment, the events within 30 s and the other log lines within 5 s.
   - `rows <logs> --trip N --from HH:MM:SS --to HH:MM:SS --fields src,err_m,speed,gps_kmh,hdg,gps_bear,snapwhy`:
     how fields change second by second. `--every 5` thins them out.
   - `events <logs> --trip N [--cat road|turn|box|gps|route|user|state|app|other] [--grep regex] [--full]`.
   - `replay <logs> --trip N --replay <day>-out.txt`: the trip against its replay, the output of
     `nogps_replay.py run` or the Android app's `nogps-replay-out.txt`. Only Android trips are replayed.
4. **Explain.** Read what a field means in `Engine::GetTripLine()` (`libs/map/nogps/engine.cpp`), and the rule
   behind it in the matching section of `docs/nogps/navigation-rules.md`. Find the code that writes an event
   line by its text. For a question the commands don't answer, import the parser in Python:
   `sys.path.insert(0, 'tools/python'); import nogps_log; a = nogps_log.Analysis(nogps_log.load_paths([...]))`,
   then use `a.trips[N].rows` (dicts of TRIP fields with `t` in ms), `.events` and `.anomalies`.
5. **Answer** with the times, the field values and the log lines that show it. To let the user see a moment, give the
   viewer command `python3 tools/python/nogps_log_viewer.py <logs>` and the `#trip=N&t=<ms>` that `state` prints.

The viewer is offline: it loads its libraries from `tools/python/nogps_log_viewer_assets/` and draws the tracks on a
plain background. `--tiles <folder>` draws a map from local `{z}/{x}/{y}.png` tiles and reveals nothing. `--tiles
<url>` fetches tiles from that server, which then sees the area of every trip opened. The choice is kept in
`~/.nogps_log_viewer.json`; `--tiles off` clears it.

The logs hold where the user drove. Keep coordinates and log files out of issues, PRs and commits: the repo is
public. Describe a place by its time on the trip.

A wrong conclusion of the parser (a trip split badly, a false anomaly, an event in the wrong category) is a bug of
`tools/python/nogps_log.py`: tell the user, and fix it with a test in `tools/python/nogps_log_test.py` if they agree.
