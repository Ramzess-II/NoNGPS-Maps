#!/usr/bin/env python3
"""Converts the TRIP lines of a NonGPS Maps log to CSV to analyse a drive.

The navigation core writes a TRIP line every second while the car moves, once in 30 s while it stands: the shown
position, the positions of the platform (gps= satellites only, Android; fused= CoreLocation on iOS, Google fused on
Android) and the state of the inertial navigation. The error of the shown position is measured against the platform position, gps= if
there is one, at the same moment (the two have different ages): along the course of the car (+ the mark is ahead)
and across it (+ the mark is to the right). With "Disable GPS" on, the platform position is the car itself. A fix
over REF_MAX_ACCURACY_M, or one that stands while the car drives, gives no error: err_why= tells which.

Logs: logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log, written with "Enable logging" on in the settings: a file per launch
of the app and per drive. A folder given is read with its subfolders: give the folder of one phone, or of one day of
it, as the rows of two phones would be mixed. Every file begins with the LOGFMT line that tells its phone, except
the OSLog text of iOS, whose phone comes from its path; a file of another layout, or of a format the tools do not
know, is refused. The names of the earlier versions (log-dd-MM-yy-<phone>.log, log.txt, app*.log) are not read.
  iOS: Documents/logs/. Times are UTC.
  Android: Android/data/<app id>/files/logs/, or the zip of "Report a bug" unpacked. Times are the local time of
  the phone, the log has no year: --year.

Usage:
  nogps_trip_log.py logs/iPhone15_2-a3f9/2026-11-01 [more logs] > trip.csv
  nogps_trip_log.py logs/iPhone15_2-a3f9 --gpx trip.gpx > trip.csv    # the shown and the platform tracks to see on a map
"""

import argparse
import bisect
import csv
import math
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# "I(1) 12.34567 nogps/engine.cpp:1010 LogTrip(): TRIP ...": seconds since the launch of the app.
IOS_PREFIX = re.compile(r'\w\(\d+\) (\d+\.\d+) ')
IOS_START = re.compile(r'Local time: (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \+0000')
# "10-08 18:51:32.123 (main) I/OM: TRIP ...".
ANDROID_PREFIX = re.compile(r'(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) ')
# The fields of a TRIP line; since LOGFMT 2 "ms=<unix ms>" comes first, see libs/map/nogps/log_line.hpp.
TRIP_LINE = re.compile(r' TRIP (?:ms=\d+ )?(?=src=)')
# gps= and fused= are "lat,lon/accuracy/km/h/course/age".
PLATFORM_FIELDS = ('acc', 'kmh', 'bear', 'age')
EARTH_RADIUS_M = 6371000
# The error is measured only against a fix this accurate: a Wi-Fi or cell position of hundreds of metres says
# nothing about the mark.
REF_MAX_ACCURACY_M = 30
# New fixes that stay within REF_STALE_MOVE_M while the car drives REF_STALE_DRIVEN_M by its own speed are stale: iOS
# repeats the last Wi-Fi position in a covered car park with a fresh age and a fair accuracy.
REF_STALE_MOVE_M = 5
REF_STALE_DRIVEN_M = 30
# A fix without a speed or a course is not measured while the car drives at least this fast: add_error() can't move
# it on by its age, and such fixes are Wi-Fi or cell positions that lag behind the car.
REF_NO_COURSE_MAX_KMH = 3
# The speed of a line counts for the seconds until the next one, at most this many: a gap is no drive.
REF_STALE_MAX_GAP_S = 5
LOG_NAME = re.compile(r'\.log$', re.I)
# Android "Report a bug" saves the system log next to the logs of the app; a replay writes its files.
NOT_LOG_NAME = re.compile(r'^(logcat|nogps-replay)', re.I)
# The formats of the first line of a log, "LOGFMT <n> ms=<unix ms> phone=<id> trip=<HHmmss> app=<version> build=<number>
# commit=<hash> om=<Organic Maps version>", see libs/map/nogps/log_line.hpp. A tool refuses any other.
LOG_FORMATS = (2,)
LOGFMT_LINE = re.compile(r'LOGFMT (\d+)((?: \w+=\S*)*)\s*$')
HEADER_KEYS = ('ms', 'phone', 'trip')
# "logs/Pixel_7-a3f9/2026-11-01/081500.log": the phone and the time the file was started at. iOS with the record in a
# file off writes the OSLog text of "Report a bug" into such a file without the LOGFMT line (Logger.mm), so a file of
# the tree is read with the phone of its path. "." and ".." are no phone, see tree_path().
TREE_PATH = re.compile(r'(?:^|/)(?!\.\.?/)([^/]+)/\d{4}-\d\d-\d\d/(\d{6}(?:-\d+)?)\.log$', re.I)
FIRST_COLUMNS = ['time', 'src', 'lat', 'lon', 'acc', 'bear', 'age', 'ref', 'err_m', 'along_m', 'across_m',
                 'err_why']


