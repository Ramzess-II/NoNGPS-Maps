#!/usr/bin/env python3
"""Reads the logs of NonGPS Maps: splits them into trips and finds the events and the anomalies of each trip, for
nogps_log_viewer.py and as a text report:

  nogps_log.py trips logs.zip
  nogps_log.py trip logs.zip --trip 3
  nogps_log.py state logs.zip --trip 3 --at 18:02:35
  nogps_log.py flags trip-logs/<phone>/<yyyy-MM-dd>
  nogps_log.py --help    for all the commands

Logs:
  Both platforms write a file per launch of the app and per drive, logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log: iOS in
  Documents/, Android in Android/data/<app id>/files/. "Report a bug" sends logs.zip of that folder, "Send logs" of
  the days of the flags: unpacked into one folder, the zips of any phones and days make one tree. The first line of
  a file, LOGFMT, tells its phone, and the path of the file does for the OSLog text of iOS; the logs of each
  platform and phone form a group of their own. A file of another layout, or of a format not known, is skipped with
  a note and refused when no file is left; the names of the earlier versions are not read.
  iOS times are UTC. Android times are the local time of the phone; the year is taken from the header of a file.

A trip is the car driving with stops shorter than STAND_SPLIT_S. The lines of a phone that stands are kept as
stationary trips.

Flags: the flags/ folders of the tree that nogps_logs.py fetch makes, <phone>/<yyyy-MM-dd>/flags/, are read with the
logs of a folder given, and of the day folder of a log file given. A flag goes on the trip of its phone at its time
(Android: the local time of its name; iOS: UTC, from the offset its day's logs tell, see nogps_db.utc_offset_ms), on
the nearest trip within STAND_KEEP_S. A flag whose time is not known, or that is on no trip, is listed by its local
time only.
"""

import bisect
import collections
import csv
import io
import math
import os
import re
import sys
import tempfile
import zipfile
from datetime import datetime, timedelta

import nogps_db
import nogps_rating
import nogps_replay
import nogps_trip_log

ANDROID_LINE = re.compile(r'(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3}) \(([^)]*)\) ([VDIWE])/([^:\s]+): (.*)')
ANDROID_DATETIME = re.compile(r'^Datetime: (\d{4})-(\d\d)')
IOS_LINE = re.compile(r'([DIWEC])\((\d+)\) (\d+\.\d+) (.*)')
IOS_LOCAL_TIME = re.compile(r'Local time: (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \+0000')
# Absolute times in the core lines tell the year of an Android log without its header.
UNIX_MS = re.compile(r'(?:Last trusted position|The car is where it was left) = \S*,(\d{13})\b')
# "nogps/engine.cpp:1526 LogTrip(): text", "Esp32BleTransport.swift:262 centralManagerDidUpdateState(_:): text".
SOURCE = re.compile(r'(\S+\.\w+):(\d+) (.+?)(?:\(\))?: (.*)', re.S)
LAT_LON = re.compile(r'ms::LatLon\((-?[\d.]+), (-?[\d.]+)\)')
LEVELS = {'V': 'D', 'D': 'D', 'I': 'I', 'W': 'W', 'E': 'E', 'C': 'E'}
EPOCH = datetime(1970, 1, 1)
LOG_NAME = re.compile(r'\.(log|zip)$', re.I)
NOT_LOG_NAME = nogps_trip_log.NOT_LOG_NAME
# A pause of the car or of the log this long ends a trip.
STAND_SPLIT_S = 300
# Standing kept before and after a trip.
STAND_KEEP_S = 30
# A pause of TRIP lines this long separates two stationary trips.
TRIP_GAP_S = 60
# Meters closer to GPS or farther from it a replay counts as a change, as nogps_replay.py compare does.
REPLAY_CHANGE_M = 15
# Seconds without a TRIP line shown as an anomaly.
MISSING_TRIP_S = 2.5
# A standing car is written once in this time, Engine::kTripLogStandIntervalMs, with a margin.
STAND_TRIP_S = 35

# The flags of a data line of the box, bit by bit, see libs/map/nogps/esp32_protocol.hpp.
BOX_FLAGS = ['IMU_OK', 'BIAS_OK', 'UP_OK', 'FWD_OK', 'OBD_OK', 'STILL', 'CALIBRATING', 'MOUNT_MOVED', 'REVERSE',
             'OBD_ABSENT', 'ERROR']
BOX_FLAGS_NEEDED = ('IMU_OK', 'BIAS_OK', 'UP_OK')
BOX_FLAGS_BAD = ('MOUNT_MOVED', 'ERROR', 'OBD_ABSENT')

