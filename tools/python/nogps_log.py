#!/usr/bin/env python3
"""Reads the logs of NonGPS Maps: splits them into trips and finds the events and the anomalies of each trip, for
nogps_log_viewer.py and as a text report:

  nogps_log.py trips logs.zip
  nogps_log.py trip logs.zip --trip 3
  nogps_log.py state logs.zip --trip 3 --at 18:02:35
  nogps_log.py --help    for all the commands

Logs:
  iOS: Documents/log.txt or the log.zip of "Report a bug". Times are UTC.
  Android: app*.log of Android/data/<app id>/files/logs/ or the logs.zip of "Report a bug". Times are the local time
  of the phone; the year is taken from the header of a file.

A trip is the car driving with stops shorter than STAND_SPLIT_S. The lines of a phone that stands are kept as
stationary trips.
"""

import bisect
import csv
import io
import math
import os
import re
import tempfile
import zipfile
from datetime import datetime, timedelta

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
LOG_NAME = re.compile(r'\.(log|txt|zip)$', re.I)
NOT_LOG_NAME = re.compile(r'^(logcat|nogps-replay)', re.I)

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
    ('road', 'loop', r'^Loop: ', None),
    ('road', 'other marks dropped', r'^Other marks? (dropped|not added)', None),
    ('road', 'car started', r'^The car has started', None),
    ('road', 'car drives fast', r'^The car drives fast', None),
    ('road', 'no road its way', r'no road goes its way', None),
    ('road', 'speed table', r'^(Rough speed table|Speed table)', None),
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
    ('box', 'calibration', r'^Calibrat|calibrat', None),
    ('box', 'box accelerometer', r'^BOXACC |accelerometer of the box|accelerometer was learned', None),
    ('box', 'firmware', r'[Ff]irmware|sending again', None),
    ('box', 'box link', r'', r'^Esp32|^NoGpsBox'),
    ('route', 'routing state', r'^Routing session state|following mode|^\[[SB]\] State', None),
    ('route', 'route calculation', r'^Calculating the route|^ROUTE ', None),
    ('route', 'routing', r'', r'^RoutingController'),
    ('gps', 'GPS spoofed', r'^GPS spoofed', None),
    ('gps', 'untrusted location', r'^Untrusted location|^Unsatisfied accuracy', None),
    ('gps', 'GPS off the roads', r'^GPS (has left|is off) the roads', None),
    ('gps', 'network location', r'[Nn]etwork (location|points)', None),
    ('gps', 'location ignored', r'^Not active, ignoring', None),
]
EVENT_KINDS = [(c, n, re.compile(t), re.compile(f) if f else None) for c, n, t, f in EVENT_KINDS]
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
    """(name, bytes) of the logs in files, folders and zips."""
    result = []
    for path in paths:
        if os.path.isdir(path):
            for folder, _, files in sorted(os.walk(path)):
                for f in sorted(files):
                    if LOG_NAME.search(f) and not NOT_LOG_NAME.match(f):
                        result += load_paths([os.path.join(folder, f)])
        else:
            with open(path, 'rb') as f:
                result += unpack(os.path.basename(path), f.read())
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
    """The lines of the logs of one platform in time order, and what they tell."""

    def __init__(self, platform, entries):
        self.platform = platform
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
        for t, level, _, tag, body in unique:
            self.classify(t, level, tag, body)
        self.row_times = [row['t'] for row in self.rows]
        self.event_times = [e['t'] for e in self.events]

    def classify(self, t, level, tag, body):
        source = SOURCE.match(body)
        file, func, text = (source.group(1), source.group(3), source.group(4)) if source else ('', '', body)
        if text.startswith('TRIP '):
            row = nogps_trip_log.parse_trip(text[len('TRIP '):])
            nogps_trip_log.add_error(row)
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
            position = LAT_LON.search(text)
            if position:
                event['lat'], event['lon'] = float(position.group(1)), float(position.group(2))
            self.events.append(event)

    def lines_between(self, start, end):
        return self.lines[bisect.bisect_left(self.times, start):bisect.bisect_right(self.times, end)]


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
        if gap > MISSING_TRIP_S * 1000:
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

    def summary(self):
        sources = {}
        for row in self.rows:
            sources[row.get('src', '-')] = sources.get(row.get('src', '-'), 0) + 1
        speeds = [x for row in self.rows for x in (num(row, 'speed'), num(row, 'gps_kmh')) if x is not None]
        severities = {}
        for a in self.anomalies:
            severities[a['severity']] = severities.get(a['severity'], 0) + 1
        errors = sorted(row['err_m'] for row in self.rows if 'err_m' in row and row.get('src') == 'INERTIAL')
        return dict(id=self.id, platform=self.group.platform, zone=self.group.zone, start=self.start, end=self.end,
                    driven=self.driven, km=round(distance_m(self.rows) / 1000, 2),
                    max_kmh=round(max(speeds)) if speeds else None, sources=sources, lines=len(self.rows),
                    events=len(self.events), anomalies=severities,
                    inertial_error_median=errors[len(errors) // 2] if errors else None)

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
                    errors=error_summary(self.rows), counts=counts, choice_switches=switches)

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
        """The trip driven again by an Android debug build: nogps-replay-out.txt against the trip."""
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
        return dict(stats=stats, stretches=stretches, track=track, events=events, day=day)


class Analysis:
    """The trips of all the logs given."""

    def __init__(self, sources, year=None):
        year = year or datetime.now().year
        entries = {}
        self.notes = []
        self.files = []
        for name, data in sources:
            for log_name, log_data in unpack(name, data):
                platform, lines, unknown = parse_file(log_name, log_data, year)
                if not platform:
                    self.notes.append('%s: not a log of the app' % log_name)
                    continue
                self.files.append(dict(name=log_name, platform=platform, lines=len(lines)))
                if unknown:
                    self.notes.append('%s: %d lines of a run without "Local time:", their time is unknown'
                                      % (log_name, unknown))
                entries.setdefault(platform, []).extend(lines)
        self.groups = [Group(platform, lines) for platform, lines in sorted(entries.items())]
        spans = sorted(((g, first, after, driven) for g in self.groups for first, after, driven in split(g)),
                       key=lambda s: s[0].rows[s[1]]['t'])
        self.trips = [Trip(i, *span) for i, span in enumerate(spans)]


# The report: what the viewer shows, as text.

STATE_GROUPS = [
    ('Position', ['src', 'lat', 'lon', 'acc', 'bear', 'age', 'markAge', 'fill']),
    ('Error from GPS', ['ref', 'err_m', 'along_m', 'across_m']),
    ('GPS', ['gpsst', 'gps_lat', 'gps_lon', 'gps_acc', 'gps_kmh', 'gps_bear', 'gps_age', 'gpsAge', 'spoofed', 'cmp']),
    ('Fused and network', ['fused_lat', 'fused_lon', 'fused_acc', 'fused_kmh', 'fused_bear', 'fused_age', 'net_lat',
                           'net_lon', 'net_acc', 'net_age']),
    ('Choice and route', ['choice', 'nav', 'left', 'rte']),
    ('Box', ['obd', 'link', 'box', 'bf', 'fw', 'ota', 'speed', 'sage']),
    ('Inertial', ['gyro', 'hdg', 'scale', 'table', 'rough', 'lag', 'boxacc', 'phoneacc', 'turn', 'odo', 'offm', 'offv',
                  'back', 'turning', 'ready', 'ring']),
    ('Road matching', ['road', 'lost', 'snap', 'snapwhy', 'rdiff', 'cand', 'fix', 'self', 'car', 'marks', 'others']),
]
# Fields that change every second: not marked as changed.
MOVING_FIELDS = {'lat', 'lon', 'gps_lat', 'gps_lon', 'fused_lat', 'fused_lon', 'age', 'gps_age', 'fused_age', 'odo',
                 'err_m', 'along_m', 'across_m'}
ROWS_FIELDS = 'src,err_m,along_m,speed,gps_kmh,hdg,gps_bear,road,lost,snapwhy'
# The lines of every second, left out of the log lines around a moment.
NOISY_LINE = re.compile(r' (LogTrip\(\): TRIP|\w+\(\): (ACCB|ACCB_BEFORE|ACC|GYRO) )')
EVENTS_AROUND_S = 30
LINES_AROUND_S = 5


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


def print_trips(analysis, stationary):
    for zone in sorted({t.group.zone for t in analysis.trips}):
        print('times of %s logs: %s' % ('iOS' if zone == 'UTC' else 'Android', zone))
    print('%3s  %-16s  %-12s %7s %5s  %-26s %7s  %-12s %s' % ('id', 'start', 'duration', 'km', 'max', 'sources',
                                                             'box err', 'anomalies', 'events'))
    for trip in analysis.trips:
        if not trip.driven and not stationary:
            continue
        s = trip.summary()
        total = sum(s['sources'].values())
        sources = ' '.join('%s %d%%' % (k, round(v * 100 / total)) for k, v in s['sources'].items())
        anomalies = '/'.join(str(s['anomalies'].get(k, 0)) for k in ('high', 'medium', 'low'))
        error = s['inertial_error_median']
        print('%3d  %-16s  %-12s %7.2f %5s  %-26s %7s  %-12s %d%s' % (
            trip.id, from_ms(trip.start).strftime('%Y-%m-%d %H:%M'), duration(trip.end - trip.start), s['km'],
            s['max_kmh'] if s['max_kmh'] is not None else '-', sources[:26],
            '%.0f m' % error if error is not None else '-', anomalies, s['events'], '' if trip.driven else ' stands'))
    print('anomalies: high/medium/low')
    for note in analysis.notes:
        print('note:', note)


def print_trip(trip):
    d = trip.details()
    print('trip %d, %s, times: %s' % (trip.id, trip.group.platform, trip.group.zone))
    print('%s – %s, %s, %.2f km, max %s km/h, %d TRIP lines, choice switches %d' % (
        from_ms(trip.start).strftime('%Y-%m-%d %H:%M:%S'), clock(trip.end), duration(trip.end - trip.start), d['km'],
        d['max_kmh'], d['lines'], d['choice_switches']))
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
    print('events:', ', '.join('%s %d' % kv for kv in sorted(by_name.items())) or 'none')
    print('anomalies:', len(trip.anomalies))
    for a in trip.anomalies:
        print('  %s %8s  %-6s  %s: %s' % (clock(a['start']), duration(a['end'] - a['start'] + 1000), a['severity'],
                                          a['kind'], short(a['text'], False)))


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
  trip    a trip: stats, error from GPS, counts, events, anomalies
  events  the events of a trip, --from/--to HH:MM[:SS], --cat road, --grep regex, --full
  state   every TRIP field at --at HH:MM[:SS], anomalies, events and log lines around it
  rows    TRIP fields second by second: --fields a,b,c, --every N s, --from/--to
  replay  the trip against a nogps-replay-out.txt: --replay file''',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=['trips', 'trip', 'events', 'state', 'rows', 'replay'])
    parser.add_argument('logs', nargs='+', help='app*.log, log.txt, logs.zip, log.zip or a folder of them')
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

    analysis = Analysis(load_paths(args.logs), args.year)
    if args.command == 'trips':
        return print_trips(analysis, args.all)
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
        nogps_replay.print_compare(result['stats'], result['day'], REPLAY_CHANGE_M)


if __name__ == '__main__':
    main()