def log_files(paths, log_name=LOG_NAME):
    """The files of the paths: a folder gives the logs in it and in its subfolders in the order of their names, as
    logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log are kept."""
    result = []
    for path in paths:
        if os.path.isdir(path):
            for folder, _, files in sorted(os.walk(path)):
                result += [os.path.join(folder, f) for f in sorted(files)
                           if log_name.search(f) and not NOT_LOG_NAME.match(f)]
        else:
            result.append(path)
    return result


class LogFormatError(ValueError):
    """A file that is not a log of a format the tools read."""


def tree_path(name):
    """The match of logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log in |name|, None when it is not such a path. A file on disk
    is matched by its absolute path: the <phone> folder can be above the path given, as it is for "." and for
    "<yyyy-MM-dd>/<HHmmss>.log" given inside the folder of one phone."""
    if os.path.isfile(name):
        name = os.path.abspath(name)
    return TREE_PATH.search(name.replace('\\', '/'))


def parse_header(name, first_line):
    """The fields of the LOGFMT line of the file |name| as a dictionary of strings, with 'logfmt' the number: the file
    identifies itself. A file of the tree without that line is the OSLog text of iOS, and its path tells the phone and
    the time it was started at; 'logfmt' is then None. LogFormatError for any other file that has no such line, one of
    a format not in LOG_FORMATS, or one that lacks a field the tools need."""
    m = LOGFMT_LINE.match(first_line.lstrip('\ufeff').rstrip('\r\n'))
    if not m:
        tree = tree_path(name)
        if tree:
            return dict(logfmt=None, ms=None, phone=tree.group(1), trip=tree.group(2))
        hint = ''
        if re.fullmatch(r'\d{6}(?:-\d+)?\.log', re.split(r'[/\\]', name)[-1], re.I):
            hint = ('; an OSLog text of iOS is read from logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log: '
                    'give the logs.zip or the folder')
        raise LogFormatError('%s: not a log of LOGFMT %s, its first line is not a LOGFMT line (logs of the earlier '
                             'versions are not read%s)' % (name, ', '.join(map(str, LOG_FORMATS)), hint))
    if int(m.group(1)) not in LOG_FORMATS:
        raise LogFormatError('%s: LOGFMT %s is not known, the tools read %s' % (
            name, m.group(1), ', '.join(map(str, LOG_FORMATS))))
    header = dict(token.split('=', 1) for token in m.group(2).split())
    missing = [key for key in HEADER_KEYS if not header.get(key)]
    if missing:
        raise LogFormatError('%s: the LOGFMT line has no %s' % (name, ', '.join(missing)))
    header['logfmt'] = int(m.group(1))
    return header


def header_of(name, data):
    """parse_header() of the bytes of a file."""
    return parse_header(name, data[:4096].decode('utf-8', errors='replace').split('\n', 1)[0])


def read_header(path):
    with open(path, 'rb') as f:
        return header_of(path, f.read(4096))


def readable_files(paths):
    """log_files() without the files of no known format, each skipped with a note on stderr; LogFormatError when none
    can be read."""
    result = []
    errors = []
    for path in log_files(paths):
        try:
            read_header(path)
            result.append(path)
        except LogFormatError as e:
            errors.append(e)
    if errors and not result:
        raise errors[0]
    for e in errors:
        print(f'Skipped: {e}', file=sys.stderr)
    return result


def files_by_phone(paths):
    """{phone: [file, …]} of the log files of the paths, a folder with its subfolders; each file's own header tells
    its phone. A file that can't be placed is skipped as in readable_files()."""
    result = {}
    for path in readable_files(paths):
        result.setdefault(read_header(path)['phone'], []).append(path)
    return result


