#!/usr/bin/env python3
"""Drives a recorded trip of NonGPS Maps again and tells what has changed.

The trip is driven through a navigation of its own by libs/map/nogps_replay, which writes the trip log of that drive,
and <output>.done when it is over. Two programs run it:
- nogps_replay_tool on macOS and Linux, the default: `run` below drives the days with it, a few at a time. Build it
  with optimized C++, ASSERTs kept, in a build folder of its own:
    cmake --preset debug -B build-<name>-o2 -DSKIP_QT_GUI=ON "-DCMAKE_CXX_FLAGS_DEBUG=-O2 -g" \
        "-DCMAKE_C_FLAGS_DEBUG=-O2 -g"
    cmake --build build-<name>-o2 --target nogps_replay_tool
  It takes the .mwm files of one version (pull the phone's: adb pull /sdcard/Android/data/<package>/files/260714)
  and, for what the navigation has learned about the car, settings.ini of the app (of a debug build:
  adb shell run-as <package> cat files/settings.ini > settings.ini). Without it the car is new.
  The car comes from the CALIBRATION line the log wrote before the box data of the file begins: its car, scale,
  tables, factor, lag and accelerometer, with the box id first, so a trip in another car is not driven with the
  values of this one. what that line does not carry is the default, not what settings.ini has, which fills only a day with no such line;
  the car speed unit is never taken from it. `run` tells for each day which of the two the car was driven with.
  The accelerometer of a box is taken only for the box the trip was driven with (the logs tell it): the settings of
  another box give the same replay as without them.
- a debug build of the Android application, on Windows: it drives the file nogps-replay-in.txt put to its folder
  (/sdcard/Android/data/<package>/files/) when it starts, and writes nogps-replay-out.txt. Build it with optimized
  C++ for replays, about 6 times faster, ASSERTs kept:
    ./gradlew assembleFdroidDebug -Parm64 -PnativeOptimized
Compare a change only with a build of the same kind, on the same maps and settings: a few diagnostic values differ
in the last digit.

The logs are the files of the Android app, logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log, the tree as the phone writes it
(the names of the earlier versions are not read). A folder given is read with its subfolders: give the whole tree,
a phone or a day. The first line of a file, LOGFMT, tells its phone, and its path does for the OSLog text of iOS;
a file of another layout, or of a format the tools do not know, is skipped with a note and refused when no file is
left. The logs of each phone are driven apart and labeled with the phone, since the lines of two
would be mixed: `days`, `run` and `input` take a tree of several phones, `compare` one phone, as it takes one
replay.

  nogps_replay.py input logs --day 10-11 -o nogps-replay-in.txt [--no-taps] [--no-route] [--from HH:MM]
      [--to HH:MM] [--fresh]
      makes the file to drive from the trip logs of a day: the rotation, the speed and the acceleration of the
      sensor box, the marks and the buttons of the user, the routes the user asked for. --no-taps leaves only the
      mark each trip starts with, --no-route drives without the routes. Where the application started anew has
      shown the car it kept, or the file begins with the car off the roads, the file gives that kept car instead of
      a tap: a tap would put it on a road. --fresh drives the trip as the first one: the file begins with "D <day>
      fresh", and the speed scale and tables of settings.ini are not taken. Logs of several phones make a file
      each, <name>-<phone>.<ext>.

  nogps_replay.py compare logs/<phone> --day 10-11 --replay nogps-replay-out.txt
      how far the mark was from GPS on the trip and how far it is driven again, where GPS was seen. The first line
      says which set the day is in.

  nogps_replay.py run logs --tool build-<name>-o2/nogps_replay_tool --data_path <maps> [--settings <ini>]
      [--day MM-DD ...] [-j N] -o <folder> [--no-taps] [--no-route] [--fresh] [--any-maps]
      makes the input of every day of the logs, or of the days given, drives them with nogps_replay_tool, N at a time,
      and prints a line of compare a day, the held-out days and the days rules were made from apart, with the
      seconds of all the days of each set. The inputs, the outputs, the log of the tool and the full compare of
      every day are written to the folder <output>/<phone>. A day is not driven when the version of the maps it was
      driven on (the MAPS line of its log) is not the one of --data_path: the roads would differ. --any-maps drives
      it anyway. A line tells when the logs come from other builds than the checkout the tool is built from.

  nogps_replay.py days logs
      the days of the logs with the seconds of TRIP lines and the set of each: "held out" (listed in
      nogps_held_out_days.txt, never used to set a rule) or "made from". A change of how the mark moves is replayed
      on the days of both sets, and the numbers of both go to the PR: better on the days it was made from and not
      on the held-out ones means the rule fits its case only.

The files made here keep the places of the trip: they are not for git. Nothing printed has coordinates.
"""
import argparse
import bisect
import collections
import concurrent.futures
import contextlib
import io
import math
import os
import re
import subprocess
import sys
import time

import nogps_trip_log

MAPS_LINE = re.compile(r'^MAPS (?:ms=\d+ )?version=(\S+)')
LINE = re.compile(r'^(\d\d-\d\d) (\d\d):(\d\d):(\d\d)\.(\d\d\d) \(([^)]*)\) \w/(\w+): (.*)$')
FIELD = re.compile(r' (\w+)=(\S+)')
SOURCE = re.compile(r'^\S+:\d+ (\w+)\(\): (.*)$')
BOX_INFO = re.compile(r'^Box (?!firmware\b)(\S+) firmware')
# The switches of the user; the core wrote "disabled = " and "enabled = " before 2026-10-29.
GPS_OFF = re.compile(r'^(?:GPS ignored by the user|disabled) = (\d)')
MANUAL = re.compile(r'^(?:Manual mode|enabled) = (\d)')
TAP = re.compile(r'tap = ms::LatLon\((-?[\d.]+), (-?[\d.]+)\) location = ms::LatLon\((-?[\d.]+), (-?[\d.]+)\) '
                 r'bearing = (-?[\d.]+)')