# What a line tells: (category, name, pattern of the text, pattern of "file func" or None). The first that matches
# names the line. The names of nogps_replay.EVENTS are kept, so the counts of the viewer are those of compare.
REPLAY_CATEGORIES = {
    'route asked for': 'route', 'route rebuilt: the car left it': 'route',
    'route rebuilt: the mark put off it': 'route',
    'route left: the car on a road beside it': 'route', 'alternative route followed': 'route',
    'turn moved to a crossing': 'turn', 'turn not at a crossing': 'turn', 'roundabout or winding road': 'turn',
    'turn place told by the way driven': 'turn', 'no road at the tap': 'user',
}
EVENT_KINDS = [
    ('app', 'app started', r'^Initializing application$|started, detected CPU cores', None),
    ('app', 'navigation started', r'^Start$', r'engine\.cpp'),
    ('app', 'navigation stopped', r'^Stop$', r'engine\.cpp'),
    ('app', 'location started', r'^Start updating location', None),
    ('app', 'location stopped', r'^Stop updating location', None),
    ('app', 'location started', r'^$', r'LocationHelper\.java start$'),
    ('app', 'location stopped', r'^$', r'LocationHelper\.java stop$'),
    ('app', 'position mode', r'^newMode = |^MyPositionMode updated', None),
    ('app', 'location status', r'^Location status updated', None),
    ('app', 'background', r'background|the car is parked', r'^(MwmApplication|NoGpsBoxService)\.java '),
    ('app', 'log lines dropped', r'^Dropped \d+ log lines', None),
    ('app', 'notification', r'^EVENT ', None),
    ('app', 'car restored', r'^The car is where it was left', None),
    ('app', 'last trusted position', r'^Last trusted position', None),
    ('state', 'position source', r'^Position source ', None),
    ('state', 'GPS signal', r'^GPS signal ', None),
    ('state', 'box state', r'^Box state ', None),
    ('state', 'box Bluetooth', r'^Box Bluetooth ', None),
    ('state', 'chosen by itself', r'is chosen by itself', None),
    ('state', 'GPS agrees with the box', r'^GPS agrees with the box', None),
    ('user', 'tap', r'^tap = ms::LatLon', None),
    ('user', 'GPS ignored by the user', r'^(GPS ignored by the user|disabled) = ', None),
    ('user', 'box set up by the user', r'^Box set up by the user', None),
    ('user', 'mark switched', r'^Switching the mark', None),
    ('user', 'car reversed', r'^Reversed the car', None),
    ('user', 'mark moved', r'^Moved the position by', None),
] + [(REPLAY_CATEGORIES.get(name, 'road'), name, pattern, None) for name, pattern in nogps_replay.EVENTS] + [
    ('road', 'not followed apart any more', r'is not followed apart any more', None),
    ('road', 'back on a road', r'drives along a road again', None),
    ('road', 'put on a road', r'it is put there$', None),
    ('road', 'bend', r'^Bend: ', None),
    ('road', 'gentle bend', r'^Gentle bend: ', None),
    ('road', 'loop', r'^Loop: ', None),
    ('road', 'other marks dropped', r'^Other marks? (dropped|not added)', None),
    ('road', 'car started', r'^The car has started', None),
    ('road', 'car drives fast', r'^The car drives fast', None),
    ('road', 'no road its way', r'no road goes its way', None),
    ('road', 'speed table', r'^(Rough speed table|Speed table|Speed factor)', None),
    ('road', 'corrected', r'^Corrected by', None),
    ('turn', 'turn', r'^TURN |^Turn from|^The turn starts', None),
    ('turn', 'no road after the turn', r'^No road after the turn', None),
    ('turn', 'marked while turning', r'is marked while it turns', None),
    ('turn', 'gyroscope against GPS', r'^The gyroscope turns the car', None),
    ('box', 'box event', r'^Box event #', None),
    ('box', 'box restarted', r'^The box has restarted', None),
    ('box', 'box', r'^Box \S+ firmware = |^ESP32 (started|stopped)|^esp32 = |^address = |^armed = ', None),
    ('box', 'Bluetooth', r'^Bluetooth = ', None),
    ('box', 'OBD state', r'^OBD state = |^ELM327|^Connected to', None),
    ('box', 'gyroscope not calibrated', r'gyroscope is not calibrated', None),
    ('box', 'car calibration', r'^CALIBRATION ', None),
    ('box', 'calibration', r'^Calibrat|calibrat', None),
    ('box', 'box accelerometer', r'^BOXACC |accelerometer of the box|accelerometer was learned', None),
    ('box', 'firmware', r'[Ff]irmware|sending again', None),
    ('box', 'box link', r'', r'^Esp32|^NoGpsBox'),
    ('route', 'routing state', r'^Route state = |^Routing session state|following mode|^\[[SB]\] State', None),
    ('route', 'route calculation', r'^Calculating the route|^ROUTE ', None),
    ('route', 'routing', r'', r'^RoutingController'),
    ('gps', 'GPS spoofed', r'^GPS spoofed', None),
    ('gps', 'untrusted location', r'^Untrusted location|^Unsatisfied accuracy', None),
    ('gps', 'GPS off the roads', r'^GPS (has left|is off) the roads', None),
    ('gps', 'network location', r'[Nn]etwork (location|points)', None),
    ('gps', 'location ignored', r'^Not active, ignoring', None),
]
EVENT_KINDS = [(c, n, re.compile(t), re.compile(f) if f else None) for c, n, t, f in EVENT_KINDS]
# The rules of the core a trip counts, in the order tried: (name, pattern of the log line). A line is one rule.
RULES = [
    ('turn moved to a crossing', r'is moved to the crossing'),
    ('turn left by "followed the roads"', r'has followed the roads, the crossing'),
    ('late turn', r'^The car has turned by'),
    # The head of LOGFMT 2 is off by now, so the rule is told by its sentence: "told repeatedly" (bend_moved_repeated,
    # a slow car or a far place) was "told repeatedly to a slow car" in older logs. Both kinds of the rule, the
    # ordinary bend and the gentle one, keep their tag in the sentence.
    ('bend moved, repeated', r'^(?:Gentle bend|Bend): moved along the road.*, told repeatedly'),
    ('bend moved', r'^(?:Gentle bend|Bend): moved along the road'),
    ('bend confirmed', r'^(?:Gentle bend|Bend): the position fits the road'),
    ('loop', r'^Loop: the way driven'),
    ('fork branch chosen', r'^FORK '),
    ('wait ahead', r'the mark is ahead, it waits'),
    ('wait at a roundabout', r'come to a roundabout before the car'),
    ('exit of a roundabout', r'has left the roundabout along a road|road past the roundabout'),
    ('followed apart', r'^The car maneuvers'),
    ('back on a road', r'drives along a road again|^The maneuvering car has driven along a road'),
    ('far mark taken', r'WAY misses.* there far\b'),
    ('mark switched by the way', r'^The car is shown on another road.*WAY misses'),
    ('road lost', r'^The road is lost after'),
]
RULES = [(name, re.compile(pattern)) for name, pattern in RULES]
# What came next is looked at this far from the line of a rule.
RULE_FOLLOW_M = 300
# A rule that fired in so few trips was made for one case: to drop or merge.
RULE_RARE_TRIPS = 2
# What Engine::PlaceMarkByGps wants of the fix: kGpsMaxAgeMs, kGpsMarkMaxAccuracyM, kGpsMarkMarginM.
GPS_MARK_MAX_AGE_S = 5
GPS_MARK_MAX_ACCURACY_M = 300
GPS_MARK_MARGIN_M = 50
# Who did what the line tells, the by= of an ACTION line: the key is in the head of the line, which the tools take
# off before they read its sentence.
ACTION_BY = re.compile(r'\bACTION \w+ (?:\w+=\S+ )*by=(\S+)')
# The by= of "ACTION tap" that are a tap of the user on the map, see Engine::PutMark; the rest ("gps_mark" for the
# GPS tap of the road lost panel, "peer" for the place of the other phone, "core" for a place the core guesses) are
# no taps. Only this key tells them apart while the manual mode is already on, as it is during a road loss: then
# Engine::SetManualMode writes no line of its own.
MARK_BY_USER = ('user', 'tap')
SENSORS = ('ACCB', 'ACCB_BEFORE', 'ACC', 'GYRO')
SLICES = 5


def num(row, key):
    """The number at the start of a field ("12/GPS" is 12), None if there is none."""
    value = row.get(key)
    if value is None:
        return None
    try:
        x = float(value.split('/')[0])
    except ValueError:
        return None
    return None if math.isnan(x) else x


def box_flags(row):
    """The names of the flags of the box set in the TRIP row, None without the box."""
    try:
        bits = int(row['bf'], 16)
    except (KeyError, ValueError):
        return None
    return {name for i, name in enumerate(BOX_FLAGS) if bits >> i & 1}


def to_ms(dt):
    return (dt - EPOCH) // timedelta(milliseconds=1)


def from_ms(ms):
    return EPOCH + timedelta(milliseconds=ms)


# Reading.

def unpack(name, data):
    """(name, bytes) of the logs in a file, a zip opened."""
    if not name.lower().endswith('.zip'):
        return [(name, data)]
    result = []
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            base = os.path.basename(info.filename)
            if not info.is_dir() and LOG_NAME.search(base) and not NOT_LOG_NAME.match(base):
                result += unpack(name + '/' + info.filename, z.read(info))
    return result


def load_paths(paths):
    """(name, bytes) of the logs in files, folders and zips. A file that is not a log of a known format (one left by
    an earlier version) is skipped with a note on stderr; LogFormatError when none can be read."""
    result = []
    errors = []
    for path in nogps_trip_log.log_files(paths, LOG_NAME):
        with open(path, 'rb') as f:
            for name, data in unpack(path, f.read()):
                try:
                    nogps_trip_log.header_of(name, data)
                except nogps_trip_log.LogFormatError as e:
                    errors.append(e)
                    continue
                result.append((name, data))
    if errors and not result:
        raise errors[0]
    for e in errors:
        print(f'Skipped: {e}', file=sys.stderr)
    return result


def load_flags(paths):
    """The flags (nogps_db.read_flags()) of the day folders of the tree in |paths|, a folder with its subfolders and
    the day folder of a file, each with its phone and day: the names of the folders <phone>/<yyyy-MM-dd>."""
    folders = set()
    for path in paths:
        path = os.path.abspath(path)
        if os.path.isdir(path):
            for folder, subfolders, _ in os.walk(path):
                if nogps_db.FLAG_FOLDER in subfolders:
                    folders.add(folder)
        elif os.path.isdir(os.path.join(os.path.dirname(path), nogps_db.FLAG_FOLDER)):
            folders.add(os.path.dirname(path))
    result = []
    for folder in sorted(folders):
        day = os.path.basename(folder)
        if not re.fullmatch(r'\d{4}-\d\d-\d\d', day):
            continue
        phone = os.path.basename(os.path.dirname(folder))
        result += [dict(flag, phone=phone, day=day, folder=folder) for flag in nogps_db.day_flags(folder, day)]
    return result


def parse_android(lines, year):
    """[time ms, level, raw line, tag, body] of an Android log, times local."""
    header_month = None
    for line in lines[:50]:
        m = ANDROID_DATETIME.match(line)
        if m:
            year, header_month = int(m.group(1)), int(m.group(2))
            break
    else:
        for line in lines:
            m = UNIX_MS.search(line)
            if m:
                year = from_ms(int(m.group(1))).year
                break
    result = []
    days = {}
    for line in lines:
        m = ANDROID_LINE.match(line)
        if not m:
            # A stack trace goes on the line before it, the header has none.
            if result and line:
                result[-1][2] += '\n' + line
                result[-1][4] += '\n' + line
            continue
        month, day = int(m.group(1)), int(m.group(2))
        y = year + 1 if header_month and month < header_month - 6 else year
        if (y, month, day) not in days:
            try:
                days[y, month, day] = to_ms(datetime(y, month, day))
            except ValueError:
                continue
        t = (days[y, month, day] + ((int(m.group(3)) * 60 + int(m.group(4))) * 60 + int(m.group(5))) * 1000
             + int(m.group(6)))
        result.append([t, LEVELS[m.group(8)], line, m.group(9), m.group(10)])
    return result