def parse_time(line, launch, year):
    """Returns the time of a log line, None if unknown. Keeps the time of the iOS app launch in |launch|."""
    m = ANDROID_PREFIX.match(line)
    if m:
        return datetime.strptime(f'{year}-{m.group(1)}', '%Y-%m-%d %H:%M:%S.%f')
    m = IOS_PREFIX.match(line)
    if not m:
        return None
    since_launch = timedelta(seconds=float(m.group(1)))
    start = IOS_START.search(line, m.end())
    if start:
        launch[0] = datetime.strptime(start.group(1), '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc) - since_launch
    return launch[0] + since_launch if launch[0] else None


def parse_trip(text):
    row = {}
    after_net = False
    for token in text.split():
        key, _, value = token.partition('=')
        if key == 'net':
            after_net = True
        elif after_net and key in ('acc', 'age'):
            key = 'net_' + key
        if key in ('pos', 'net'):
            prefix = '' if key == 'pos' else 'net_'
            row[prefix + 'lat'], row[prefix + 'lon'] = value.split(',')
        elif key in ('gps', 'fused'):
            lat_lon, *rest = value.split('/')
            row[key + '_lat'], row[key + '_lon'] = lat_lon.split(',')
            row.update((f'{key}_{name}', v) for name, v in zip(PLATFORM_FIELDS, rest))
        else:
            row[key] = value
    return row


def number(row, key):
    try:
        return float(row[key])
    except (KeyError, ValueError):
        return None


def offset_m(lat, lon, ref_lat, ref_lon):
    """(east, north) of lat,lon from ref_lat,ref_lon, metres."""
    return (math.radians(lon - ref_lon) * math.cos(math.radians(ref_lat)) * EARTH_RADIUS_M,
            math.radians(lat - ref_lat) * EARTH_RADIUS_M)


class ErrorMeter:
    """Adds the error of the shown position from the platform fix to the TRIP rows of one phone, in time order.
    ref= is the fix measured against: gps= if it is accurate, else fused=. err_why= tells why a row with a fix has
    no error: 'coarse' (no fix within REF_MAX_ACCURACY_M), 'stale' (new fixes stood while the car drove) or
    'nocourse' (a fix without a speed or a course while the car drives). One old fix repeated with a growing age is
    not stale: add_error() moves it on by its age and course."""

    def __init__(self):
        # Of gps and fused apart, as ref= switches between them: where and since when the fixes stand, the time of
        # the last fix (the time of its row less its age) and whether they are stale.
        self.fixes = {}
        self.odometer = [(-math.inf, 0.0)]  # (seconds, metres driven by the car's speed) at each row.
        self.kmh = None

    def add(self, row, seconds):
        self.drive(seconds)
        self.kmh = number(row, 'speed')
        refs = [r for r in ('gps', 'fused') if r + '_lat' in row]
        if not refs:
            return
        accurate = [r for r in refs if (number(row, r + '_acc') or 0) <= REF_MAX_ACCURACY_M]
        ref = (accurate or refs)[0]
        row['ref'] = ref
        lat, lon = float(row[ref + '_lat']), float(row[ref + '_lon'])
        fix_time = seconds - (number(row, ref + '_age') or 0)
        fix = self.fixes.get(ref)
        if fix is None or math.hypot(*offset_m(lat, lon, fix['lat'], fix['lon'])) > REF_STALE_MOVE_M:
            fix = self.fixes[ref] = dict(lat=lat, lon=lon, since=fix_time, stale=False)
        elif abs(fix_time - fix['time']) > 0.5:
            fix['stale'] = self.driven_at(fix_time) - self.driven_at(fix['since']) > REF_STALE_DRIVEN_M
        fix['time'] = fix_time
        if not accurate:
            row['err_why'] = 'coarse'
        elif fix['stale']:
            row['err_why'] = 'stale'
        elif ((self.kmh or 0) >= REF_NO_COURSE_MAX_KMH
              and (number(row, ref + '_kmh') is None or number(row, ref + '_bear') is None)):
            row['err_why'] = 'nocourse'
        else:
            add_error(row, ref)

    def drive(self, seconds):
        last_seconds, driven = self.odometer[-1]
        if self.kmh is not None and self.kmh > 0:
            driven += self.kmh / 3.6 * min(max(0.0, seconds - last_seconds), REF_STALE_MAX_GAP_S)
        self.odometer.append((seconds, driven))

    def driven_at(self, seconds):
        i = bisect.bisect_right(self.odometer, (seconds, math.inf))
        if i >= len(self.odometer):
            return self.odometer[-1][1]
        (t0, d0), (t1, d1) = self.odometer[i - 1], self.odometer[i]
        return d0 if t0 == -math.inf else d0 + (d1 - d0) * (seconds - t0) / (t1 - t0)


def add_error(row, ref):
    if 'lat' not in row:
        return
    ref_lat = float(row[ref + '_lat'])
    dx, dy = offset_m(float(row['lat']), float(row['lon']), ref_lat, float(row[ref + '_lon']))
    kmh, course = number(row, ref + '_kmh'), number(row, ref + '_bear')
    if kmh is None or course is None:
        row['err_m'] = round(math.hypot(dx, dy), 1)
        return
    c = math.radians(course)
    # The car has moved on by the difference of the ages.
    along = dx * math.sin(c) + dy * math.cos(c) + kmh / 3.6 * (number(row, 'age') - number(row, ref + '_age'))
    across = dx * math.cos(c) - dy * math.sin(c)
    row.update(err_m=round(math.hypot(along, across), 1), along_m=round(along, 1), across_m=round(across, 1))


def read_rows(paths, year):
    rows = []
    for path in paths:
        launch = [None]
        with open(path, encoding='utf-8', errors='replace') as log:
            for line in log:
                time = parse_time(line, launch, year)
                trip = TRIP_LINE.search(line)
                if time is None or not trip:
                    continue
                row = parse_trip(line[trip.end():])
                row['time'] = time
                rows.append(row)
    rows.sort(key=lambda row: row['time'])
    meter = ErrorMeter()
    for row in rows:
        meter.add(row, row['time'].timestamp())
    for row in rows:
        row['time'] = row['time'].isoformat(timespec='milliseconds')
    return rows


def write_gpx(path, rows):
    def track(name, points):
        trkpts = ''.join(f'<trkpt lat="{lat}" lon="{lon}"><time>{time}</time></trkpt>\n' for lat, lon, time in points)
        return f'<trk><name>{name}</name><trkseg>\n{trkpts}</trkseg></trk>\n'

    shown = [(r['lat'], r['lon'], r['time']) for r in rows if 'lat' in r]
    platform = [(r[r['ref'] + '_lat'], r[r['ref'] + '_lon'], r['time']) for r in rows if 'ref' in r]
    with open(path, 'w', encoding='utf-8') as gpx:
        gpx.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                  '<gpx version="1.1" creator="nogps_trip_log" xmlns="http://www.topografix.com/GPX/1/1">\n')
        gpx.write(track('Shown position', shown) + track('Platform position', platform) + '</gpx>\n')