CHECKPOINT = re.compile(r'ms::LatLon\((-?[\d.]+), (-?[\d.]+)\)')
# Since LOGFMT 2 (libs/map/nogps/log_line.hpp) a line of the core begins with a head: the tag, the stable name of a
# rule, an action or an event, "ms=<unix ms>" and the key=value pairs, and the free sentence follows: "RULE
# bend_moved ms=1763800000000 kind=bend Bend: moved along the road by 20 m". The tools still read the sentence, so
# read() takes the head off every line and every pattern here and in nogps_log.py is written for the sentence alone,
# as it was before LOGFMT 2. Reading the name and the keys instead is #464.
HEAD_RE = re.compile(r'^(?:RULE|ACTION|EVENT) \w+ (?:\w+=\S+ )+')
# A data line keeps its tag and has only "ms=" after it: "GYRO ms=1763800000000 12.5 …" is read as "GYRO 12.5 …".
DATA_MS_RE = re.compile(r'^([A-Z][A-Z_\d]*) ms=\d+ ')
SLICE_MS = 200
# A break of the box data longer than this is another trip.
MAX_STAND_FILL_MS = 600_000
# A standing car is written once in this time, Engine::kTripLogStandIntervalMs, with a margin.
STAND_TRIP_MS = 35_000
# The car standing before the first data of the box is driven again for this long at most.
MAX_STAND_BEFORE_MS = 15_000
HELD_OUT_DAYS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'nogps_held_out_days.txt')


def held_out_days(path=HELD_OUT_DAYS_FILE):
    """The days (MM-DD) of the held-out set: the lines of the file that are not comments."""
    with open(path, encoding='utf-8') as f:
        return {line.split('#')[0].strip() for line in f} - {''}


def set_of(day, held_out):
    return 'held out' if day in held_out else 'made from'


def trip_days(paths):
    """The seconds of TRIP lines of every day of the logs."""
    counts = collections.Counter()
    for path in paths:
        seen = set()
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                m = LINE.match(line.rstrip('\n'))
                if m and m.group(7) == 'OMcore' and ' TRIP ' in m.group(8) and line not in seen:
                    seen.add(line)
                    counts[m.group(1)] += 1
    return counts


def days(args):
    """Every day of the logs of a phone with its seconds of TRIP lines and its set."""
    held_out = held_out_days()
    counts = trip_days(args.logs)
    for day in sorted(counts):
        print('%s  %6d TRIP lines  %s' % (day, counts[day], set_of(day, held_out)))
    print('held out %d of %d days' % (sum(day in held_out for day in counts), len(counts)))


def sentence(text):
    """The line without the head of LOGFMT 2, see HEAD_RE: the sentence of a rule, an action or an event, a data
    line with its tag and without its "ms=", and any other line as it is."""
    m = HEAD_RE.match(text)
    if m:
        return text[m.end():]
    return DATA_MS_RE.sub(r'\1 ', text, count=1)


def read(paths, day):
    """The lines of the core of the day: the TRIP lines as dictionaries, the others as (ms of the day, text, the
    function that has written it), and when the application was started."""
    seen = set()
    trips = []
    others = []
    started = []
    for path in paths:
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                if not line.startswith(day):
                    continue
                m = LINE.match(line.rstrip('\n'))
                if not m or line in seen:
                    continue
                seen.add(line)
                ms = ((int(m.group(2)) * 60 + int(m.group(3))) * 60 + int(m.group(4))) * 1000 + int(m.group(5))
                body = m.group(8)
                if m.group(7) != 'OMcore':
                    if 'initNativePlatform()' in body:
                        started.append(ms)
                    continue
                source = SOURCE.match(body)
                function, text = (source.group(1), source.group(2)) if source else ('', body)
                text = sentence(text)
                if text.startswith('TRIP '):
                    fields = dict(FIELD.findall(' ' + text))
                    fields['ms'] = ms
                    trips.append(fields)
                else:
                    others.append((ms, text, function))
    trips.sort(key=lambda f: f['ms'])
    others.sort(key=lambda x: x[0])
    return trips, others, sorted(set(started))


def logged_map_versions(others):
    """The map versions of the first MAPS line of the day's lines (newest first), or [] when it has none or no maps."""
    for _, text, _ in others:
        m = MAPS_LINE.match(text)
        if m:
            return [] if m.group(1) == '-' else m.group(1).split(',')
    return []


def tool_map_version(data_path):
    """The map version nogps_replay_tool drives on, as it picks it (libs/map/nogps_replay_tool/main.cpp): the newest
    all-digit subfolder of |data_path|, else |data_path| itself when its name is all digits, else None."""
    try:
        names = [n for n in os.listdir(data_path) if n.isdigit() and os.path.isdir(os.path.join(data_path, n))]
    except OSError:
        names = []
    if names:
        return str(max(int(n) for n in names))
    name = os.path.basename(os.path.abspath(data_path))
    return name if name.isdigit() else None


def wrong_maps(args, others):
    """Why the day is not driven on --data_path, or None: its log says the maps of other versions."""
    if args.any_maps:
        return None
    logged = logged_map_versions(others)
    if not logged:
        return None
    version = tool_map_version(args.data_path)
    if version is None:
        return ('the version of --data_path is not known (name its folder by the version, as 260714) and the log '
                'has %s: --any-maps drives it anyway' % ','.join(logged))
    if version not in logged:
        return 'the log was driven on maps %s and --data_path has %s: --any-maps drives it anyway' % (
            ','.join(logged), version)
    return None


def number(fields, name, default=None):
    value = fields.get(name)
    if value is None:
        return default
    try:
        return float(value.split('/')[0])
    except ValueError:
        return default


def lat_lon(value):
    try:
        lat, lon = value.split('/')[0].split(',')
        return float(lat), float(lon)
    except (ValueError, AttributeError):
        return None


def clock(ms):
    return '%02d:%02d:%02d' % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60)


def parse_clock(text):
    parts = [int(p) for p in text.split(':')]
    while len(parts) < 3:
        parts.append(0)
    return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000


def slices_of(lines, parse):
    """The parts of the seconds of GYRO or ACCB lines: (the end of the part in ms, its duration, the values)."""
    result = []
    previous_end = None
    for end, values in lines:
        duration = SLICE_MS
        # The box counts the parts by its own samples: they are a bit longer than 200 ms of the phone.
        if previous_end is not None and 900 <= end - previous_end <= 1300:
            duration = (end - previous_end) / len(values)
        previous_end = end
        for i, value in enumerate(values):
            parsed = parse(value)
            if parsed is not None:
                result.append((end - (len(values) - 1 - i) * duration, duration, parsed))
    return result


