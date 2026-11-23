#!/usr/bin/env python3
"""The SQLite database of a phone-day of NonGPS Maps trip logs: the schema, the import and the open.

The text log stays the source of truth, the database is a cache derived from it: a schema we got wrong is made again
by importing the text anew, never migrated (SCHEMA_VERSION is checked on open). The schema is the contract between
the log and every tool: the importer maps the lines the core writes with a tag and, for a rule, an action or an event,
a stable name (libs/map/nogps/log_line.hpp), and *fails* on a line it cannot map -- an unknown tag, name or key, a
field that does not parse -- or on a LOGFMT it does not know, instead of skipping it. A parser that drifts from the
core (#463) cannot go unseen.

Not mapped: the ordinary lines of the application, which have no `ms=`; their sentences are not data. What the
replay needs from them, the box id, the Bluetooth state and the routes, is in a log only as sentences without a time
yet, so the tables below do not have them.

Tables (times are unix ms, UTC, as the core writes them):
  file        one row per log file: the LOGFMT line, the maps (the first MAPS line)
  trip        a run of TRIP lines without a pause of TRIP_SPLIT_S; the other lines belong to the trip they were
              written in, the ones before the first trip to the first one. in_check_set and check_reason are filled
              by the check set query, not by the import
  sample      a TRIP line: the shown position, the state of the core and of the box (TRIP_COLUMNS)
  fix         the positions of the platform of a TRIP line: gps (satellites only), fused, net
  sensor      ACC, ACCB (the accelerometers: v1..v3 the mean acceleration, v4 the jolt) and GYRO (v1 the rotation
              of the part, v2 the speed of the car, v3 the total rotation since the start) by the parts of a second;
              ms is the end of the second a line has, slice 0..4 the part. ACCB_BEFORE is ACCB at ms - the seconds
              written in it
  calibration the CALIBRATION lines: what the car had learned, as the core serializes it
  action      what the replay drives again: start, stop, gps_off, manual, tap, reverse, switch_mark, shift,
              restore_car. payload is the JSON of the keys of the line, text its sentence
  rule        the rules that move the mark, event what happened to the state of the core: the same
  note        BOXACC, TURN, RPM, POTHOLE, SPRINT and MAPS lines, the text after the tag
  check_result, baseline  filled by nogps_checks.py (empty here)
"""
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timezone

import nogps_trip_log

SCHEMA_VERSION = 1
# A pause between two TRIP lines that ends a trip: a standing car with the box connected writes one in 30 s, and
# nogps_log.py ends a trip by the pause of STAND_SPLIT_S.
TRIP_SPLIT_S = 300
# A TRIP line is written every second while the car moves and five more after it: a gap up to this long counts to
# the moving seconds of a trip.
MOVING_GAP_S = 2

TAGS = ('TRIP', 'ACC', 'ACCB', 'ACCB_BEFORE', 'GYRO', 'BOXACC', 'TURN', 'CALIBRATION', 'RPM', 'POTHOLE', 'SPRINT',
        'MAPS', 'RULE', 'ACTION', 'EVENT')
NOTE_TAGS = ('BOXACC', 'TURN', 'RPM', 'POTHOLE', 'SPRINT', 'MAPS')
RULES = frozenset((
    'road_lost late_turn turn_moved_to_crossing turn_followed_roads bend_confirmed bend_moved bend_moved_repeated '
    'loop fork_branch wait_ahead wait_at_roundabout roundabout_exit followed_apart back_on_road mark_switched_by_way '
    'far_mark_taken mark_switched_road_lost mark_switched_turn mark_switched_stand_lost mark_switched_by_user'
).split())
ACTIONS = frozenset('start stop gps_off manual tap reverse switch_mark shift restore_car'.split())
EVENTS = frozenset((
    'position_source gps_signal box_state box_ble peer_role gps_spoofed gps_untrusted gps_off_roads gps_trusted '
    'network_back manual_by_itself'
).split())
NAMES = {'RULE': RULES, 'ACTION': ACTIONS, 'EVENT': EVENTS}
CALIBRATION_KEYS = ('car', 'scale', 'table', 'rough', 'factor', 'unit', 'lag', 'accel')