def parse_ios(lines):
    """[time ms, level, raw line, tag, body] of an iOS log, times UTC, and the number of lines of no known time.

    The time of a line is seconds since the app started; the "Local time:" line of each run tells when that was."""
    result = []
    pending = []
    launch = None
    previous = None
    last = None
    unknown = 0
    for line in lines:
        m = IOS_LINE.match(line)
        if not m:
            if last and line:
                last[2] += '\n' + line
                last[4] += '\n' + line
            continue
        seconds = float(m.group(3))
        if previous is not None and seconds + 1 < previous:
            unknown += len(pending)
            pending = []
            launch = None
        previous = seconds
        last = [seconds * 1000, LEVELS[m.group(1)], line, '', m.group(4)]
        anchor = IOS_LOCAL_TIME.search(m.group(4))
        if anchor:
            launch = to_ms(datetime.strptime(anchor.group(1), '%Y-%m-%d %H:%M:%S')) - last[0]
            pending.append(last)
            for entry in pending:
                entry[0] = round(launch + entry[0])
            result += pending
            pending = []
        elif launch is None:
            pending.append(last)
        else:
            last[0] = round(launch + last[0])
            result.append(last)
    return result, unknown + len(pending)


def parse_file(name, data, year):
    """The platform of a log and its lines, as parse_android() and parse_ios() give them."""
    lines = data.decode('utf-8', errors='replace').splitlines()
    sample = lines[:1000]
    android = sum(1 for line in sample if ANDROID_LINE.match(line))
    ios = sum(1 for line in sample if IOS_LINE.match(line))
    if android > ios:
        return 'android', parse_android(lines, year), 0
    if ios:
        return 'ios', *parse_ios(lines)
    return None, [], 0


# What a line tells.

def event_of(level, file, func, text):
    """The category and the name of a line that is an event, None if it is not."""
    where = file + ' ' + func
    for category, name, text_rx, where_rx in EVENT_KINDS:
        if (where_rx is None or where_rx.search(where)) and text_rx.search(text):
            return category, name
    if file.startswith('nogps/') or level in ('W', 'E'):
        return 'other', ' '.join(text.split('\n')[0].split()[:4])
    return None