def moves_by(fields):
    """The core writes a TRIP line every second while the car moves by the box or by GPS, see Engine::LogTrip."""
    if number(fields, 'speed', 0) > 0:
        return True
    for source in ('gps', 'fused'):
        try:
            if float(fields.get(source, '').split('/')[2]) >= 3:
                return True
        except (ValueError, IndexError):
            pass
    return False


# The values of a CALIBRATION line the replay takes. The unit is left out: the GYRO lines carry the car speed the
# phone has already multiplied by it, a replay that took it would multiply it again.
CALIBRATION_KEYS = ('scale', 'table', 'rough', 'factor', 'lag', 'accel')


def car_calibration(others, first, data_start):
    """The record "K <ms> car=<id> key=value..." of the last CALIBRATION line the log wrote before the box data of
    the file begins (the car still stands then, and the lines after the box connects come in that time), or None.
    The file begins at |first|; a line of the day before it is the state the car was left in. What the line does
    not carry is not in the record: the car has not learned it, and the replay takes the default."""
    lines = [(ms, text) for ms, text, _ in others if text.startswith('CALIBRATION ') and ms <= data_start]
    if not lines:
        return None
    fields = dict(FIELD.findall(' ' + lines[-1][1]))
    if 'car' not in fields:
        return None
    parts = ['car=' + fields['car']] + ['%s=%s' % (k, fields[k]) for k in CALIBRATION_KEYS if k in fields]
    return 'K %d %s' % (first, ' '.join(parts))