# "... nogps/engine.cpp:1010 LogTrip(): TRIP ms=1763800000000 src=GPS ..."; the same on both platforms.
HEAD = re.compile(r'\(\): ([A-Z][A-Z_0-9]*)(?: ([a-z][a-z_0-9]*))? ms=(\d+)(?: (.*))?$')
KEY_VALUE = re.compile(r'^(\w+)=(\S*)$')
LAT_LON = re.compile(r'ms::LatLon\((-?[\d.]+), (-?[\d.]+)\)')
TAP = re.compile(r'tap = ms::LatLon\((-?[\d.]+), (-?[\d.]+)\) location = ms::LatLon\((-?[\d.]+), (-?[\d.]+)\) '
                 r'bearing = (-?[\d.]+)')
MAPS_VERSION = re.compile(r'version=(\S+)$')


class ImportError_(ValueError):
    """A line or a file that the schema has no place for."""


def number(text, kind=float):
    """The number of a field, None for what the core writes when it has none: "-" and "NaN"."""
    if text in ('-', 'NaN', ''):
        return None
    return kind(text)


def flag(text):
    if text not in ('0', '1'):
        raise ValueError('not 0 or 1: %r' % text)
    return int(text)


def text(value):
    return value


# The keys of a TRIP line that are a column of their own: key -> (column, type, SQL type). The others are in
# special(): pos, gps, fused, net, cmp, box, link, ota, lag, hdg, boxacc, phoneacc, bf, acc and age.
SIMPLE_KEYS = {
    'src': ('src', text, 'TEXT'), 'markAge': ('mark_age_s', number, 'REAL'), 'gpsAge': ('gps_age_s', number, 'REAL'),
    'fill': ('fill', int, 'INTEGER'), 'spoofed': ('spoofed', flag, 'INTEGER'), 'gpsst': ('gps_state', text, 'TEXT'),
    'nav': ('nav', flag, 'INTEGER'), 'left': ('left', text, 'TEXT'), 'rte': ('rte_m', number, 'REAL'),
    'obd': ('obd', text, 'TEXT'), 'speed': ('speed_kmh', int, 'INTEGER'), 'sage': ('speed_age_ms', int, 'INTEGER'),
    'fw': ('fw', text, 'TEXT'), 'rpm': ('rpm', int, 'INTEGER'), 'scale': ('scale', float, 'REAL'),
    'table': ('tbl', int, 'INTEGER'), 'factor': ('factor', float, 'REAL'), 'rough': ('rough', int, 'INTEGER'),
    'gyro': ('gyro', text, 'TEXT'), 'turn': ('turn_m', number, 'REAL'), 'road': ('road', flag, 'INTEGER'),
    'lost': ('lost', flag, 'INTEGER'), 'back': ('back', flag, 'INTEGER'), 'turning': ('turning', flag, 'INTEGER'),
    'odo': ('odo_m', float, 'REAL'), 'offm': ('off_m', float, 'REAL'), 'offv': ('off_kmh', float, 'REAL'),
    'cand': ('cand_m', number, 'REAL'), 'self': ('self_off', flag, 'INTEGER'), 'marks': ('marks', int, 'INTEGER'),
    'others': ('others', text, 'TEXT'), 'snap': ('snap_m', number, 'REAL'), 'rdiff': ('rdiff', number, 'REAL'),
    'snapwhy': ('snapwhy', text, 'TEXT'), 'wait': ('wait_m', number, 'REAL'), 'fix': ('fix_m', float, 'REAL'),
    'ready': ('ready', flag, 'INTEGER'), 'ring': ('ring', flag, 'INTEGER'),
}
SPECIAL_COLUMNS = (
    ('lat', 'REAL'), ('lon', 'REAL'), ('acc_m', 'REAL'), ('bearing', 'REAL'), ('age_s', 'REAL'),
    ('cmp_deg', 'REAL'), ('cmp_acc_deg', 'REAL'), ('cmp_age_s', 'REAL'), ('link', 'TEXT'), ('box_lines', 'INTEGER'),
    ('box_gap_ms', 'INTEGER'), ('box_flags', 'INTEGER'), ('ota', 'TEXT'), ('ota_pct', 'INTEGER'), ('lag', 'REAL'),
    ('lag_default', 'INTEGER'), ('hdg', 'REAL'), ('hdg_src', 'TEXT'), ('boxacc_corr', 'REAL'),
    ('boxacc_ahead_m', 'REAL'), ('phoneacc_corr', 'REAL'), ('phoneacc_ahead_m', 'REAL'), ('car_lat', 'REAL'),
    ('car_lon', 'REAL'))