def sensor_slices(t, words, count):
    """[time, values…] of each 200 ms slice of the second before |t|: the slices are "a,b,c,…"."""
    result = []
    for i, word in enumerate(words[:SLICES]):
        try:
            result.append([t - 1000 + (i + 1) * 1000 // SLICES] + [float(x) for x in word.split(',')[:count]])
        except ValueError:
            pass
    return result


class Group:
    """The lines of the logs of one platform and phone in time order, and what they tell."""

    def __init__(self, platform, phone, entries):
        self.platform = platform
        self.phone = phone
        self.zone = 'UTC' if platform == 'ios' else 'local time of the phone'
        seen = set()
        unique = []
        for entry in entries:
            if entry[2] not in seen:
                seen.add(entry[2])
                unique.append(entry)
        unique.sort(key=lambda e: e[0])
        self.times = [e[0] for e in unique]
        self.lines = [(e[0], e[1], e[2]) for e in unique]
        self.rows = []
        self.events = []
        self.series = dict(accb=[], acc=[], gyro=[])
        self.error_meter = nogps_trip_log.ErrorMeter()
        for t, level, _, tag, body in unique:
            self.classify(t, level, tag, body)
        self.row_times = [row['t'] for row in self.rows]
        self.event_times = [e['t'] for e in self.events]

    def classify(self, t, level, tag, body):
        source = SOURCE.match(body)
        file, func, text = (source.group(1), source.group(3), source.group(4)) if source else ('', '', body)
        # A line of LOGFMT 2 has a head before what the patterns below read, see nogps_replay.sentence.
        text = nogps_replay.sentence(text)
        if text.startswith('TRIP '):
            # Only the first line: parse_android appends the header of a joined file's next day to this entry.
            row = nogps_trip_log.parse_trip(text[len('TRIP '):].split('\n', 1)[0])
            self.error_meter.add(row, t / 1000)
            row['t'] = t
            self.rows.append(row)
            return
        words = text.split(' ')
        if words[0] in SENSORS:
            if words[0] == 'GYRO' and len(words) > SLICES + 1:
                # The rotation of each slice, degrees a second.
                for slice_ in sensor_slices(t, words[2:], 1):
                    self.series['gyro'].append([slice_[0], round(slice_[1] * SLICES, 2)])
            elif words[0] == 'ACCB_BEFORE' and len(words) > 1 and words[1].isdigit():
                self.series['accb'] += sensor_slices(t - int(words[1]) * 1000, words[2:], 4)
            elif words[0] in ('ACCB', 'ACC'):
                self.series[words[0].lower()] += sensor_slices(t, words[1:], 4)
            return
        kind = event_of(level, file, func, text)
        if kind:
            event = dict(t=t, level=level, cat=kind[0], name=kind[1], text=text, src=('%s %s' % (file, func)).strip())
            by = ACTION_BY.search(body)
            if by:
                event['by'] = by.group(1)
            position = LAT_LON.search(text)
            if position:
                event['lat'], event['lon'] = float(position.group(1)), float(position.group(2))
            self.events.append(event)

    def lines_between(self, start, end):
        return self.lines[bisect.bisect_left(self.times, start):bisect.bisect_right(self.times, end)]

    def map_taps(self):
        """When the user placed the mark on the map, by a tap or by the button of a place. Engine::PutMark writes
        the same "tap =" line for the GPS tap of the road lost panel, for the place the other phone shares and for
        the place the core guesses itself; its by= tells which of them. A line without by= is read as the user's,
        which is what a log older than the road lost panel has. A build between the panel (2026-11-19) and the by=
        key writes neither: in such a log a GPS tap of the panel counts as a map tap, and `losses` shows its loss
        as ended by the user."""
        return [e['t'] for e in self.events if e['cat'] == 'user' and e['name'] == 'tap'
                and e.get('by', 'tap') in MARK_BY_USER]

    def road_losses(self):
        """The road losses of the log (a row with lost=1 after one without), each as a dict: t, seconds, taps (the
        user tapped the map before the loss ended), fixable_s (seconds after the loss when the GPS tap of the road
        lost panel would first have worked, None if never) and why (what stopped it most often). The whole log of
        the phone is read at once: a loss goes on while the car stands, and standing splits the trips.

        The check is that of Engine::PlaceMarkByGps on the TRIP line: the newer of the GPS and fused fixes is not
        older than GPS_MARK_MAX_AGE_S, is accurate to GPS_MARK_MAX_ACCURACY_M, GPS is not spoofed, and the fix is
        not farther from the mark than the distance driven since the loss, the accuracies of the mark and of the fix
        and GPS_MARK_MARGIN_M. The distance is driven by the speed of the car alone, as InertialNavigator drives
        m_roadLostDrivenM; "speed=-1" is a speed not fresh, which neither drives it on. The road near the fix is
        not checked: the log has no map, so "fixable" is an upper bound: the settings of the user are not read
        either, so a trip with GPS turned off in the app (the tap fails with "GPS is turned off") can show losses as
        fixable. A tap on the map or the end of the loss ends the time the GPS tap could be used in; a tap just
        before the loss ends on its own is counted as a map tap too."""
        taps = self.map_taps()
        # iOS writes a line of the network location between the lines of the mark, with lost=0.
        rows = [row for row in self.rows if row.get('src') != 'NETWORK']

        def paused(j):
            """The log wrote nothing for STAND_SPLIT_S before rows[j]: a standing car is written every STAND_TRIP_S,
            so the app was not running, and the loss after the pause is counted as another one."""
            return rows[j]['t'] - rows[j - 1]['t'] > STAND_SPLIT_S * 1000

        result = []
        for i, row in enumerate(rows):
            if row.get('lost') != '1' or (i and rows[i - 1].get('lost') == '1' and not paused(i)):
                continue
            end = next((j for j in range(i + 1, len(rows)) if rows[j].get('lost') != '1' or paused(j)), len(rows))
            ended = rows[end]['t'] if end < len(rows) and not paused(end) else rows[end - 1]['t']
            tap = next((t for t in taps if row['t'] < t <= ended), None)
            fixable, reasons, driven = None, collections.Counter(), 0.0
            for j in range(i, end):
                current = rows[j]
                if tap is not None and current['t'] > tap:
                    break
                if j > i:
                    before = rows[j - 1]
                    driven += max(0.0, num(before, 'speed') or 0) / 3.6 * min(5, (current['t'] - before['t']) / 1000)
                why = gps_mark_failure(current, driven)
                if not why:
                    fixable = (current['t'] - row['t']) / 1000
                    break
                reasons[why] += 1
            why = reasons.most_common(1)[0][0] if reasons else 'no fix in the line'
            result.append(dict(t=row['t'], seconds=(ended - row['t']) / 1000, taps=tap is not None,
                               fixable_s=fixable, why=why))
        return result


# Trips.

def is_moving(row):
    speed = num(row, 'speed')
    if speed is not None and speed >= 3:
        return True
    for source in ('gps', 'fused'):
        kmh, accuracy = num(row, source + '_kmh'), num(row, source + '_acc')
        if kmh is not None and kmh >= 5 and (accuracy is None or accuracy <= 30):
            return True
    return False


def logs_every_second(row):
    """The core writes a TRIP line every second while the car moves by the box or by GPS, see Engine::LogTrip."""
    speed = num(row, 'speed')
    if speed is not None and speed > 0:
        return True
    return any((num(row, source + '_kmh') or 0) >= 3 for source in ('gps', 'fused'))


def split(group):
    """[first row, row after the last] of each trip of the group, and whether the car has driven on it."""
    rows = group.rows
    moving = [i for i, row in enumerate(rows) if is_moving(row)]
    drives = []
    for i in moving:
        if drives and rows[i]['t'] - rows[drives[-1][1]]['t'] <= STAND_SPLIT_S * 1000:
            drives[-1][1] = i
        else:
            drives.append([i, i])
    spans = []
    for first, last in drives:
        start, end = rows[first]['t'] - STAND_KEEP_S * 1000, rows[last]['t'] + STAND_KEEP_S * 1000
        spans.append((bisect.bisect_left(group.row_times, start), bisect.bisect_right(group.row_times, end), True))
    # The rows between drives: the phone standing, split where the log pauses.
    result = []
    i = 0
    for first, after, _ in spans + [(len(rows), len(rows), True)]:
        j = i
        while j < first:
            k = j + 1
            while k < first and rows[k]['t'] - rows[k - 1]['t'] <= TRIP_GAP_S * 1000:
                k += 1
            result.append((j, k, False))
            j = k
        i = after
    return sorted(result + spans)


def distance_m(rows):
    total = 0.0
    previous = None
    for row in rows:
        if 'lat' not in row:
            continue
        point = (float(row['lat']), float(row['lon']))
        if previous and row['t'] - previous[0] <= 5000:
            total += nogps_replay.meters(previous[1], point)
        previous = (row['t'], point)
    return total


def error_summary(rows):
    """The error of the shown position per source, as nogps_trip_log.py prints it."""
    result = {}
    for row in rows:
        result.setdefault(row.get('src'), []).append(row)
    summary = []
    for source, source_rows in result.items():
        errors = sorted(r['err_m'] for r in source_rows if 'err_m' in r)
        along = sorted(r['along_m'] for r in source_rows if 'along_m' in r)
        item = dict(src=source, seconds=len(source_rows), errors=len(errors))
        if errors:
            item.update(median=errors[len(errors) // 2], p90=errors[len(errors) * 9 // 10], max=errors[-1])
        if along:
            item['along_median'] = along[len(along) // 2]
        summary.append(item)
    return summary


# Anomalies: (name, test of a TRIP row and the row before it giving a value or None, seconds at least, severity of
# the values, text of the values).

def far_from_gps(row, _):
    error = row.get('err_m')
    if row.get('ref') == 'gps' and row.get('src') != 'GPS' and error is not None and error > 30:
        accuracy = num(row, 'gps_acc')
        return error if accuracy is None or accuracy <= 20 else None
    return None


def jumped(row, previous):
    if not previous or 'lat' not in row or 'lat' not in previous:
        return None
    dt = (row['t'] - previous['t']) / 1000
    if dt > 5:
        return None
    moved = nogps_replay.meters((float(row['lat']), float(row['lon'])),
                                (float(previous['lat']), float(previous['lon'])))
    speed = max(num(row, 'speed') or 0, num(row, 'gps_kmh') or 0, num(previous, 'speed') or 0) / 3.6
    return moved if moved > speed * dt + 50 else None


def box_data(row, _):
    if 'box' not in row or not is_moving(row):
        return None
    try:
        lines, gap = (int(x) for x in row['box'].split('/'))
    except ValueError:
        return None
    return row['box'] if lines < 4 or gap > 1000 else None


def box_link(row, _):
    link = row.get('link')
    return link if link and link != 'BLE/CONNECTED' and row.get('src') == 'INERTIAL' else None


def speed_stale(row, _):
    age = num(row, 'sage')
    return age if age is not None and age > 1500 and is_moving(row) else None


def bad_box_flags(row, _):
    flags = box_flags(row)
    if flags is None or not is_moving(row):
        return None
    bad = {'no ' + f for f in BOX_FLAGS_NEEDED if f not in flags} | {f for f in BOX_FLAGS_BAD if f in flags}
    return frozenset(bad) or None


def not_calibrated(row, _):
    gyro = row.get('gyro')
    return gyro if gyro and gyro != 'DONE' and is_moving(row) else None


def flag(key):
    return lambda row, _: 1 if row.get(key) == '1' else None


def heading_off(row, _):
    heading, bearing, kmh = num(row, 'hdg'), num(row, 'gps_bear'), num(row, 'gps_kmh')
    accuracy = num(row, 'gps_acc')
    if heading is None or bearing is None or kmh is None or kmh < 15 or (accuracy is not None and accuracy > 20):
        return None
    if row.get('gpsst') not in (None, 'GOOD'):
        return None
    difference = abs((heading - bearing + 180) % 360 - 180)
    return difference if difference > 30 else None


def speed_off(row, _):
    speed, kmh, accuracy = num(row, 'speed'), num(row, 'gps_kmh'), num(row, 'gps_acc')
    if speed is None or kmh is None or kmh < 20 or (accuracy is not None and accuracy > 20):
        return None
    difference = (speed - kmh) / kmh * 100
    return difference if abs(difference) > 20 else None


def worst(values):
    return max(values, key=abs)


def tiers(values):
    return 'high' if worst(values) > 100 else 'medium' if worst(values) > 50 else 'low'


def names(values):
    return ', '.join(sorted(set().union(*values)))


ANOMALIES = [
    ('mark far from GPS', far_from_gps, 3, tiers, lambda v: 'up to %.0f m from GPS' % worst(v)),
    ('mark jumped', jumped, 1, lambda v: 'medium', lambda v: '%.0f m in a second' % worst(v)),
    ('box data gaps', box_data, 2, lambda v: 'medium', lambda v: 'lines/longest gap ms: ' + ', '.join(
        sorted(set(v))[:5])),
    ('box not connected', box_link, 1, lambda v: 'high', lambda v: ', '.join(sorted(set(v)))),
    ('car speed stale', speed_stale, 2, lambda v: 'medium', lambda v: 'up to %.0f ms old' % worst(v)),
    ('box flags', bad_box_flags, 2, lambda v: 'medium', names),
    ('gyroscope not calibrated', not_calibrated, 2, lambda v: 'medium', lambda v: ', '.join(sorted(set(v)))),
    ('road lost', flag('lost'), 1, lambda v: 'medium', lambda v: 'lost=1'),
    ('followed apart off the roads', flag('self'), 1, lambda v: 'low', lambda v: 'self=1'),
    ('driving backward', flag('back'), 1, lambda v: 'low', lambda v: 'back=1'),
    ('GPS spoofed', flag('spoofed'), 1, lambda v: 'high', lambda v: 'spoofed=1'),
    ('heading off GPS', heading_off, 3, lambda v: 'medium', lambda v: 'up to %.0f°' % worst(v)),
    ('speed off GPS', speed_off, 5, lambda v: 'low', lambda v: 'up to %+.0f%%' % worst(v)),
]
# Warnings of the same kind this close are one anomaly.
WARNING_JOIN_S = 30


def stretches(rows, test, min_s, join_s=3):
    """[first time, last time, values] where test() gives a value, at least |min_s| long."""
    result = []
    current = None
    previous = None
    for row in rows:
        value = test(row, previous)
        if value is not None:
            if current and row['t'] - current[1] <= join_s * 1000:
                current[1] = row['t']
                current[2].append(value)
            else:
                current = [row['t'], row['t'], [value]]
                result.append(current)
        previous = row
    return [s for s in result if s[1] - s[0] >= (min_s - 1) * 1000]


def anomalies(rows, events):
    result = []
    for name, test, min_s, severity, text in ANOMALIES:
        for start, end, values in stretches(rows, test, min_s):
            result.append(dict(start=start, end=end, kind=name, severity=severity(values), text=text(values)))
    for previous, row in zip(rows, rows[1:]):
        gap = row['t'] - previous['t']
        if gap > MISSING_TRIP_S * 1000 and not (gap <= STAND_TRIP_S * 1000 and not logs_every_second(previous)):
            result.append(dict(start=previous['t'], end=row['t'], kind='no TRIP lines', severity='low',
                               text='%.0f s without a TRIP line' % (gap / 1000)))
    warnings = {}
    for e in events:
        if e['level'] not in ('W', 'E'):
            continue
        key = (e['level'], e['name'])
        last = warnings.get(key)
        if last and e['t'] - last['end'] <= WARNING_JOIN_S * 1000:
            last['end'] = e['t']
            last['count'] += 1
            continue
        warnings[key] = dict(start=e['t'], end=e['t'], count=1, first=e['text'],
                             kind=('error: ' if e['level'] == 'E' else 'warning: ') + e['name'],
                             severity='high' if e['level'] == 'E' else 'low')
        result.append(warnings[key])
    for a in result:
        if 'count' in a:
            count, first = a.pop('count'), a.pop('first')
            a['text'] = first if count == 1 else '%d lines, the first: %s' % (count, first)
    result.sort(key=lambda a: a['start'])
    return result


def gps_mark_failure(row, driven_m):
    """Why a tap on the road lost panel could not place the mark by the GPS of the TRIP line, None if it could:
    Engine::PlaceMarkByGps without the road search."""
    fixes = [(num(row, key + '_age'), key) for key in ('gps', 'fused') if key + '_lat' in row]
    fixes = [(age, key) for age, key in fixes if age is not None]
    if not fixes:
        return 'no fix in the line'
    age, key = min(fixes)
    accuracy = num(row, key + '_acc') or 0
    if row.get('spoofed') == '1':
        return 'GPS is spoofed'
    if age > GPS_MARK_MAX_AGE_S:
        return 'fix older than %d s' % GPS_MARK_MAX_AGE_S
    if accuracy > GPS_MARK_MAX_ACCURACY_M:
        return 'fix accuracy over %d m' % GPS_MARK_MAX_ACCURACY_M
    mark = (float(row['lat']), float(row['lon']))
    away = nogps_replay.meters(mark, (float(row[key + '_lat']), float(row[key + '_lon'])))
    if away > driven_m + (num(row, 'acc') or 0) + accuracy + GPS_MARK_MARGIN_M:
        return 'fix too far from the mark'
    return None


class Trip:
    def __init__(self, number, group, first, after, driven):
        self.id = number
        self.group = group
        self.rows = group.rows[first:after]
        self.start, self.end = self.rows[0]['t'], self.rows[-1]['t']
        self.driven = driven
        # The events of the seconds before the first TRIP line, as the start of the app, are the trip's too.
        events_from = self.start - STAND_KEEP_S * 1000
        if first:
            events_from = max(events_from, group.rows[first - 1]['t'] + 1)
        self.events = group.events[bisect.bisect_left(group.event_times, events_from):
                                   bisect.bisect_right(group.event_times, self.end)]
        self.anomalies = anomalies(self.rows, self.events)
        self.flags = []

    def calibration(self):
        """The calibration of the car the log last wrote before this trip moved, "car=C47D scale=1.04 table=…":
        the last CALIBRATION line before the car moves, before the first TRIP line of a trip that stands. The
        lines written after the box connects, when its car is another one or its values are taken, come while the
        car still stands. None if the log has none.

        It is what the trip started with only when the line is of this trip: the core writes it at a launch and at
        a TripStarted (a link gap of 5 minutes), and learning writes nothing. A second drive after a shorter stand
        is one trip to the core and another one here, so it reports the values of the drive before it, without what
        that drive learned. calibration_at() tells which, so compare it with the start of the trip."""
        e = self.calibration_event()
        return e['text'][len('CALIBRATION '):] if e else None

    def calibration_at(self):
        """When the line of calibration() was written, None if the log has none."""
        e = self.calibration_event()
        return e['t'] if e else None

    def calibration_event(self):
        start = next((row['t'] for row in self.rows if is_moving(row)), self.start)
        events = self.group.events
        for e in reversed(events[:bisect.bisect_right(self.group.event_times, start)]):
            if e['name'] == 'car calibration':
                return e
        return None

    def summary(self):
        sources = {}
        # A line stands for the seconds until the next one: a standing car is written once in STAND_TRIP_S.
        for row, after in zip(self.rows, self.rows[1:] + [None]):
            seconds = 1
            if after and not logs_every_second(row):
                seconds = max(1, min(STAND_TRIP_S, round((after['t'] - row['t']) / 1000)))
            sources[row.get('src', '-')] = sources.get(row.get('src', '-'), 0) + seconds
        speeds = [x for row in self.rows for x in (num(row, 'speed'), num(row, 'gps_kmh')) if x is not None]
        severities = {}
        for a in self.anomalies:
            severities[a['severity']] = severities.get(a['severity'], 0) + 1
        errors = sorted(row['err_m'] for row in self.rows if 'err_m' in row and row.get('src') == 'INERTIAL')
        return dict(id=self.id, platform=self.group.platform, phone=self.group.phone, zone=self.group.zone,
                    start=self.start, end=self.end, driven=self.driven, km=round(distance_m(self.rows) / 1000, 2),
                    max_kmh=round(max(speeds)) if speeds else None, sources=sources, lines=len(self.rows),
                    events=len(self.events), anomalies=severities, flags=len(self.flags),
                    inertial_error_median=errors[len(errors) // 2] if errors else None)

    def rule_counts(self):
        """{rule name: dict(fired, ok, lost, tap)}: how often a rule of RULES fired in the trip, and what came next
        within RULE_FOLLOW_M of driving: the road lost (a new loss), a tap of the user on the map, or neither (ok).
        The loss after "road lost" itself is not counted."""
        taps = self.group.map_taps()
        result = {}
        for e in self.events:
            name = next((n for n, rx in RULES if rx.search(e['text'])), None)
            if not name:
                continue
            counts = result.setdefault(name, dict(fired=0, ok=0, lost=0, tap=0))
            counts['fired'] += 1
            first = bisect.bisect_left(self.group.row_times, e['t'])
            rows = self.group.rows
            walked, end, lost = 0.0, e['t'], False
            was_lost = first < len(rows) and rows[first].get('lost') == '1'
            for row, after in zip(rows[first:], rows[first + 1:]):
                lost = lost or (row.get('lost') == '1' and not was_lost)
                # The core drives the mark by the speed of the car; "speed=-1" is a speed not fresh.
                kmh = max(0.0, num(row, 'speed') or 0)
                walked += kmh / 3.6 * min(5, (after['t'] - row['t']) / 1000)
                end = after['t']
                if walked >= RULE_FOLLOW_M or after['t'] > self.end:
                    break
            tapped = any(e['t'] < t <= end for t in taps)
            if lost and name != 'road lost':
                counts['lost'] += 1
            elif tapped:
                counts['tap'] += 1
            else:
                counts['ok'] += 1
        return result

    def details(self):
        fields = list(dict.fromkeys(k for row in self.rows for k in row))
        series = {name: [s for s in values if self.start - 1000 <= s[0] <= self.end]
                  for name, values in self.group.series.items()}
        counts = []
        for name, pattern in nogps_replay.EVENTS:
            rx = re.compile(pattern)
            counts.append((name, sum(1 for e in self.events if rx.search(e['text']))))
        for name, key in (('seconds stopped as lost', 'lost'), ('seconds followed apart', 'self')):
            counts.append((name, sum(1 for r in self.rows if r.get(key) == '1' and (num(r, 'speed') or 0) > 0)))
        switches = sum(1 for a, b in zip(self.rows, self.rows[1:]) if a.get('choice') != b.get('choice'))
        return dict(self.summary(), fields=fields, rows=[[row.get(k) for k in fields] for row in self.rows],
                    series=series, events=self.events, anomalies=self.anomalies,
                    errors=error_summary(self.rows), counts=counts, choice_switches=switches,
                    rules=self.rule_counts())

    def csv(self):
        rows = []
        for row in self.rows:
            row = dict(row)
            row['time'] = from_ms(row.pop('t')).isoformat(timespec='milliseconds')
            rows.append(row)
        columns = nogps_trip_log.FIRST_COLUMNS + list(
            dict.fromkeys(k for row in rows for k in row if k not in nogps_trip_log.FIRST_COLUMNS))
        out = io.StringIO()
        writer = csv.DictWriter(out, columns)
        writer.writeheader()
        writer.writerows(rows)
        return out.getvalue()

    def gpx(self):
        rows = []
        for row in self.rows:
            row = dict(row)
            # Android logs have the local time of the phone, not UTC.
            row['time'] = from_ms(row['t']).isoformat(timespec='milliseconds') + (
                'Z' if self.group.platform == 'ios' else '')
            rows.append(row)
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'trip.gpx')
            nogps_trip_log.write_gpx(path, rows)
            with open(path, encoding='utf-8') as f:
                return f.read()

    def replay(self, data):
        """The trip driven again by nogps_replay_tool or an Android debug build: its trip log against the trip."""
        if self.group.platform != 'android':
            raise ValueError('only an Android trip is driven again')
        day_start = self.start - self.start % 86_400_000
        day = from_ms(self.start).strftime('%m-%d')
        with tempfile.TemporaryDirectory() as folder:
            original, replay = os.path.join(folder, 'trip.log'), os.path.join(folder, 'replay.log')
            with open(original, 'w', encoding='utf-8') as f:
                f.writelines(line + '\n' for _, _, line in self.group.lines_between(day_start, day_start + 86_399_999))
            with open(replay, 'wb') as f:
                f.write(data)
            trips, others, _ = nogps_replay.read([original], day)
            replayed, replayed_others, _ = nogps_replay.read([replay], day)
        start, end = self.start - day_start, self.end - day_start
        stats = nogps_replay.compare_stats(trips, others, replayed, replayed_others, start, end, REPLAY_CHANGE_M)
        stretches = [dict(s, start=day_start + s['start'] * 1000, to=day_start + s['to'] * 1000)
                     for s in stats['stretches']]
        track = []
        for f in replayed:
            position = nogps_replay.lat_lon(f.get('pos'))
            if position and start <= f['ms'] <= end:
                track.append([day_start + f['ms'], position[0], position[1], f.get('src')])
        events = [dict(t=day_start + ms, text=text) for ms, text, _ in replayed_others if start <= ms <= end]
        return dict(stats=stats, stretches=stretches, track=track, events=events, day=day,
                    date=from_ms(self.start).strftime('%Y-%m-%d'))


class Analysis:
    """The trips of all the logs given."""

    def __init__(self, sources, year=None, flags=()):
        year = year or datetime.now().year
        entries = {}
        self.notes = []
        self.files = []
        # A file of no known format is skipped as load_paths() skips it, and refused when no file is left: a zip can
        # hold a file of an earlier version next to the ones of the tree.
        refused = []
        read = 0
        for name, data in sources:
            for log_name, log_data in unpack(name, data):
                try:
                    phone = nogps_trip_log.header_of(log_name, log_data)['phone']
                except nogps_trip_log.LogFormatError as e:
                    refused.append(e)
                    continue
                read += 1
                platform, lines, unknown = parse_file(log_name, log_data, year)
                if not platform:
                    self.notes.append('%s: has no lines of the app' % log_name)
                    continue
                self.files.append(dict(name=log_name, platform=platform, phone=phone, lines=len(lines)))
                if unknown:
                    self.notes.append('%s: %d lines of a run without "Local time:", their time is unknown'
                                      % (log_name, unknown))
                entries.setdefault((platform, phone), []).extend(lines)
        if refused and not read:
            raise refused[0]
        self.notes += ['Skipped: %s' % e for e in refused]
        self.groups = [Group(platform, phone, lines) for (platform, phone), lines in sorted(entries.items())]
        spans = sorted(((g, first, after, driven) for g in self.groups for first, after, driven in split(g)),
                       key=lambda s: s[0].rows[s[1]]['t'])
        self.trips = [Trip(i, *span) for i, span in enumerate(spans)]
        self.flags = [self.place(dict(flag)) for flag in sorted(flags, key=lambda f: (f['phone'], f['local_ms']))]

    def place(self, flag):
        """|flag| with 't', its time on the axis of the trips of its phone (None when unknown), and 'trip', the id
        of the trip it is on (None when it is on none)."""
        flag['t'] = flag['trip'] = None
        best = None
        for trip in self.trips:
            if trip.group.phone != flag['phone']:
                continue
            t = flag['local_ms'] if trip.group.platform == 'android' else flag['ms']
            if t is None:
                continue
            flag['t'] = t
            off = max(trip.start - t, t - trip.end, 0)
            if off <= STAND_KEEP_S * 1000 and (best is None or off < best[0]):
                best = off, trip
        if best:
            flag['trip'] = best[1].id
            best[1].flags.append(flag)
        return flag


# The report: what the viewer shows, as text.

STATE_GROUPS = [
    ('Position', ['src', 'lat', 'lon', 'acc', 'bear', 'age', 'markAge', 'fill']),
    ('Error from GPS', ['ref', 'err_m', 'along_m', 'across_m', 'err_why']),
    ('GPS', ['gpsst', 'gps_lat', 'gps_lon', 'gps_acc', 'gps_kmh', 'gps_bear', 'gps_age', 'gpsAge', 'spoofed', 'cmp']),
    ('Fused and network', ['fused_lat', 'fused_lon', 'fused_acc', 'fused_kmh', 'fused_bear', 'fused_age', 'net_lat',
                           'net_lon', 'net_acc', 'net_age']),
    ('Choice and route', ['choice', 'nav', 'left', 'rte']),
    ('Box', ['obd', 'link', 'box', 'bf', 'fw', 'ota', 'speed', 'sage']),
    ('Inertial', ['gyro', 'hdg', 'scale', 'table', 'rough', 'lag', 'boxacc', 'phoneacc', 'turn', 'odo', 'offm', 'offv',
                  'back', 'turning', 'ready', 'ring']),
    ('Road matching', ['road', 'lost', 'snap', 'snapwhy', 'wait', 'rdiff', 'cand', 'fix', 'self', 'car', 'marks',
                       'others']),
]
# Fields that change every second: not marked as changed.
MOVING_FIELDS = {'lat', 'lon', 'gps_lat', 'gps_lon', 'fused_lat', 'fused_lon', 'age', 'gps_age', 'fused_age', 'odo',
                 'err_m', 'along_m', 'across_m'}
ROWS_FIELDS = 'src,err_m,along_m,speed,gps_kmh,hdg,gps_bear,road,lost,snapwhy'
# The lines of every second, left out of the log lines around a moment.
NOISY_LINE = re.compile(r' (LogTrip\(\): TRIP|\w+\(\): (ACCB|ACCB_BEFORE|ACC|GYRO) )')
EVENTS_AROUND_S = 30
LINES_AROUND_S = 5
FLAG_AROUND_S = 30


def clock(ms):
    return from_ms(ms).strftime('%H:%M:%S')


def duration(ms):
    s = round(ms / 1000)
    return '%d s' % s if s < 60 else '%d min %d s' % divmod(s, 60) if s < 3600 else '%d h %d min' % (
        s // 3600, s % 3600 // 60)


def moment(trip, text):
    """The time of HH:MM[:SS] on the trip: after midnight on a trip that has crossed it."""
    h, m, s = ([int(x) for x in text.split(':')] + [0])[:3]
    t = trip.start - trip.start % 86_400_000 + ((h * 60 + m) * 60 + s) * 1000
    return t + 86_400_000 if t < trip.start - 3_600_000 else t


def short(text, full):
    text = text if full else text.split('\n')[0]
    return text if full or len(text) <= 200 else text[:200] + '…'


def flag_text(flag):
    """"flag 3 18:02:35 voice 7 s, sent" of a flag, at the local time of its name."""
    voice = flag.get('voice_s')
    return 'flag %s %s%s%s' % (flag.get('n'), clock(flag['local_ms']), ' voice %g s' % voice if voice else '',
                               ', sent' if flag.get('sent') else '')


def print_flags(analysis):
    """Every flag with its trip, the time of its name, the voice and where the viewer shows it."""
    print('%-18s %-10s %4s  %-8s %-8s %5s %5s  %s' % ('phone', 'day', 'trip', 'local', 'on trip', 'voice', 'sent',
                                                     'viewer'))
    for f in analysis.flags:
        on_trip = clock(f['t']) if f['trip'] is not None else '-'
        print('%-18s %-10s %4s  %-8s %-8s %5s %5s  %s' % (
            f['phone'][:18], f['day'], f['trip'] if f['trip'] is not None else '-', clock(f['local_ms']), on_trip,
            '%g s' % f['voice_s'] if f.get('voice_s') else '-', 'yes' if f.get('sent') else 'no',
            '#trip=%d&t=%d' % (f['trip'], f['t']) if f['trip'] is not None else
            'no trip' if f['t'] is not None or f['ms'] is not None else 'UTC unknown'))
    print('%d flags, %d on a trip' % (len(analysis.flags), sum(f['trip'] is not None for f in analysis.flags)))


def print_trips(analysis, stationary):
    for zone in sorted({t.group.zone for t in analysis.trips}):
        print('times of %s logs: %s' % ('iOS' if zone == 'UTC' else 'Android', zone))
    print('%3s  %-16s  %-12s %7s %5s  %-26s %7s  %-12s %5s %s' % ('id', 'start', 'duration', 'km', 'max', 'sources',
                                                                 'box err', 'anomalies', 'flags', 'events'))
    for trip in analysis.trips:
        if not trip.driven and not stationary:
            continue
        s = trip.summary()
        total = sum(s['sources'].values())
        sources = ' '.join('%s %d%%' % (k, round(v * 100 / total)) for k, v in s['sources'].items())
        anomalies = '/'.join(str(s['anomalies'].get(k, 0)) for k in ('high', 'medium', 'low'))
        error = s['inertial_error_median']
        print('%3d  %-16s  %-12s %7.2f %5s  %-26s %7s  %-12s %5d %d%s' % (
            trip.id, from_ms(trip.start).strftime('%Y-%m-%d %H:%M'), duration(trip.end - trip.start), s['km'],
            s['max_kmh'] if s['max_kmh'] is not None else '-', sources[:26],
            '%.0f m' % error if error is not None else '-', anomalies, s['flags'], s['events'],
            '' if trip.driven else ' stands'))
    print('anomalies: high/medium/low')
    for note in analysis.notes:
        print('note:', note)


def print_trip(trip):
    d = trip.details()
    print('trip %d, %s, times: %s' % (trip.id, ' '.join(filter(None, (trip.group.platform, trip.group.phone))),
                                      trip.group.zone))
    print('%s – %s, %s, %.2f km, max %s km/h, %d TRIP lines, choice switches %d' % (
        from_ms(trip.start).strftime('%Y-%m-%d %H:%M:%S'), clock(trip.end), duration(trip.end - trip.start), d['km'],
        d['max_kmh'], d['lines'], d['choice_switches']))
    calibration, at = trip.calibration(), trip.calibration_at()
    # The time tells whether the line is of this trip: written before it, it misses what the drive before learned.
    print('calibration:', '%s (written %s)' % (calibration, clock(at)) if calibration else 'not in the log')
    total = sum(d['sources'].values())
    print('sources:', ', '.join('%s %d s %.0f%%' % (k, v, v * 100 / total) for k, v in d['sources'].items()))
    for e in d['errors']:
        if e['errors']:
            print('error from GPS of %s: %d s with GPS, median %.1f m, 90%% %.1f m, max %.1f m%s' % (
                e['src'], e['errors'], e['median'], e['p90'], e['max'],
                ', along median %+.1f m' % e['along_median'] if 'along_median' in e else ''))
    counts = [(name, count) for name, count in d['counts'] if count]
    print('counts:', ', '.join('%s %d' % c for c in counts) or 'none')
    by_name = {}
    for e in trip.events:
        by_name[e['cat'] + '/' + e['name']] = by_name.get(e['cat'] + '/' + e['name'], 0) + 1
    rules = trip.rule_counts()
    print('rules:', ', '.join('%s %d (lost %d, tap %d)' % (name, c['fired'], c['lost'], c['tap'])
                              for name, c in rules.items()) or 'none')
    print('events:', ', '.join('%s %d' % kv for kv in sorted(by_name.items())) or 'none')
    print('anomalies:', len(trip.anomalies))
    for a in trip.anomalies:
        print('  %s %8s  %-6s  %s: %s' % (clock(a['start']), duration(a['end'] - a['start'] + 1000), a['severity'],
                                          a['kind'], short(a['text'], False)))
    print('flags:', len(trip.flags))
    for f in trip.flags:
        print('  %s %s (#trip=%d&t=%d)' % (clock(f['t']), flag_text(f), trip.id, f['t']))


def print_rules(analysis):
    """The rules of RULES over all the driven trips: how often each fired, in how many trips, and what came next."""
    total = {}
    for trip in analysis.trips:
        if not trip.driven:
            continue
        for name, c in trip.rule_counts().items():
            t = total.setdefault(name, dict(fired=0, ok=0, lost=0, tap=0, trips=0))
            t['trips'] += 1
            for key in ('fired', 'ok', 'lost', 'tap'):
                t[key] += c[key]
    print('%-36s %6s %6s %6s %6s %6s  %s' % ('rule', 'fired', 'trips', 'ok', 'lost', 'tap',
                                           'within %d m of driving' % RULE_FOLLOW_M))
    for name, _ in RULES:
        t = total.get(name, dict(fired=0, ok=0, lost=0, tap=0, trips=0))
        notes = []
        if t['trips'] <= RULE_RARE_TRIPS:
            notes.append('rare: %d trips, made for one case?' % t['trips'])
        if name != 'road lost' and t['lost'] + t['tap'] > t['ok']:
            notes.append('followed by a loss or a tap more often than not')
        print('%-36s %6d %6d %6d %6d %6d  %s' % (name, t['fired'], t['trips'], t['ok'], t['lost'], t['tap'],
                                                '; '.join(notes)))


def print_rating(analysis):
    """The driver rating of the driven trips, rebuilt from lim= and speed= of the TRIP lines, see nogps_rating.py:
    for each trip the share of the driven km that was rated and the episodes by band, then the score of the
    window the app shows. A trip logged before lim= was written has no rated driving."""
    print('%3s  %-16s %7s %7s %6s  %-9s %5s' % ('id', 'start', 'km', 'rated', 'share', 'episodes', 'score'))
    results = []
    for trip in analysis.trips:
        if not trip.driven:
            continue
        r = nogps_rating.rate_rows(trip.rows, num)
        results.append(r)
        km = trip.summary()['km']
        print('%3d  %-16s %7.2f %7.2f %5.0f%%  %-9s %5s' % (
            trip.id, from_ms(trip.start).strftime('%Y-%m-%d %H:%M'), km, r['rated_km'],
            100 * r['rated_km'] / km if km else 0, '/'.join(str(b) for b in r['bands']),
            r['score'] if r['rated_s'] else '-'))
        for e in r['episodes']:
            print('       SPEEDING %s dur=%.1f dist=%d lim=%d peak=%d mean=%d band=%d' % (
                clock(e['ms']), e['dur'], e['dist'], e['lim'], e['peak'], e['mean'], e['band']))
    w = nogps_rating.window(results)
    print('window: %.0f km rated, %s, score %d, episodes %s' % (
        w['rated_km'], 'enough' if w['enough'] else 'not enough (under %d km)' % nogps_rating.SCORE_MIN_KM, w['score'],
        '/'.join(str(b) for b in w['bands'])))
    print('episodes: +20..40 / +40..60 / over +60')


def print_losses(analysis):
    """The road losses of the logs: for each, whether a tap on the road lost panel would have placed the mark by
    GPS (see Group.road_losses), and the totals per set of nogps_replay.py days. The trip logs have no taps on the
    panel, so a replay can't tell it."""
    held_out = nogps_replay.held_out_days()
    totals = {}
    print('%-6s %-8s %8s  %-8s %-9s  %s' % ('day', 'at', 'lasted', 'ended by', 'GPS tap', 'why not'))
    losses = sorted((loss for group in analysis.groups for loss in group.road_losses()), key=lambda l: l['t'])
    for loss in losses:
        day = from_ms(loss['t']).strftime('%m-%d')
        date = from_ms(loss['t']).strftime('%Y-%m-%d')
        fixed = loss['fixable_s'] is not None
        print('%-6s %s %8s  %-8s %-9s  %s' % (day, clock(loss['t']), duration(loss['seconds'] * 1000),
                                              'map tap' if loss['taps'] else 'no tap',
                                              'after %ds' % loss['fixable_s'] if fixed else 'no',
                                              '' if fixed else loss['why']))
        t = totals.setdefault(nogps_replay.set_of(date, held_out), collections.Counter())
        t['losses'] += 1
        t['fixable'] += fixed
        t['taps'] += loss['taps']
        t['tap_fixable'] += fixed and loss['taps']
    print()
    print('%-10s %7s %9s %9s %17s' % ('set', 'losses', 'fixable', 'map taps', 'map taps fixable'))
    for name in ('made from', 'held out'):
        t = totals.get(name, collections.Counter())
        print('%-10s %7d %9d %9d %17d' % (name, t['losses'], t['fixable'], t['taps'], t['tap_fixable']))


def print_events(trip, start, end, category, text, full):
    rx = re.compile(text, re.I) if text else None
    for e in trip.events:
        if start <= e['t'] <= end and (not category or e['cat'] == category) and (
                not rx or rx.search(e['name'] + ' ' + e['text'])):
            print('%s %s %s/%s: %s' % (clock(e['t']), e['level'], e['cat'], e['name'], short(e['text'], full)))


def format_field(row, key):
    value = row[key]
    if key == 'bf':
        flags = box_flags(row) or set()
        return '%s (%s)' % (value, ' '.join(f for f in BOX_FLAGS if f in flags) or 'none')
    return '%.1f' % value if isinstance(value, float) else str(value)


def print_state(trip, t, full):
    times = [row['t'] for row in trip.rows]
    i = max(bisect.bisect_right(times, t) - 1, 0)
    row, previous = trip.rows[i], trip.rows[i - 1] if i else None
    print('%s, TRIP line %d of %d of trip %d (in the viewer: #trip=%d&t=%d), * changed since the line before' % (
        clock(row['t']), i + 1, len(trip.rows), trip.id, trip.id, row['t']))
    grouped = {k for _, keys in STATE_GROUPS for k in keys} | {'t'}
    for name, keys in STATE_GROUPS + [('Other', [k for k in row if k not in grouped])]:
        fields = ['%s=%s%s' % (k, format_field(row, k), '*' if previous and k not in MOVING_FIELDS
                                                        and previous.get(k) != row[k] else '')
                  for k in keys if k in row]
        if fields:
            print('%s: %s' % (name, ' '.join(fields)))
    flags = [f for f in trip.flags if abs(f['t'] - t) <= FLAG_AROUND_S * 1000]
    print('flags within %d s:' % FLAG_AROUND_S, '; '.join('%+d s %s' % (round((f['t'] - t) / 1000), flag_text(f))
                                                          for f in flags) or 'none')
    now = [a for a in trip.anomalies if a['start'] <= t <= a['end'] + 1000]
    print('anomalies now:', '; '.join('%s %s: %s' % (a['severity'], a['kind'], a['text']) for a in now) or 'none')
    print('events within %d s:' % EVENTS_AROUND_S)
    for e in trip.events:
        if abs(e['t'] - t) <= EVENTS_AROUND_S * 1000:
            print('  %+4d s %s %s/%s: %s' % (round((e['t'] - t) / 1000), e['level'], e['cat'], e['name'],
                                             short(e['text'], full)))
    print('log lines within %d s, without TRIP and sensor lines:' % LINES_AROUND_S)
    for _, _, raw in trip.group.lines_between(t - LINES_AROUND_S * 1000, t + LINES_AROUND_S * 1000):
        if not NOISY_LINE.search(raw):
            print('  ' + short(raw, full))


def print_rows(trip, start, end, fields, every):
    print(('time      ' + ' '.join('%-9s' % f for f in fields)).rstrip())
    last = None
    for row in trip.rows:
        if start <= row['t'] <= end and (last is None or row['t'] - last >= every * 1000):
            last = row['t']
            print(('%s  %s' % (clock(row['t']), ' '.join('%-9s' % (format_field(row, f) if f in row else '-')
                                                        for f in fields))).rstrip())


def main():
    import argparse
    parser = argparse.ArgumentParser(
        description='What the trip log viewer shows, as text: for a terminal and for Claude Code.',
        epilog='''commands:
  trips   the trips of the logs, --all with the stationary ones
  rating  the driver rating from the lim= and speed= of the TRIP lines: rated km, episodes by band, score
  losses  the road losses: would a tap on the road lost panel have placed the mark by GPS
  rules   how often each rule of the core fired over all the trips, and what came next
  trip    a trip: stats, error from GPS, counts, events, anomalies
  events  the events of a trip, --from/--to HH:MM[:SS], --cat road, --grep regex, --full
  state   every TRIP field at --at HH:MM[:SS], anomalies, events and log lines around it
  rows    TRIP fields second by second: --fields a,b,c, --every N s, --from/--to
  replay  the trip against a nogps-replay-out.txt: --replay file
  flags   every flag of the tree with its trip, the time, the voice and where the viewer shows it''',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=['trips', 'rating', 'losses', 'rules', 'trip', 'events', 'state', 'rows', 'replay',
                                            'flags'])
    parser.add_argument('logs', nargs='+', help='the logs tree logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log, '
                        'logs.zip or log files')
    parser.add_argument('--year', type=int, help='the year of an Android log without its header')
    parser.add_argument('--trip', type=int, help='the id the trips command shows')
    parser.add_argument('--all', action='store_true', help='with the stationary trips')
    parser.add_argument('--at', help='HH:MM[:SS]')
    parser.add_argument('--from', dest='start', help='HH:MM[:SS]')
    parser.add_argument('--to', dest='end', help='HH:MM[:SS]')
    parser.add_argument('--cat', help='app state user road turn box route gps other')
    parser.add_argument('--grep', help='a regular expression the event matches')
    parser.add_argument('--full', action='store_true', help='whole lines, with their stack traces')
    parser.add_argument('--fields', default=ROWS_FIELDS)
    parser.add_argument('--every', type=float, default=1)
    parser.add_argument('--replay', help='nogps-replay-out.txt')
    args = parser.parse_args()

    try:
        analysis = Analysis(load_paths(args.logs), args.year, load_flags(args.logs))
    except nogps_trip_log.LogFormatError as e:
        parser.error(str(e))
    if args.command == 'trips':
        return print_trips(analysis, args.all)
    if args.command == 'rating':
        return print_rating(analysis)
    if args.command == 'losses':
        return print_losses(analysis)
    if args.command == 'rules':
        return print_rules(analysis)
    if args.command == 'flags':
        return print_flags(analysis)
    if args.trip is None or not 0 <= args.trip < len(analysis.trips):
        parser.error('--trip: one of the ids the trips command shows')
    trip = analysis.trips[args.trip]
    start = moment(trip, args.start) if args.start else trip.start - EVENTS_AROUND_S * 1000
    end = moment(trip, args.end) if args.end else trip.end
    if args.command == 'trip':
        print_trip(trip)
    elif args.command == 'events':
        print_events(trip, start, end, args.cat, args.grep, args.full)
    elif args.command == 'state':
        if not args.at:
            parser.error('state needs --at')
        print_state(trip, moment(trip, args.at), args.full)
    elif args.command == 'rows':
        print_rows(trip, start, end, args.fields.split(','), args.every)
    elif not args.replay:
        parser.error('replay needs --replay')
    else:
        with open(args.replay, 'rb') as f:
            result = trip.replay(f.read())
        nogps_replay.print_compare(result['stats'], result['day'], REPLAY_CHANGE_M, result['date'])


if __name__ == '__main__':
    main()