def print_summary(rows):
    by_source = {}
    for row in rows:
        by_source.setdefault(row.get('src'), []).append(row)
    for source, source_rows in by_source.items():
        text = f'{source}: {len(source_rows)} lines'
        errors = sorted(float(r['err_m']) for r in source_rows if 'err_m' in r)
        if errors:
            text += (f', error median {errors[len(errors) // 2]} m, 90% {errors[len(errors) * 9 // 10]} m,'
                     f' max {errors[-1]} m')
        along = sorted(float(r['along_m']) for r in source_rows if 'along_m' in r)
        if along:
            text += f', along median {along[len(along) // 2]:+} m'
        print(text, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('logs', nargs='+')
    parser.add_argument('--year', type=int, default=datetime.now().year, help='the year of an Android log')
    parser.add_argument('--gpx', help='also write the shown and the platform positions as GPX tracks')
    args = parser.parse_args()

    try:
        by_phone = files_by_phone(args.logs)
    except LogFormatError as e:
        parser.error(str(e))
    if len(by_phone) > 1:
        parser.error('the logs of %s: give the logs of one phone, their rows and tracks would be mixed'
                     % ', '.join(sorted(by_phone)))
    rows = read_rows([path for paths in by_phone.values() for path in paths], args.year)
    columns = FIRST_COLUMNS + list(dict.fromkeys(k for row in rows for k in row if k not in FIRST_COLUMNS))
    out = csv.DictWriter(sys.stdout, columns)
    out.writeheader()
    out.writerows(rows)
    if args.gpx:
        write_gpx(args.gpx, rows)
    print_summary(rows)


if __name__ == '__main__':
    main()