TRIP_COLUMNS = ([(column, sql) for column, _, sql in SIMPLE_KEYS.values()] + list(SPECIAL_COLUMNS))
# gps=, fused= and net= are rows of fix.
FIX_KINDS = ('gps', 'fused', 'net')

SCHEMA = '''
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE file(
  id INTEGER PRIMARY KEY, phone TEXT NOT NULL, day TEXT NOT NULL, name TEXT NOT NULL, logfmt INTEGER NOT NULL,
  trip_name TEXT NOT NULL, header_ms INTEGER NOT NULL, app_version TEXT, build TEXT, build_commit TEXT,
  om_version TEXT, map_version TEXT, imported_at INTEGER NOT NULL);
CREATE TABLE trip(
  id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES file(id), started_ms INTEGER NOT NULL,
  ended_ms INTEGER NOT NULL, moving_s REAL NOT NULL, in_check_set INTEGER, check_reason TEXT);
CREATE TABLE sample(trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, %s);
CREATE TABLE fix(
  trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, kind TEXT NOT NULL, lat REAL NOT NULL,
  lon REAL NOT NULL, acc_m REAL, kmh REAL, bearing REAL, bearing_acc_deg REAL, age_s REAL);
CREATE TABLE sensor(
  trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, kind TEXT NOT NULL, slice INTEGER NOT NULL,
  v1 REAL, v2 REAL, v3 REAL, v4 REAL);
CREATE TABLE calibration(
  trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, car TEXT, scale REAL, tbl TEXT, rough TEXT,
  factor TEXT, unit TEXT, lag TEXT, accel TEXT);
CREATE TABLE action(
  trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
  text TEXT NOT NULL);
CREATE TABLE rule(
  trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, name TEXT NOT NULL, payload TEXT NOT NULL,
  text TEXT NOT NULL);
CREATE TABLE event(
  trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, name TEXT NOT NULL, payload TEXT NOT NULL,
  text TEXT NOT NULL);
CREATE TABLE note(trip_id INTEGER NOT NULL REFERENCES trip(id), ms INTEGER NOT NULL, tag TEXT NOT NULL,
  text TEXT NOT NULL);
CREATE TABLE check_result(
  trip_id INTEGER NOT NULL REFERENCES trip(id), "check" TEXT NOT NULL, passed INTEGER NOT NULL, value REAL,
  run_at INTEGER NOT NULL, PRIMARY KEY(trip_id, "check"));
CREATE TABLE baseline(
  trip_id INTEGER NOT NULL REFERENCES trip(id), metric TEXT NOT NULL, value REAL NOT NULL,
  accepted_at INTEGER NOT NULL, PRIMARY KEY(trip_id, metric));
CREATE INDEX sample_ms ON sample(trip_id, ms);
CREATE INDEX fix_ms ON fix(trip_id, ms);
CREATE INDEX sensor_ms ON sensor(trip_id, ms);
CREATE INDEX calibration_ms ON calibration(trip_id, ms);
CREATE INDEX action_ms ON action(trip_id, ms);
CREATE INDEX rule_ms ON rule(trip_id, ms);
CREATE INDEX event_ms ON event(trip_id, ms);
CREATE INDEX note_ms ON note(trip_id, ms);
''' % ', '.join('%s %s' % c for c in TRIP_COLUMNS)