def make_input(args):
    trips, others, started = read(args.logs, args.day)
    start = parse_clock(args.start) if args.start else 0
    end = parse_clock(args.end) if args.end else 86_400_000

    gyro_lines = []
    accel_lines = []
    # What the application and the user did: (ms, order at the same time, the record, done by the user).
    actions = [(ms, 0, 'S %d 2' % ms, False) for ms in started]
    total_before = None
    by_itself_ms = None
    # The routes: (ms, the points the user asked a route through or None, the route is followed or closed).
    routes = []
    asked_ms = None
    # Where the application started anew has found the car it kept: (ms, the kept car as it was written).
    restores = []
    for ms, text, function in others:
        if text.startswith('GYRO '):
            parts = text.split()
            deltas = [float(p) for p in parts[2:7]]
            speeds = [int(p) for p in parts[7:12]]
            if len(deltas) != 5 or len(speeds) != 5:
                continue
            # The parts are rounded to 0.01 degrees and the total is not: what the rounding has lost in a second
            # is given back, so the heading doesn't drift over an hour.
            total = float(parts[1])
            if gyro_lines and 900 <= ms - gyro_lines[-1][0] <= 1300 and total_before is not None:
                lost = total - total_before - sum(deltas)
                if abs(lost) <= 0.2:
                    deltas = [d + lost / 5 for d in deltas]
            # What the car has rotated since the previous line, if a line between them is lost.
            between = total - sum(deltas) - total_before if total_before is not None else 0
            total_before = total
            gyro_lines.append((ms, [(d, v, between if i == 0 else 0) for i, (d, v) in enumerate(zip(deltas, speeds))]))
        elif text.startswith('ACCB_BEFORE '):
            parts = text.split()
            accel_lines.append((ms - int(parts[1]) * 1000, parts[2:7]))
        elif text.startswith('ACCB '):
            accel_lines.append((ms, text.split()[1:6]))
        elif function == 'Start' and text == 'Start':
            actions.append((ms, 1, 'S %d 1' % ms, False))
        elif function == 'Stop' and text == 'Stop':
            actions.append((ms, 1, 'S %d 0' % ms, False))
        elif function == 'OnBleState' and text.startswith('Bluetooth = '):
            # The connection that probes a pairing thought lost is no link: the flag is written since #474, and the
            # logs of the trips driven before it have no field for it.
            lost = '1' if text.endswith('bond lost = 1') else '0'
            actions.append((ms, 2, 'L %d %s %s' % (ms, text.split()[2], lost), False))
        elif function == 'OnInfo' and BOX_INFO.match(text):
            actions.append((ms, 2, 'I %d %s' % (ms, BOX_INFO.match(text).group(1)), False))
        elif function == 'SetGpsDisabled' and GPS_OFF.match(text):
            actions.append((ms, 3, 'X %d %s' % (ms, GPS_OFF.match(text).group(1)), False))
        elif text.startswith('Entering the manual mode') or text.startswith('GPS is trusted again'):
            by_itself_ms = ms
        elif function == 'SetManualMode' and MANUAL.match(text):
            # The navigation turns the manual mode on and off by itself too, and does it again here.
            if by_itself_ms is None or ms - by_itself_ms > 5:
                actions.append((ms, 3, 'A %d %s' % (ms, MANUAL.match(text).group(1)), False))
        elif text.startswith('tap = '):
            m = TAP.search(text)
            if m:
                actions.append((ms, 6, 'T %d %s %s' % (ms, m.group(1), m.group(2)), True))
                actions.append((ms, 6, 'H %d %s' % (ms, m.group(5)), True))
        elif function == 'RestoreCarPosition' and text.startswith('The car is where it was left = '):
            restores.append((ms, text.split(' = ', 1)[1].split(',')))
        elif text.startswith('Reversed the car'):
            actions.append((ms, 6, 'R %d' % ms, True))
        elif function == 'SwitchMark' and text == 'Switching the mark':
            actions.append((ms, 6, 'W %d' % ms, True))
        elif text.startswith('Moved the position by'):
            m = re.match(r'Moved the position by (-?[\d.]+)', text)
            if m:
                actions.append((ms, 6, 'M %d %s' % (ms, m.group(1)), True))
        elif text.startswith('paused = '):
            actions.append((ms, 6, 'P %d %s' % (ms, text.split()[2]), True))
        elif function == 'SetState' and text.startswith('Routing session state: '):
            # A route the user asks for is built, a route the car has left is rebuilt: the latter is done again by
            # the route of the trip driven again.
            state = text.split()[-1]
            if state == 'RouteBuilding':
                asked_ms = ms
            elif state == 'NoValidRoute':
                routes.append((ms, None, False))
        elif function == 'CalculateRoute' and text.startswith('Calculating the route') and asked_ms is not None:
            points = CHECKPOINT.findall(text.split('startDirection')[0])
            if len(points) >= 2 and ms - asked_ms <= 5000:
                routes.append((asked_ms, points, False))
            asked_ms = None
        elif function == 'EnableFollowMode' and text.split()[-1] in ('OnRoute', 'RouteNotStarted'):
            routes.append((ms, None, True))
    if args.no_route:
        routes = []
    for ms, points, follow in routes:
        if points:
            actions.append((ms, 7, 'N %d %s' % (ms, ' '.join('%s %s' % p for p in points)), False))
        else:
            actions.append((ms, 7, 'F %d %d' % (ms, follow), False))

    # GPS as the application has seen it, a position a second. What it has told to be spoofed is left out: it is
    # told so by the network positions, which are not driven again.
    def optional(text, scale):
        try:
            return '%.2f' % (float(text) * scale)
        except ValueError:
            return '-'

    fix_ms = None
    # The last GPS position given and the number of the TRIP line it is from.
    last_fix = None
    # GPS changed or the application started anew while the car stood: GPS did not go on as it was.
    breaks = sorted([ms for ms, text, _ in others if text.startswith('GPS signal ')] + started)
    for k, f in enumerate(trips):
        value = f.get('gps')
        if not value or f.get('spoofed') == '1':
            continue
        parts = value.split('/')
        position = lat_lon(value)
        try:
            accuracy = float(parts[1])
            age = float(parts[4])
        except (ValueError, IndexError):
            continue
        at = f['ms'] - age * 1000
        if position is None or age > 1.05 or (fix_ms is not None and at - fix_ms < 300):
            continue
        fix_ms = at
        # The accuracy of the bearing tells if a slow car takes its heading from GPS. Older logs don't have it:
        # the car looking where GPS did has taken it.
        if len(parts) > 5:
            bearing_accuracy = optional(parts[5], 1)
        else:
            bearing_accuracy = '-'
            try:
                took = abs((float(parts[3]) - number(f, 'hdg', 1e9) + 180) % 360 - 180) <= 6
                if took and f.get('hdg', '').endswith('/GPS'):
                    bearing_accuracy = '5.00'
            except ValueError:
                pass
        rest = '%.6f %.6f %.1f %s %s %s' % (position[0], position[1], accuracy, optional(parts[2], 1 / 3.6),
                                           optional(parts[3], 1), bearing_accuracy)
        # A standing car is written once in STAND_TRIP_MS: GPS has given the same position every second meanwhile,
        # a pause would be GPS lost.
        if (last_fix and last_fix[1] == k - 1 and 1500 < f['ms'] - trips[k - 1]['ms'] <= STAND_TRIP_MS and
                not moves_by(trips[k - 1]) and
                bisect.bisect_right(breaks, trips[k - 1]['ms']) == bisect.bisect_left(breaks, f['ms'])):
            fill = last_fix[0] + 1000
            while fill < at - 500:
                actions.append((fill, 4, 'G %d %s' % (round(fill), last_fix[2]), False))
                fill += 1000
        last_fix = (at, k, rest)
        actions.append((at, 4, 'G %d %s' % (round(at), rest), False))
    accel_lines.sort(key=lambda x: x[0])

    def accel_value(text):
        try:
            h1, h2, up, jolt = [float(v) for v in text.split(',')]
        except ValueError:
            return None
        return round(h1 * 1000), round(h2 * 1000), round(up * 1000), round(jolt * 1000)

    gyro = slices_of(gyro_lines, lambda v: v)
    accel = slices_of(accel_lines, accel_value)
    accel_times = [a[0] for a in accel]
    trip_times = [f['ms'] for f in trips]
    # The car kept is given with the start that has found it, as old as the first trip line after it tells.
    for ms, kept in restores:
        opened = max((s for s in started if ms - 10_000 <= s <= ms), default=None)
        if opened is None or len(kept) != 5:
            continue
        i = bisect.bisect_left(trip_times, ms)
        age = next((number(f, 'markAge') * 1000 - (f['ms'] - ms) for f in trips[i:i + 5] if 'markAge' in f), 0)
        actions.append((opened, 0, 'C %d %s %s %s %s %d' % (opened, kept[0], kept[1], kept[2], kept[3], max(0, age)),
                        False))

    def accel_at(ms, window):
        i = bisect.bisect_left(accel_times, ms)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(accel) and (best is None or abs(accel[j][0] - ms) < abs(best[0] - ms)):
                best = accel[j]
        return best[2] if best and abs(best[0] - ms) <= window else None

    def accel_field(ms):
        """The acceleration of the part nearest in 3 s. Its jolt only if the part is of this time: a part taken for
        other times too would drive one hit of a pothole again."""
        a = accel_at(ms, 3000)
        if not a:
            return '-'
        return '%d %d %d %d' % (a[:3] + (a[3] if accel_at(ms, 150) else 0,))

    def flags_at(ms):
        i = bisect.bisect_right(trip_times, ms) - 1
        return trips[i].get('bf', '17') if i >= 0 else '17'

    def stands(from_ms, to_ms):
        """The application was running and the box was heard all the time: the car stood, a second it moves or
        rotates in is written. A standing car has a TRIP line once in STAND_TRIP_MS, every second in older logs."""
        rows = trips[bisect.bisect_left(trip_times, from_ms):bisect.bisect_right(trip_times, to_ms)]
        times = [from_ms] + [f['ms'] for f in rows] + [to_ms]
        return ((rows or to_ms - from_ms <= 1250) and all(b - a <= STAND_TRIP_MS for a, b in zip(times, times[1:])) and
                all(number(f, 'speed', -1) >= 0 and f.get('src') != 'GPS' for f in rows))

    def speed_at(ms):
        """The speed of the nearest trip line. A second of the box is not written when the car reports 0 at its end:
        the faster of the lines around drove on a car that stood, on October 18 at 21:23:30 a stand of 1.5 s was
        driven again as 0.4 s."""
        i = bisect.bisect_right(trip_times, ms)
        rows = [f for f in trips[max(0, i - 1):i + 1] if abs(f['ms'] - ms) <= 1500]
        nearest = min(rows, key=lambda f: abs(f['ms'] - ms), default=None)
        return int(number(nearest, 'speed', 0)) if nearest else 0

    records = []  # (ms, order at the same time, text)
    previous = None
    for at, duration, (delta, speed, between) in gyro:
        if not (start <= at <= end):
            continue
        gap = at - duration - previous if previous is not None else None
        if gap is None or gap > MAX_STAND_FILL_MS or (gap > 2 * SLICE_MS and not stands(previous, at - duration)):
            # Nothing has come from the box meanwhile. Then the car stood for some seconds before it moved: a
            # standing car is not written, but how long it stood tells which way it starts.
            begin = at - duration
            i = bisect.bisect_right(trip_times, begin) - 1
            while (i >= 0 and begin - trips[i]['ms'] <= MAX_STAND_BEFORE_MS and trips[i].get('speed') == '0' and
                   (previous is None or trips[i]['ms'] > previous)):
                i -= 1
            stood_from = trips[i + 1]['ms'] if i + 1 < len(trips) and trips[i + 1]['ms'] < begin else begin
            # A standing car is written seldom: it has stood since a line of 0 km/h before.
            if (i >= 0 and trips[i].get('speed') == '0' and 1500 < stood_from - trips[i]['ms'] <= STAND_TRIP_MS and
                    (previous is None or trips[i]['ms'] > previous)):
                stood_from = min(stood_from, max(trips[i]['ms'], begin - MAX_STAND_BEFORE_MS))
            records.append((stood_from, 5, 'J %d' % round(stood_from)))
            count = round((begin - stood_from) / SLICE_MS)
            for k in range(count):
                t = stood_from + (begin - stood_from) * (k + 1) / count
                records.append((t, 5, 'B %d %d 0 0 %s %s' % (round(t), round((begin - stood_from) / count),
                                                             flags_at(t), accel_field(t))))
        elif gap > SLICE_MS / 2:
            # Nothing is written about the box while the car stands. A second of a driving car is lost from the
            # log now and then: the car has driven on with the speed of the trip line of that second, and has
            # rotated as much as the total rotation tells.
            count = max(1, round(gap / SLICE_MS))
            moves = gap <= 10_000 and any(speed_at(previous + gap * (i + 1) / count) > 0 for i in range(count))
            for i in range(count):
                t = previous + gap * (i + 1) / count
                records.append((t, 5, 'B %d %d %d %d %s %s' % (
                    round(t), round(gap / count), round(between * 1000 / count) if moves else 0,
                    speed_at(t) if moves else 0, flags_at(t), accel_field(t))))
        records.append((at, 5, 'B %d %d %d %d %s %s' % (round(at), round(duration), round(delta * 1000), speed,
                                                        flags_at(at), accel_field(at))))
        previous = at
    if not records:
        print('no box data in the logs of', args.day)
        return
    first = round(records[0][0]) - 1000
    # The file begins when the application was started before that, if it was that day: with all it was given since.
    if any(start <= ms <= first for ms in started):
        first = max(ms for ms in started if start <= ms <= first)

    # The box data only: the start of the application of the file is not counted in.
    data_start = min(r[0] for r in records)
    for ms, order, text, by_user in actions:
        if first <= ms <= end and not (by_user and args.no_taps):
            records.append((ms, order, text))

    calibration = car_calibration(others, first, data_start)
    if calibration:
        # Before the start of the application: the engine reads it from the storage when it is made.
        records.append((first, -5, calibration))
    args.calibration_source = 'log %s' % calibration.split()[2][len('car='):] if calibration else 'settings'
    # What the navigation was like when the file begins, unless the application is started right then.
    if not any(first <= ms <= first + 10_000 for ms in started):
        i = min(bisect.bisect_left(trip_times, first), len(trips) - 1)
        state = trips[i] if trips else {}
        position = lat_lon(state.get('pos'))
        heading = number(state, 'hdg')
        # A tap would put the car standing off the roads on a road, looking along it: on October 19 and 23 it stood
        # across its road in the yard, and the trip driven again went the other way. It is started as the
        # application keeps it then.
        kept = state.get('src') in ('MANUAL', 'INERTIAL') and position and state.get('road') == '0'
        records.append((first, -4, 'S %d 2' % first))
        if kept:
            records.append((first, -4, 'C %d %.6f %.6f %s 1 %d' % (
                first, position[0], position[1], '-' if heading is None else '%.1f' % heading,
                round(number(state, 'markAge', 0) * 1000))))
        records.append((first, -3, 'S %d 1' % first))
        if state.get('link', '').endswith('/CONNECTED'):
            # The trip line tells the state and not the flag: it is the one of the last state written before.
            lost = [r[2].split()[-1] for r in actions if r[2].startswith('L ') and r[0] <= first]
            records.append((first, -3, 'L %d CONNECTED %s' % (first, lost[-1] if lost else '0')))
            # The box the application has heard before the file begins.
            box = [BOX_INFO.match(text).group(1) for ms, text, function in others
                   if function == 'OnInfo' and ms <= first and BOX_INFO.match(text)]
            if box:
                records.append((first, -3, 'I %d %s' % (first, box[-1])))
        # GPS switched off stays so: since the choice is kept after a restart too. On October 19 it was switched off
        # the day before, and the first GPS position came minutes after the file begins.
        disabled = None
        for ms, text, function in others:
            if function == 'SetGpsDisabled' and ms <= first and GPS_OFF.match(text):
                disabled = GPS_OFF.match(text).group(1) == '1'
            elif disabled is None and ms >= first and function == 'SetGpsDisabled':
                break
            elif disabled is None and ms >= first and text.startswith('GPS is disabled, ignoring'):
                disabled = True
        if disabled:
            records.append((first, -2, 'X %d 1' % first))
        if state.get('src') in ('MANUAL', 'INERTIAL') and position and not kept:
            records.append((first, -1, 'A %d 1' % first))
            records.append((first, -1, 'T %d %.6f %.6f' % (first, position[0], position[1])))
            if heading is not None:
                records.append((first, -1, 'H %d %.0f' % (first, heading)))
        # The route the car follows when the file begins is asked for from where the car is.
        asked = None
        followed = False
        for ms, points, follow in routes:
            if ms >= first:
                break
            if points:
                asked, followed = points, False
            elif follow:
                followed = asked is not None
            else:
                asked = None
        if asked and position:
            there = ' '.join('%s %s' % p for p in asked[1:])
            records.append((first, 0, 'N %d %.6f %.6f %s' % (first, position[0], position[1], there)))
            if followed:
                records.append((first, 1, 'F %d 1' % first))

    records.sort(key=lambda r: (r[0], r[1]))
    with open(args.output, 'w', encoding='ascii', newline='\n') as f:
        f.write('D %s%s\n' % (args.day, ' fresh' if getattr(args, 'fresh', False) else ''))
        for _, _, text in records:
            f.write(text + '\n')
    kinds = collections.Counter(r[2][0] for r in records)
    print('written %s: %.1f h of the box in %d pieces, GPS %d, taps %d, reverse %d, pause %d, moved %d, '
          'GPS switched %d, manual mode %d, starts %d, routes asked for %d' % (
              args.output, kinds['B'] * SLICE_MS / 3.6e6, kinds['J'], kinds['G'], kinds['T'], kinds['R'], kinds['P'],
              kinds['M'], kinds['X'], kinds['A'], kinds['S'], kinds['N']))