def parse_fix(value):
    """"lat,lon/accuracy/km/h/course/age/accuracy of the course" of gps= and fused=, the last may be missing (a log of
    before it was written); net= is "lat,lon" with acc= and age= after it."""
    lat_lon, *rest = value.split('/')
    lat, lon = lat_lon.split(',')
    rest = [number(v) for v in rest]
    if len(rest) > 5:
        raise ValueError('too many fields')
    return [float(lat), float(lon)] + rest + [None] * (5 - len(rest))


def parse_trip(body):
    """The sample row (a dictionary of columns) and the fix rows [(kind, lat, lon, acc, kmh, bearing, bearing_acc,
    age)] of the fields of a TRIP line."""
    row = {}
    fixes = {}
    after_net = False
    for token in body.split():
        key, eq, value = token.partition('=')
        if not eq:
            raise ValueError('not a key=value: %r' % token)
        if key == 'net':
            lat, lon = value.split(',')
            fixes['net'] = {'lat': float(lat), 'lon': float(lon)}
            after_net = True
        elif after_net and key in ('acc', 'age'):
            fixes['net'][key] = number(value)
        elif key == 'pos':
            row['lat'], row['lon'] = (float(v) for v in value.split(','))
        elif key == 'acc':
            row['acc_m'] = number(value)
        elif key == 'age':
            row['age_s'] = number(value)
        elif key == 'bear':
            row['bearing'] = number(value)
        elif key in ('gps', 'fused'):
            fixes[key] = dict(zip(('lat', 'lon', 'acc', 'kmh', 'bear', 'age', 'bear_acc'), parse_fix(value)))
        elif key == 'cmp':
            row['cmp_deg'], row['cmp_acc_deg'], row['cmp_age_s'] = (number(v) for v in value.split('/'))
        elif key == 'link':
            row['link'] = value
        elif key == 'box':
            row['box_lines'], row['box_gap_ms'] = (int(v) for v in value.split('/'))
        elif key == 'bf':
            row['box_flags'] = int(value, 16)
        elif key == 'ota':
            state, pct = value.split('/')
            row['ota'], row['ota_pct'] = state, int(pct)
        elif key == 'lag':
            lag, _, default = value.partition('/')
            if default not in ('', 'DEFAULT'):
                raise ValueError('lag: %r' % value)
            row['lag'], row['lag_default'] = float(lag), int(bool(default))
        elif key == 'hdg':
            heading, source = value.split('/')
            row['hdg'], row['hdg_src'] = number(heading), source
        elif key in ('boxacc', 'phoneacc'):
            corr, ahead = value.split('/')
            row[key[:-3] + 'acc_corr'] = float(corr)
            row[key[:-3] + 'acc_ahead_m'] = number(ahead)
        elif key == 'car':
            row['car_lat'], row['car_lon'] = (float(v) for v in value.split(','))
        elif key in SIMPLE_KEYS:
            column, convert, _ = SIMPLE_KEYS[key]
            row[column] = convert(value)
        else:
            raise ValueError('unknown key %s' % key)
    return row, fixes


def split_keys(rest):
    """The key=value tokens at the start of |rest| as a dictionary, and the sentence that follows them."""
    keys = {}
    words = (rest or '').split(' ')
    i = 0
    while i < len(words):
        m = KEY_VALUE.match(words[i])
        if not m:
            break
        keys[m.group(1)] = m.group(2)
        i += 1
    return keys, ' '.join(words[i:])


class Line:
    """A line of the file the importer has mapped: its time, its table and the values of its row."""

    def __init__(self, ms, tag, name, rest):
        self.ms, self.tag, self.name, self.rest = ms, tag, name, rest


def parse_line(line):
    """The Line of a log line, None for a line without a tag and "ms=": an ordinary line of the application. The
    machine lines are checked here: ValueError says what is wrong with one."""
    m = HEAD.search(line)
    if not m:
        return None
    tag, name, ms, rest = m.group(1), m.group(2), int(m.group(3)), m.group(4) or ''
    if tag not in TAGS:
        raise ValueError('unknown tag %s' % tag)
    if tag in NAMES:
        if name not in NAMES[tag]:
            raise ValueError('unknown %s name %s' % (tag.lower(), name))
    elif name:
        raise ValueError('%s has no name, got %s' % (tag, name))
    return Line(ms, tag, name, rest)


def sensor_rows(line):
    """[(ms, kind, slice, v1..v4)] of an ACC, ACCB, ACCB_BEFORE or GYRO line."""
    tag, rest, ms = line.tag, line.rest, line.ms
    if tag == 'GYRO':
        values = rest.split()
        if len(values) != 11:
            raise ValueError('GYRO has %d values, expected 11' % len(values))
        total = float(values[0])
        return [(ms, 'gyro', i, float(values[1 + i]), float(values[6 + i]), total, None) for i in range(5)]
    kind = 'acc' if tag == 'ACC' else 'accb'
    if tag == 'ACCB_BEFORE':
        before, _, rest = rest.partition(' ')
        ms -= int(before) * 1000
    slices = rest.split()
    if len(slices) != 5:
        raise ValueError('%s has %d slices, expected 5' % (tag, len(slices)))
    rows = []
    for i, part in enumerate(slices):
        values = [float(v) for v in part.split(',')]
        if len(values) != 4:
            raise ValueError('%s slice %d has %d values, expected 4' % (tag, i, len(values)))
        rows.append((ms, kind, i, *values))
    return rows


def action_payload(line):
    keys, sentence = split_keys(line.rest)
    if line.name == 'tap':
        m = TAP.search(sentence)
        if not m:
            raise ValueError('tap has no positions')
        keys.update(zip(('tap_lat', 'tap_lon', 'lat', 'lon', 'bearing'), m.groups()))
    elif line.name == 'restore_car':
        if ' = ' not in sentence:
            raise ValueError('restore_car has no car')
    elif line.name in ('gps_off', 'manual'):
        flag_key = 'disabled' if line.name == 'gps_off' else 'enabled'
        if keys.get(flag_key) not in ('0', '1') or not keys.get('by'):
            raise ValueError('%s needs %s= and by=' % (line.name, flag_key))
    elif line.name == 'shift':
        number(keys.get('m', ''), int)
        if 'm' not in keys:
            raise ValueError('shift needs m=')
    return keys, sentence


def calibration_row(line):
    keys, sentence = split_keys(line.rest)
    unknown = set(keys) - set(CALIBRATION_KEYS)
    if unknown or sentence or 'car' not in keys:
        raise ValueError('CALIBRATION with keys %s %r' % (sorted(keys), sentence))
    return (None if keys['car'] == '-' else keys['car'], float(keys['scale']) if 'scale' in keys else None,
            keys.get('table'), keys.get('rough'), keys.get('factor'), keys.get('unit'), keys.get('lag'),
            keys.get('accel'))


def split_trips(trip_ms):
    """[(first index, last index)] of the runs of the sorted times |trip_ms| without a pause of TRIP_SPLIT_S."""
    runs = []
    for i, ms in enumerate(trip_ms):
        if runs and ms - trip_ms[i - 1] <= TRIP_SPLIT_S * 1000:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    return runs