def meters(a, b):
    north = (a[0] - b[0]) * 111320.0
    east = (a[1] - b[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(north, east)


class GpsTrack:
    """GPS of the trip, to tell where the car was at any moment."""

    def __init__(self, trips):
        points = {}
        for f in trips:
            value = f.get('gps')
            if not value or f.get('spoofed') == '1':
                continue
            parts = value.split('/')
            position = lat_lon(value)
            try:
                accuracy = float(parts[1])
                age = float(parts[4])
            except (ValueError, IndexError):
                continue
            if position is None or accuracy > 12 or age > 2.5:
                continue
            points[round(f['ms'] - age * 1000)] = position
        self.times = sorted(points)
        self.points = [points[t] for t in self.times]

    def at(self, ms):
        i = bisect.bisect_left(self.times, ms)
        if i == 0 or i == len(self.times):
            return None
        t0, t1 = self.times[i - 1], self.times[i]
        if t1 - t0 > 2500:
            return None
        k = (ms - t0) / (t1 - t0)
        a, b = self.points[i - 1], self.points[i]
        return a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k


def error_stats(errors):
    """The median, 90% and shares over 30, 50 and 100 m of the distances from GPS, None without any."""
    if not errors:
        return None
    errors = sorted(errors)
    n = len(errors)
    return dict(n=n, median=errors[n // 2], p90=errors[n * 9 // 10],
                over30=100 * sum(e > 30 for e in errors) / n, over50=100 * sum(e > 50 for e in errors) / n,
                over100=100 * sum(e > 100 for e in errors) / n)


def summary(name, stats):
    if not stats:
        print('%-22s no seconds with GPS' % name)
        return
    print('%-22s %5d s  median %4.0f m  90%% %4.0f m  over 30 m %4.1f%%  over 50 m %4.1f%%  over 100 m %4.1f%%' % (
        name, stats['n'], stats['median'], stats['p90'], stats['over30'], stats['over50'], stats['over100']))


EVENTS = [
    # Before October 16 the car followed apart was "paused by itself".
    ('road lost', r'road is lost after'), ('followed apart off the roads', r'paused by itself|it is followed apart'),
    ('mark waited ahead at a bend', r'road goes away .* the mark is ahead, it waits'),
    ('mark waited ahead at a roundabout', r'come to a roundabout before the car'),
    ('mark put on a road past a roundabout', r'road past the roundabout'),
    ('turn moved to a crossing', r'is moved to the crossing'), ('turn not at a crossing', r'is not at a crossing'),
    ('roundabout or winding road', r'roundabout or a winding'), ('off the roads at a roundabout', r'at a roundabout'),
    ('started backward', r'has started backward'), ('way of a start changed', r'by the accelerometer, it has felt'),
    ('mark moved to the road of the car', r'the mark is put on the road going its way'),
    ('no road at the tap', r'^No road at the tap'), ('bend moved', r'^Bend: moved'),
    ('bend told nothing', r'^Bend: tells nothing'),
    ('gentle bend moved', r'^Gentle bend: moved'),
    ('gentle bend told nothing', r'^Gentle bend: tells nothing'),
    ('seconds on another branch of a fork', r'^FORK '),
    ('route asked for', r'Routing session state: \w+ -> RouteBuilding'),
    ('route rebuilt: the car left it', r'Routing session state: RouteNeedRebuild -> RouteRebuilding'),
    ('route rebuilt: the mark put off it', r'^Manual position is off the route'),
    ('route left: the car on a road beside it', r'beside the route, the route is left'),
    ('alternative route followed', r'is on the alternative route'),
    # A turn that fits several roads splits the mark, since October 17.
    ('other mark added', r'^Other mark added'), ('other mark dropped', r'^Other mark dropped'),
    ('mark switched to another road', r'^The car is shown on another road'),
    ('turn place told by the way driven', r'^Turn from .* WAY misses'),
]


def compare_stats(trips, others, replayed, replayed_others, start, end, change):
    """The trip against the trip driven again from |start| to |end|, ms of the day, as read() gives them."""
    gps = GpsTrack(trips)

    def errors_of(rows):
        result = {}
        for f in rows:
            if not (start <= f['ms'] <= end) or f.get('src') != 'INERTIAL' or number(f, 'speed', 0) <= 0:
                continue
            position = lat_lon(f.get('pos'))
            truth = gps.at(f['ms'])
            if position and truth:
                result[f['ms'] // 1000] = meters(position, truth)
        return result

    was = errors_of(trips)
    now = errors_of(replayed)
    both = sorted(set(was) & set(now))
    stats = dict(lines=len(replayed), trip_lines=len(trips), errors=[
        ('the trip, all', error_stats(list(was.values()))),
        ('the trip, same seconds', error_stats([was[s] for s in both])),
        ('driven again', error_stats([now[s] for s in both]))])
    stats['seconds'] = [(was[s], now[s]) for s in both]

    # The mark of the trip against the mark driven again, GPS or not.
    original = {f['ms'] // 1000: lat_lon(f.get('pos')) for f in trips if f.get('src') == 'INERTIAL'}
    apart = []
    for f in replayed:
        a, b = original.get(f['ms'] // 1000), lat_lon(f.get('pos'))
        if a and b and number(f, 'speed', 0) > 0 and start <= f['ms'] <= end:
            apart.append(meters(a, b))
    stats['apart'] = error_stats(apart)

    stats['events'] = []
    for name, pattern in EVENTS:
        rx = re.compile(pattern)
        a = sum(1 for ms, text, _ in others if start <= ms <= end and rx.search(text))
        b = sum(1 for ms, text, _ in replayed_others if start <= ms <= end and rx.search(text))
        stats['events'].append((name, a, b))
    for name, key in (('seconds stopped as lost', 'lost'), ('seconds followed apart', 'self'),
                      ('seconds paused', 'paused')):
        a = sum(1 for f in trips if start <= f['ms'] <= end and f.get(key) == '1' and number(f, 'speed', 0) > 0)
        b = sum(1 for f in replayed if start <= f['ms'] <= end and f.get(key) == '1' and number(f, 'speed', 0) > 0)
        stats['events'].append((name, a, b))

    # Where it has changed: the stretches the mark driven again is much closer to GPS or much farther from it.
    stretches = []
    current = None
    for s in both:
        difference = now[s] - was[s]
        kind = 'better' if difference < -change else 'worse' if difference > change else None
        if kind and current and current['kind'] == kind and s - current['to'] <= 3:
            current['to'] = s
            current['was'].append(was[s])
            current['now'].append(now[s])
        elif kind:
            current = dict(kind=kind, start=s, to=s, was=[was[s]], now=[now[s]])
            stretches.append(current)
        else:
            current = None
    stats['stretches'] = [dict(kind=x['kind'], start=x['start'], to=x['to'], was=max(x['was']), now=max(x['now']))
                          for x in stretches if x['to'] - x['start'] >= 2]
    return stats


def compare(args):
    trips, others, _ = read(args.logs, args.day)
    replayed, replayed_others, _ = read([args.replay], args.day)
    start = parse_clock(args.start) if args.start else 0
    end = parse_clock(args.end) if args.end else 86_400_000
    if not replayed:
        print('nothing is driven again in', args.replay)
        return
    print_compare(compare_stats(trips, others, replayed, replayed_others, start, end, args.change), args.day,
                  args.change)


def print_compare(stats, day, change):
    print('the day %s (%s), driven again: %d s of TRIP lines, the trip had %d' % (
        day, set_of(day, held_out_days()), stats['lines'], stats['trip_lines']))
    for name, errors in stats['errors']:
        summary(name, errors)
    apart = stats['apart']
    if apart:
        print('the two marks apart:   median %.0f m, 90%% %.0f m, over 30 m %.1f%% of %d s' % (
            apart['median'], apart['p90'], apart['over30'], apart['n']))

    print('%-34s %8s %8s' % ('', 'the trip', 'again'))
    for name, a, b in stats['events']:
        print('%-34s %8d %8d' % (name, a, b))

    stretches = stats['stretches']
    print('stretches of 3 s or longer changed by more than %d m: better %d (%d s), worse %d (%d s)' % (
        change, sum(x['kind'] == 'better' for x in stretches),
        sum(x['to'] - x['start'] + 1 for x in stretches if x['kind'] == 'better'),
        sum(x['kind'] == 'worse' for x in stretches),
        sum(x['to'] - x['start'] + 1 for x in stretches if x['kind'] == 'worse')))
    for x in stretches:
        print('  %s %3d s %-6s  the trip %4.0f m, again %4.0f m from GPS at the worst' % (
            clock(x['start'] * 1000), x['to'] - x['start'] + 1, x['kind'], x['was'], x['now']))


def run_day(args, day):
    """Makes the input of the day, drives it with the tool and compares it with the trip: the compare of the day and
    the seconds the tool took, or None and what went wrong."""
    base = os.path.join(args.output, day)
    trips, others, _ = read(args.logs, day)
    wrong = wrong_maps(args, others)
    if wrong:
        return day, None, wrong, None
    day_args = argparse.Namespace(logs=args.logs, day=day, start=args.start, end=args.end, output=base + '-in.txt',
                                  no_taps=args.no_taps, no_route=args.no_route, fresh=args.fresh)
    with contextlib.redirect_stdout(io.StringIO()):
        make_input(day_args)
    source = getattr(day_args, 'calibration_source', None)
    if not os.path.exists(day_args.output):
        return day, None, 'no box data', source
    out = base + '-out.txt'
    command = [args.tool, '--data_path', args.data_path, '--resources_path', args.resources_path]
    if args.settings:
        command += ['--settings', args.settings]
    started = time.monotonic()
    with open(base + '-tool.log', 'w') as log:
        code = subprocess.run(command + [day_args.output, out], stdout=log, stderr=subprocess.STDOUT).returncode
    seconds = time.monotonic() - started
    # A day the tool has not driven to the end is not compared: the other days are.
    if code != 0 or not os.path.exists(out + '.done'):
        return day, None, 'the tool has not driven it to the end, exit code %d: see %s-tool.log' % (code, base), source
    replayed, replayed_others, _ = read([out], day)
    start = parse_clock(args.start) if args.start else 0
    end = parse_clock(args.end) if args.end else 86_400_000
    stats = compare_stats(trips, others, replayed, replayed_others, start, end, args.change)
    with open(base + '-compare.txt', 'w') as f, contextlib.redirect_stdout(f):
        print_compare(stats, day, args.change)
    return day, stats, seconds, source


def warn_builds(paths):
    """Tells on stderr when the logs were written by builds of other commits than the checkout of this script: the
    mark of the trip then came from other rules than the replay has."""
    here = subprocess.run(['git', '-C', os.path.dirname(os.path.abspath(__file__)), 'rev-parse', '--short=8', 'HEAD'],
                          capture_output=True, text=True)
    if here.returncode != 0:
        return
    commits = set()
    for path in nogps_trip_log.log_files(paths):
        try:
            commit = nogps_trip_log.read_header(path).get('commit')
        except nogps_trip_log.LogFormatError:
            continue
        if commit:
            commits.add(commit[:8])
    others = sorted(commits - {here.stdout.strip()})
    if others:
        print('note: the logs are of the builds %s, this checkout is %s: the "trip" columns are of those rules' % (
            ', '.join(others), here.stdout.strip()), file=sys.stderr)


def run(args):
    """Drives the days with nogps_replay_tool, a few at a time, and prints a line of compare a day."""
    os.makedirs(args.output, exist_ok=True)
    held_out = held_out_days()
    days_to_run = sorted(set(args.day) if args.day else trip_days(args.logs))
    warn_builds(args.logs)
    started = time.monotonic()
    with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run_day, [args] * len(days_to_run), days_to_run))

    def median_p90(stats):
        return '%5.0f %5.0f' % (stats['median'], stats['p90']) if stats else '    -     -'

    print('%-5s %-9s %6s %11s %11s %11s %9s %6s' % ('day', 'set', 'TRIP s', 'trip m', 'again m', 'apart m',
                                                     'lost', 'tool s'))
    print('%-5s %-9s %6s %11s %11s %11s %9s %6s' % ('', '', '', 'med   90%', 'med   90%', 'med   90%', 'trip/new',
                                                     ''))
    for name in ('held out', 'made from'):
        seconds = []
        count = 0
        for day, stats, tool_seconds, _ in results:
            if set_of(day, held_out) != name:
                continue
            if not stats:
                print('%-5s %-9s %s' % (day, name, tool_seconds))
                continue
            count += 1
            seconds += stats['seconds']
            errors = dict(stats['errors'])
            lost = next((a, b) for event, a, b in stats['events'] if event == 'road lost')
            print('%-5s %-9s %6d %s %s %s %4d/%-4d %6.0f' % (
                day, name, stats['lines'], median_p90(errors['the trip, same seconds']),
                median_p90(errors['driven again']), median_p90(stats['apart']), lost[0], lost[1], tool_seconds))
        if count:
            print('%-15s %6d %s %s   (%d days)' % (
                name + ', all', len(seconds), median_p90(error_stats([was for was, _ in seconds])),
                median_p90(error_stats([now for _, now in seconds])), count))
    # The log wins, the settings only fill what it does not carry.
    print('calibration:', '; '.join('%s %s' % (day, source or '-') for day, _, _, source in results))
    print('driven in %.0f s, the files are in %s' % (time.monotonic() - started, args.output))


LOGS_HELP = 'the trip logs of the application: files or a folder of them, logs or logs/<phone>'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    sub = commands.add_parser('days')
    sub.add_argument('logs', nargs='+', help=LOGS_HELP)
    sub = commands.add_parser('run')
    sub.add_argument('logs', nargs='+', help=LOGS_HELP)
    sub.add_argument('--tool', required=True, help='nogps_replay_tool of a build with optimized C++')
    sub.add_argument('--data_path', required=True, help='the .mwm files of one version, or a folder of them')
    sub.add_argument('--resources_path', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..',
                                                                  'data'), help='the data folder of the repository')
    sub.add_argument('--settings', help='settings.ini of the app: what it has learned about the car')
    sub.add_argument('--day', action='append', help='MM-DD, as the lines of the log begin; all days without it')
    sub.add_argument('--from', dest='start', help='HH:MM[:SS]')
    sub.add_argument('--to', dest='end', help='HH:MM[:SS]')
    sub.add_argument('-j', '--jobs', type=int, default=os.cpu_count(), help='days driven at a time')
    sub.add_argument('-o', '--output', required=True, help='the folder of the files of the run, not for git')
    sub.add_argument('--no-taps', action='store_true', help='only the mark every trip starts with')
    sub.add_argument('--no-route', action='store_true', help='without the routes the user asked for')
    sub.add_argument('--fresh', action='store_true', help='drive the trips as the first ones: no speed scale or '
                                                          'tables from the settings')
    sub.add_argument('--any-maps', action='store_true', help='drive a day logged on maps of another version')
    sub.add_argument('--change', type=float, default=15, help='meters that count as a change')
    for name in ('input', 'compare'):
        sub = commands.add_parser(name)
        sub.add_argument('logs', nargs='+', help=LOGS_HELP)
        sub.add_argument('--day', required=True, help='MM-DD, as the lines of the log begin')
        sub.add_argument('--from', dest='start', help='HH:MM[:SS]')
        sub.add_argument('--to', dest='end', help='HH:MM[:SS]')
        if name == 'input':
            sub.add_argument('-o', '--output', default='nogps-replay-in.txt')
            sub.add_argument('--no-taps', action='store_true', help='only the mark every trip starts with')
            sub.add_argument('--no-route', action='store_true', help='without the routes the user asked for')
            sub.add_argument('--fresh', action='store_true', help='drive the trip as the first one')
        else:
            sub.add_argument('--replay', required=True, help='nogps-replay-out.txt of the application')
            sub.add_argument('--change', type=float, default=15, help='meters that count as a change')
    args = parser.parse_args()
    try:
        by_phone = nogps_trip_log.files_by_phone(args.logs)
    except nogps_trip_log.LogFormatError as e:
        parser.error(str(e))
    if not by_phone:
        parser.error('no .log files in %s' % ', '.join(args.logs))
    if args.command == 'compare' and len(by_phone) > 1:
        parser.error('the logs of %s: compare takes one phone, as it takes one replay' % ', '.join(sorted(by_phone)))
    for phone, paths in sorted(by_phone.items()):
        phone_args = argparse.Namespace(**vars(args))
        phone_args.logs = paths
        if args.command == 'days':
            print('phone', phone)
            days(phone_args)
        elif args.command == 'run':
            print('phone', phone)
            phone_args.output = os.path.join(args.output, phone)
            run(phone_args)
        elif args.command == 'input':
            if len(by_phone) > 1:
                stem, ext = os.path.splitext(args.output)
                phone_args.output = '%s-%s%s' % (stem, phone, ext)
            make_input(phone_args)
        else:
            compare(phone_args)


if __name__ == '__main__':
    main()