def read_file(path, data, header):
    """The mapped lines of a file: ImportError_ with the file and the line number for the first that can't be."""
    lines = []
    for number_, raw in enumerate(data.decode('utf-8', errors='replace').split('\n'), 1):
        raw = raw.rstrip('\r')
        try:
            line = parse_line(raw)
            if line is None:
                continue
            if line.tag == 'TRIP':
                line.row, line.fixes = parse_trip(line.rest)
            elif line.tag in ('ACC', 'ACCB', 'ACCB_BEFORE', 'GYRO'):
                line.rows = sensor_rows(line)
            elif line.tag == 'CALIBRATION':
                line.row = calibration_row(line)
            elif line.tag in ('ACTION', 'RULE', 'EVENT'):
                line.keys, line.sentence = action_payload(line) if line.tag == 'ACTION' else split_keys(line.rest)
            elif line.tag == 'MAPS':
                if not MAPS_VERSION.match(line.rest):
                    raise ValueError('MAPS has no version=')
            lines.append(line)
        except ValueError as e:
            raise ImportError_('%s:%d: %s: %s' % (path, number_, e, raw[:200])) from None
    return lines


def insert_file(conn, path, data, phone, day, imported_at):
    header = nogps_trip_log.header_of(path, data)
    if header['logfmt'] is None:
        raise ImportError_('%s: no LOGFMT line, nothing to import (the OSLog text of iOS has no machine lines)' % path)
    lines = read_file(path, data, header)
    maps = next((MAPS_VERSION.match(line.rest).group(1) for line in lines if line.tag == 'MAPS'), None)
    file_id = conn.execute(
        'INSERT INTO file(phone, day, name, logfmt, trip_name, header_ms, app_version, build, build_commit, '
        'om_version, map_version, imported_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
        (phone, day, os.path.basename(path), header['logfmt'], header['trip'], int(header['ms']),
         header.get('app'), header.get('build'), header.get('commit'), header.get('om'), maps, imported_at)).lastrowid

    # The sort is stable, so the lines of one millisecond keep the order of the file.
    lines.sort(key=lambda line: line.ms)
    trips = [line for line in lines if line.tag == 'TRIP']
    runs = split_trips([line.ms for line in trips])
    if runs:
        bounds = [(trips[a].ms, trips[b].ms) for a, b in runs]
        moving = [sum(min(y.ms - x.ms, MOVING_GAP_S * 1000) for x, y in zip(trips[a:b], trips[a + 1:b + 1])
                      if y.ms - x.ms <= MOVING_GAP_S * 1000) / 1000 for a, b in runs]
    else:
        bounds = [(lines[0].ms, lines[-1].ms) if lines else (int(header['ms']), int(header['ms']))]
        moving = [0.0]
    trip_ids = [conn.execute('INSERT INTO trip(file_id, started_ms, ended_ms, moving_s) VALUES (?,?,?,?)',
                             (file_id, start, end, m)).lastrowid for (start, end), m in zip(bounds, moving)]
    starts = [start for start, _ in bounds]

    def trip_of(ms):
        i = max(0, sum(s <= ms for s in starts) - 1)
        return trip_ids[i]

    for line in lines:
        trip_id = trip_of(line.ms)
        if line.tag == 'TRIP':
            row = dict(line.row, src=line.row.get('src'))
            columns = ['trip_id', 'ms'] + list(row)
            conn.execute('INSERT INTO sample(%s) VALUES (%s)' % (','.join(columns), ','.join('?' * len(columns))),
                         [trip_id, line.ms] + list(row.values()))
            for kind, fix in line.fixes.items():
                conn.execute('INSERT INTO fix VALUES (?,?,?,?,?,?,?,?,?,?)',
                             (trip_id, line.ms, kind, fix['lat'], fix['lon'], fix.get('acc'), fix.get('kmh'),
                              fix.get('bear'), fix.get('bear_acc'), fix.get('age')))
        elif line.tag in ('ACC', 'ACCB', 'ACCB_BEFORE', 'GYRO'):
            conn.executemany('INSERT INTO sensor VALUES (?,?,?,?,?,?,?,?)',
                             [(trip_id,) + row for row in line.rows])
        elif line.tag == 'CALIBRATION':
            conn.execute('INSERT INTO calibration VALUES (?,?,?,?,?,?,?,?,?,?)', (trip_id, line.ms) + line.row)
        elif line.tag == 'ACTION':
            conn.execute('INSERT INTO action VALUES (?,?,?,?,?)',
                         (trip_id, line.ms, line.name, json.dumps(line.keys, sort_keys=True), line.sentence))
        elif line.tag in ('RULE', 'EVENT'):
            conn.execute('INSERT INTO %s VALUES (?,?,?,?,?)' % line.tag.lower(),
                         (trip_id, line.ms, line.name, json.dumps(line.keys, sort_keys=True), line.sentence))
        else:
            conn.execute('INSERT INTO note VALUES (?,?,?,?)', (trip_id, line.ms, line.tag, line.rest))


def import_day(files, db_path, phone, day):
    """Writes the database |db_path| of the log |files| of |phone| on |day|: [(path, bytes)]. The old database is
    replaced only when the import has succeeded as a whole."""
    folder = os.path.dirname(os.path.abspath(db_path))
    os.makedirs(folder, exist_ok=True)
    handle, tmp = tempfile.mkstemp(suffix='.sqlite', dir=folder)
    os.close(handle)
    try:
        conn = sqlite3.connect(tmp)
        conn.executescript(SCHEMA)
        conn.execute('INSERT INTO meta VALUES (?, ?)', ('schema_version', str(SCHEMA_VERSION)))
        imported_at = int(time.time() * 1000)
        for path, data in sorted(files):
            insert_file(conn, path, data, phone, day, imported_at)
        conn.commit()
        conn.close()
        os.replace(tmp, db_path)
    except BaseException:
        try:
            conn.close()
        except (NameError, sqlite3.Error):
            pass
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def tree_days(paths):
    """{(phone, day): [file, …]} of the logs of the paths, the phone from the LOGFMT line of each file and the day
    from its folder in logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log. A file without a LOGFMT line (the OSLog text of iOS) is
    skipped with a note; any other file that can't be read is an error."""
    result = {}
    for path in nogps_trip_log.log_files(paths):
        header = nogps_trip_log.read_header(path)
        if header['logfmt'] is None:
            print('%s: no LOGFMT line (OSLog text), skipped' % path, file=sys.stderr)
            continue
        tree = nogps_trip_log.tree_path(path)
        if not tree:
            raise ImportError_('%s: not in logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log' % path)
        day = re.search(r'/(\d{4}-\d\d-\d\d)/[^/]+$', os.path.abspath(path).replace('\\', '/')).group(1)
        result.setdefault((header['phone'], day), []).append(path)
    return result


def db_name(phone, day):
    return '%s-%s.sqlite' % (phone, day)


def import_tree(paths, out_dir):
    """Imports every phone-day of the logs of |paths| into |out_dir|. Returns [(database path, files)]. An error
    stops the import at the day it is in; the days before it are kept."""
    result = []
    for (phone, day), files in sorted(tree_days(paths).items()):
        data = []
        for path in files:
            with open(path, 'rb') as f:
                data.append((path, f.read()))
        db_path = os.path.join(out_dir, db_name(phone, day))
        import_day(data, db_path, phone, day)
        result.append((db_path, files))
    return result


def open_db(path):
    """The connection to a database, read as rows with names. A database of another SCHEMA_VERSION is refused:
    import the text again."""
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        version = conn.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
    except sqlite3.DatabaseError as e:
        conn.close()
        raise ImportError_('%s is not a database of the tools: %s' % (path, e)) from None
    if not version or int(version[0]) != SCHEMA_VERSION:
        conn.close()
        raise ImportError_('%s has schema %s, the tools read %d: import the logs again'
                           % (path, version[0] if version else None, SCHEMA_VERSION))
    return conn


def utc(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
