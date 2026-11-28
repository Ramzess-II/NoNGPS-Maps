#!/usr/bin/env python3
"""Tests of nogps_log.py on made-up logs: the places are not real.

  python3 tools/python/nogps_log_test.py
"""

import argparse
import io
import json
import os
import re
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_log  # noqa: E402
import nogps_replay  # noqa: E402
import nogps_trip_log  # noqa: E402

DEG_PER_M = 1 / 111320.0
START_LAT, START_LON = 10.0, 20.0
DAY_MS = nogps_log.to_ms(nogps_log.datetime(2026, 10, 8))
# The stamp of LOGFMT 2 data lines: the tools skip it so far, see nogps_replay.sentence.
LOGFMT_MS = 1760000000000
DATA_TAG = re.compile(r'(\(\): (?:TRIP|ACC|ACCB|ACCB_BEFORE|GYRO|CALIBRATION)) ')


def logfmt2(lines):
    """The same log as LOGFMT 2 writes it: every data line has "ms=<unix ms>" right after its tag."""
    return [DATA_TAG.sub(r'\1 ms=%d ' % LOGFMT_MS, line) for line in lines]


def android_time(day, second, ms=0):
    h, rest = divmod(second, 3600)
    m, s = divmod(rest, 60)
    return '%s %02d:%02d:%02d.%03d' % (day, h, m, s, ms)


def core(day, second, func, text, level='I', ms=0, file='nogps/engine.cpp:1'):
    return '%s (main) %s/OMcore: %s %s(): %s' % (android_time(day, second, ms), level, file, func, text)


def trip_line(error_m=3.0, lat=START_LAT, kmh=36.0, **extra):
    """A TRIP line of a car driving north at |lat| with the mark |error_m| ahead of GPS."""
    fields = dict(src='INERTIAL', pos='%.6f,%.6f' % (lat + error_m * DEG_PER_M, START_LON), acc='10', bear='0',
                  age='0.0', gps='%.6f,%.6f/5.0/%.1f/0/0.00/3' % (lat, START_LON, kmh), gpsAge='0.0', fill='4',
                  spoofed='0', gpsst='GOOD', choice='BOX', nav='0', obd='CONNECTED', speed='%d' % kmh, sage='200',
                  link='BLE/CONNECTED', box='5/220', bf='1F', scale='1.000', table='3', rough='0', lag='0.30',
                  boxacc='0.90/+1.0', phoneacc='0.50/-', gyro='DONE', turn='NaN', hdg='0/GPS', road='1', lost='0',
                  back='0', turning='0', odo='0', offm='0', offv='0', cand='-', snap='1.0', rdiff='0',
                  snapwhy='ROAD', wait='-', fix='0', ready='1', ring='0')
    fields.update(extra)
    return 'TRIP ' + ' '.join('%s=%s' % kv for kv in fields.items())


def android_drive(day='10-08', start=18 * 3600, seconds=120, stand=10, error=lambda s: 3.0, fields=lambda s: {},
                  header=True):
    """An Android log of one drive: the app starts, the car stands |stand| s, then drives north at 10 m/s."""
    lines = []
    if header:
        lines += ['Datetime: 2026-%s 18:00:00.000' % day, '', 'Android version: 15 (API 35)']
    lines.append('%s (main) I/OrganicMaps: MwmApplication.java:126 onCreate(): Initializing application'
                 % android_time(day, start))
    lines.append(core(day, start + 1, 'Start', 'Start'))
    for s in range(seconds):
        moving = s >= stand
        lat = START_LAT + max(0, s - stand) * 10 * DEG_PER_M
        lines.append(core(day, start + 2 + s, 'LogTrip', trip_line(error(s), lat, 36.0 if moving else 0.0,
                                                                   **fields(s)), file='nogps/engine.cpp:1526'))
        if moving:
            lines.append(core(day, start + 2 + s, 'OnData', 'ACCB ' + ' '.join(['0.10,0.00,0.00,0.5'] * 5), ms=500,
                              file='nogps/esp32_source.cpp:249'))
    return lines


def logfmt_line(phone='Pixel_7-a3f9', version=2, trip='180000', commit='abcdef12'):
    """The first line of a log file, as LogsManager.getLogFormatLine writes it."""
    return ('LOGFMT %d ms=%d phone=%s trip=%s app=2026.10.08-1-Google build=26100801 commit=%s om=2026.10.27-10'
            % (version, LOGFMT_MS, phone, trip, commit))


def with_logfmt(lines, phone='Pixel_7-a3f9', **kwargs):
    return [logfmt_line(phone, **kwargs)] + lines


def analyse(*logs, year=None):
    """The analysis of logs (name, lines): a file without the LOGFMT line gets the one of Pixel_7-a3f9."""
    return nogps_log.Analysis([(name, ('\n'.join(lines if lines[0].startswith('LOGFMT') else with_logfmt(lines)) + '\n')
                                .encode()) for name, lines in logs], year)


def write_tree(folder, files):
    """The files {'<phone>/<yyyy-MM-dd>/<HHmmss>.log': lines} in |folder|."""
    for name, lines in files.items():
        path = os.path.join(folder, *name.split('/'))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')


def kinds(trip):
    return {a['kind'] for a in trip.anomalies}


class AndroidTest(unittest.TestCase):
    def test_line(self):
        lines = nogps_log.parse_android(['Datetime: 2026-10-08 18:00:00.000',
                                         core('10-08', 3600, 'Start', 'Start', ms=250, level='W')], None)
        self.assertEqual(len(lines), 1)
        t, level, raw, tag, body = lines[0]
        self.assertEqual(t, DAY_MS + 3600_250)
        self.assertEqual((level, tag, body), ('W', 'OMcore', 'nogps/engine.cpp:1 Start(): Start'))

    def test_stack_trace_goes_on_its_line(self):
        lines = nogps_log.parse_android([core('10-08', 1, 'F', 'crash', level='E'), '\tat a.B.c(B.java:1)'], 2026)
        self.assertEqual(lines[0][2], core('10-08', 1, 'F', 'crash', level='E') + '\n\tat a.B.c(B.java:1)')

    def test_year_without_header(self):
        lines = nogps_log.parse_android(
            [core('10-08', 0, 'Restore', 'Last trusted position = 10.0,20.0,1791417600000')], 2020)
        self.assertEqual(nogps_log.from_ms(lines[0][0]).year, 2026)

    def test_new_year_in_a_file(self):
        lines = nogps_log.parse_android(['Datetime: 2026-12-31 23:00:00.000', core('01-01', 0, 'Start', 'Start')],
                                        None)
        self.assertEqual(nogps_log.from_ms(lines[0][0]).year, 2027)


class IosTest(unittest.TestCase):
    LOG = ['I(1) 0.01000 Maps/main.mm:14 main: NonGPS Maps app.nogps 1.0 started, detected CPU cores: 6',
           'I(1) 0.50000 Local time: 2026-10-08 15:00:00 +0000 , Time Zone: MSK',
           'I(2) 10.50000 nogps/engine.cpp:1526 LogTrip(): ' + trip_line(),
           # The app is started anew: the seconds start from zero.
           'I(1) 0.02000 Maps/main.mm:14 main: NonGPS Maps app.nogps 1.0 started, detected CPU cores: 6',
           'I(1) 1.00000 Local time: 2026-10-08 16:00:00 +0000 , Time Zone: MSK',
           'W(3) 2.00000 Location/MWMLocationManager.mm:640 -[MWMLocationManager start]: Start updating location']

    def test_times_of_runs(self):
        lines, unknown = nogps_log.parse_ios(self.LOG)
        self.assertEqual(unknown, 0)
        start = DAY_MS + 15 * 3600_000
        self.assertEqual([e[0] for e in lines], [start - 490, start, start + 10_000, start + 3600_000 - 980,
                                                 start + 3600_000, start + 3601_000])
        self.assertEqual(lines[-1][1], 'W')

    def test_run_without_local_time(self):
        _, unknown = nogps_log.parse_ios(self.LOG[:3] + ['I(1) 0.50000 nogps/engine.cpp:111 Start(): Start'])
        self.assertEqual(unknown, 1)

    def test_file_of_a_new_day(self):
        # The file opened mid-run starts with the time of the launch.
        lines, unknown = nogps_log.parse_ios(['I(1) 3600.00000 Local time: 2026-10-09 00:00:00 +0000',
                                              'I(2) 3610.50000 nogps/engine.cpp:1526 LogTrip(): ' + trip_line()])
        self.assertEqual(unknown, 0)
        self.assertEqual(lines[1][0], DAY_MS + 86400_000 + 10_500)

    def test_objc_function(self):
        group = analyse(('log.txt', self.LOG)).groups[0]
        self.assertEqual(group.zone, 'UTC')
        self.assertEqual([e['name'] for e in group.events], ['app started', 'app started', 'location started'])


class TripLineTest(unittest.TestCase):
    def test_fields(self):
        # The network location has its own acc and age after it.
        line = trip_line(bf='9B') + ' net=10.00100,20.00100 acc=900 age=12.0'
        row = analyse(('app.log', [core('10-08', 0, 'LogTrip', line)])).groups[0].rows[0]
        self.assertEqual((row['acc'], row['net_acc'], row['net_age']), ('10', '900', '12.0'))
        self.assertEqual((row['gps_kmh'], row['err_m'], row['along_m']), ('36.0', 3.0, 3.0))
        self.assertEqual(nogps_log.box_flags(row), {'IMU_OK', 'BIAS_OK', 'FWD_OK', 'OBD_OK', 'MOUNT_MOVED'})

    def test_header_of_a_joined_file_after_a_trip_line(self):
        # A standing car ends the first day with a TRIP line: the header of the next file follows it.
        first = android_drive('10-08', seconds=5, stand=5)
        second = android_drive('10-09', seconds=5, stand=5)
        second.insert(1, 'Location providers: gps net')
        self.assertIn('TRIP ', first[-1])
        groups = analyse(('joined.log', first + second)).groups
        self.assertEqual(sum(len(g.rows) for g in groups), 10)

    def test_sensors(self):
        group = analyse(('app.log', android_drive(seconds=12))).groups[0]
        self.assertEqual(len(group.series['accb']), 10)
        self.assertEqual(group.series['accb'][0][1:], [0.1, 0.0, 0.0, 0.5])


class ErrorMeterTest(unittest.TestCase):
    """The error of the mark is measured only against an accurate fix that moves with the car."""

    @staticmethod
    def rows(lines):
        """Rows of the TRIP lines given as (seconds, fields of trip_line)."""
        meter = nogps_trip_log.ErrorMeter()
        rows = []
        for seconds, fields in lines:
            row = nogps_trip_log.parse_trip(trip_line(**fields)[len('TRIP '):])
            meter.add(row, seconds)
            rows.append(row)
        return rows

    @staticmethod
    def fix(lat=START_LAT, acc=5.0, kmh=36.0):
        return '%.6f,%.6f/%.1f/%.1f/0/0.00/3' % (lat, START_LON, acc, kmh)

    def test_coarse_fix(self):
        row = self.rows([(0, dict(gps=self.fix(acc=500)))])[0]
        self.assertEqual((row['ref'], row.get('err_m'), row['err_why']), ('gps', None, 'coarse'))
        row = self.rows([(0, dict(gps=self.fix(acc=nogps_trip_log.REF_MAX_ACCURACY_M)))])[0]
        self.assertEqual((row['err_m'], row.get('err_why')), (3.0, None))

    def test_accurate_fused_after_coarse_gps(self):
        row = self.rows([(0, dict(gps=self.fix(acc=500), fused=self.fix(acc=10)))])[0]
        self.assertEqual((row['ref'], row['err_m']), ('fused', 3.0))

    def test_fix_standing_while_the_car_drives(self):
        # The car drives 10 m/s, the fix stays at the start: 30 m on, the error is not measured. Then it moves.
        lines = [(s, dict(lat=START_LAT + s * 10 * DEG_PER_M, kmh=36.0, gps=self.fix())) for s in range(6)]
        lines.append((6, dict(lat=START_LAT + 60 * DEG_PER_M, kmh=36.0, gps=self.fix(START_LAT + 60 * DEG_PER_M))))
        rows = self.rows(lines)
        self.assertEqual([r.get('err_why') for r in rows], [None, None, None, None, 'stale', 'stale', None])
        self.assertAlmostEqual(rows[3]['err_m'], 33.0, delta=0.2)
        self.assertAlmostEqual(rows[6]['err_m'], 3.0, delta=0.2)

    def test_stale_fused_between_accurate_gps(self):
        # The fused fix stands while gps= comes and goes: the fused one stays stale when it is measured against again.
        lines = [(s, dict(lat=START_LAT + s * 10 * DEG_PER_M, kmh=36.0, fused=self.fix(acc=10),
                          gps=self.fix(acc=500) if s != 5 else self.fix(START_LAT + s * 10 * DEG_PER_M)))
                 for s in range(8)]
        rows = self.rows(lines)
        self.assertEqual([r['ref'] for r in rows], ['fused'] * 5 + ['gps'] + ['fused'] * 2)
        self.assertEqual([r.get('err_why') for r in rows], [None] * 4 + ['stale', None, 'stale', 'stale'])

    def test_old_fix_repeated(self):
        # One fix of the start, older each second: add_error() moves it on by its age, so it is still measured.
        rows = self.rows([(s, dict(lat=START_LAT + s * 10 * DEG_PER_M, kmh=36.0,
                                   gps='%.6f,%.6f/5.0/36.0/0/%.2f/3' % (START_LAT, START_LON, s))) for s in range(8)])
        self.assertEqual([r.get('err_why') for r in rows], [None] * 8)
        self.assertAlmostEqual(rows[-1]['err_m'], 3.0, delta=0.2)

    def test_fix_without_course(self):
        # A Wi-Fi fix without speed and course, older each second, can't be moved on: not measured while the car
        # drives, measured while it stands.
        wifi = '%.6f,%.6f/20.0/-/-/%.2f/3'
        rows = self.rows([(s, dict(lat=START_LAT + s * 10 * DEG_PER_M, kmh=36.0, gps=wifi % (START_LAT, START_LON, s)))
                          for s in range(3)] + [(3, dict(kmh=0.0, gps=wifi % (START_LAT, START_LON, 0)))])
        self.assertEqual([r.get('err_why') for r in rows], ['nocourse'] * 3 + [None])
        self.assertAlmostEqual(rows[-1]['err_m'], 3.0, delta=0.2)
        # A speed without a course can't move it on either; the car at REF_NO_COURSE_MAX_KMH counts as driving.
        kmh = nogps_trip_log.REF_NO_COURSE_MAX_KMH
        for car_kmh, why in ((kmh, 'nocourse'), (kmh - 1, None)):
            row = self.rows([(0, dict(kmh=car_kmh, gps='%.6f,%.6f/5.0/36.0/-/0.50/3' % (START_LAT, START_LON)))])[0]
            self.assertEqual(row.get('err_why'), why, car_kmh)

    def test_fix_of_a_standing_car(self):
        rows = self.rows([(s, dict(kmh=0.0, gps=self.fix(kmh=0))) for s in range(0, 600, 30)])
        self.assertTrue(all('err_m' in r for r in rows))

    def test_gap_is_no_drive(self):
        # An hour without lines counts REF_STALE_MAX_GAP_S of driving: 25 m at 5 m/s, under REF_STALE_DRIVEN_M.
        rows = self.rows([(0, dict(kmh=18.0, gps=self.fix())), (3600, dict(kmh=18.0, gps=self.fix()))])
        self.assertEqual(rows[1].get('err_why'), None)

    def test_trips_of_the_analysis(self):
        # The fix stops 10 s after the car started: the error of the rest is not measured, not 10 m more each second.
        drive = android_drive(seconds=40, stand=10, fields=lambda s: dict(gps=self.fix(
            START_LAT + min(max(0, s - 10), 10) * 10 * DEG_PER_M)), error=lambda s: 0.0)
        rows = analyse(('app.log', drive)).groups[0].rows
        errors = [r['err_m'] for r in rows if 'err_m' in r]
        self.assertLessEqual(max(errors), nogps_trip_log.REF_STALE_DRIVEN_M + 10)
        self.assertEqual(rows[-1]['err_why'], 'stale')


class SplitTest(unittest.TestCase):
    def test_one_drive_trimmed(self):
        trips = analyse(('app.log', android_drive(seconds=200, stand=100))).trips
        self.assertEqual([t.driven for t in trips], [False, True])
        self.assertEqual(trips[1].start - trips[0].end, 1000)
        # The drive keeps STAND_KEEP_S of the standing before it.
        self.assertEqual(len(trips[1].rows), 100 + nogps_log.STAND_KEEP_S)

    def test_long_stand_splits(self):
        stand = nogps_log.STAND_SPLIT_S + 100
        log = android_drive(seconds=60 + stand + 60, stand=0,
                            fields=lambda s: dict(speed='0', gps='%.6f,%.6f/5.0/0/0/0.00/3' % (START_LAT, START_LON))
                            if 60 <= s < 60 + stand else {})
        trips = analyse(('app.log', log)).trips
        self.assertEqual([t.driven for t in trips], [True, False, True])

    def test_short_stop_and_pause_of_the_log_keep_one_trip(self):
        log = android_drive(seconds=100, stand=0) + android_drive(start=18 * 3600 + 200, seconds=100, stand=0,
                                                                  header=False)
        trips = analyse(('app.log', log)).trips
        self.assertEqual([t.driven for t in trips], [True])
        self.assertEqual([(a['kind'], a['text']) for a in trips[0].anomalies], [('no TRIP lines',
                                                                                 '101 s without a TRIP line')])

    def test_standing_car_written_seldom_is_no_gap(self):
        stand = lambda s: 60 <= s < 180
        log = android_drive(seconds=240, stand=0, fields=lambda s: dict(
            speed='0', gps='%.6f,%.6f/5.0/0/0/0.00/3' % (START_LAT, START_LON)) if stand(s) else {})
        # The core writes a standing car once in 30 s; a moving one every second, a pause of it is a gap.
        def written(line):
            if 'TRIP ' not in line:
                return True
            s = int(line[9:11]) * 60 + int(line[12:14]) - 2
            return not ((stand(s) and s % 30) or 200 <= s < 210)
        log = [line for line in log if written(line)]
        trips = analyse(('app.log', log)).trips
        self.assertEqual([(a['kind'], a['text']) for t in trips for a in t.anomalies],
                         [('no TRIP lines', '11 s without a TRIP line')])

    def test_long_pause_of_the_log_splits(self):
        log = android_drive(seconds=100, stand=0) + android_drive(start=19 * 3600, seconds=100, stand=0, header=False)
        self.assertEqual(len(analyse(('app.log', log)).trips), 2)

    def test_stationary_split_by_gaps(self):
        log = android_drive(seconds=20, stand=20) + android_drive(start=19 * 3600, seconds=20, stand=20, header=False)
        self.assertEqual([t.driven for t in analyse(('app.log', log)).trips], [False, False])


class AnomaliesTest(unittest.TestCase):
    def drive(self, fields, error=lambda s: 3.0):
        return analyse(('app.log', android_drive(seconds=60, stand=0, fields=fields, error=error))).trips[0]

    def test_clean_drive(self):
        self.assertEqual(self.drive(lambda s: {}).anomalies, [])

    def test_far_from_gps(self):
        trip = self.drive(lambda s: {}, error=lambda s: 120.0 if 10 <= s < 15 else 40.0 if 30 <= s < 32 else 3.0)
        far = [a for a in trip.anomalies if a['kind'] == 'mark far from GPS']
        # 2 s at 40 m is too short.
        self.assertEqual([(a['severity'], a['end'] - a['start']) for a in far], [('high', 4000)])

    def test_rules(self):
        cases = [
            (dict(box='2/300'), 'box data gaps'), (dict(box='5/1500'), 'box data gaps'),
            (dict(link='BLE/SEARCHING'), 'box not connected'), (dict(sage='3000'), 'car speed stale'),
            (dict(bf='1B'), 'box flags'), (dict(bf='41F'), 'box flags'),
            (dict(gyro='NONE'), 'gyroscope not calibrated'),
            (dict(lost='1'), 'road lost'), (dict(back='1'), 'driving backward'), (dict(spoofed='1'), 'GPS spoofed'),
            (dict(self='1', car='10.0,20.0'), 'followed apart off the roads'),
            (dict(hdg='40/ROAD'), 'heading off GPS'), (dict(speed='50'), 'speed off GPS'),
        ]
        for extra, kind in cases:
            with self.subTest(extra=extra):
                self.assertEqual(kinds(self.drive(lambda s: extra if 10 <= s < 20 else {})), {kind})

    def test_flags_text(self):
        trip = self.drive(lambda s: dict(bf='9B') if 10 <= s < 20 else {})
        self.assertEqual(trip.anomalies[0]['text'], 'MOUNT_MOVED, no UP_OK')

    def test_warnings_joined(self):
        log = android_drive(seconds=60, stand=0)
        log += [core('10-08', 18 * 3600 + 10 + s, 'Check', 'Untrusted location = ms::LatLon(10.0, 20.0) 80', level='W')
                for s in (0, 5, 50)]
        trip = analyse(('app.log', log)).trips[0]
        warnings = [a for a in trip.anomalies if a['kind'] == 'warning: untrusted location']
        self.assertEqual([a['text'][:9] for a in warnings], ['2 lines, ', 'Untrusted'])


class EventsTest(unittest.TestCase):
    def test_categories(self):
        day, t = '10-08', 18 * 3600
        log = logfmt2(android_drive(seconds=30, stand=0)) + [
            core(day, t + 5, 'SetManual', 'tap = ms::LatLon(10.0001, 20.0002) location = ms::LatLon(10.0, 20.0) '
                 'bearing = 0 heading was = nullopt'),
            core(day, t + 6, 'LogStateChanges', 'GPS signal GOOD -> NONE'),
            core(day, t + 7, 'Lost', 'The road is lost after 120 m, stopping at ms::LatLon(10.0, 20.0)'),
            core(day, t + 8, 'OnBoxEvent', 'Box event # 3 at 10 ms: MOUNT_MOVED', level='W'),
            core(day, t + 9, 'SetState', 'Routing session state: RouteNotStarted -> RouteBuilding',
                 file='routing/routing_session.cpp:273'),
            core(day, t + 10, 'Something', 'A new line of the core'),
            core(day, t + 10, 'operator()', 'ACTION route ms=1791417610000 Route state = RouteBuilding was NoValidRoute'),
            core(day, t + 10, 'OnBoxEvent', 'EVENT box_event ms=1791417610000 Box event # 4 at 11 ms: MOUNT_MOVED'),
            '%s (main) D/LocationState: LocationHelper.java:525 start(): ' % android_time(day, t + 11),
            '%s (main) I/Other: Other.java:1 run(): not a NoGPS line' % android_time(day, t + 12),
        ]
        events = analyse(('app.log', log)).trips[0].events
        self.assertEqual([(e['cat'], e['name']) for e in events if e['name'] not in ('app started',
                                                                                   'navigation started')], [
            ('user', 'tap'), ('state', 'GPS signal'), ('road', 'road lost'), ('box', 'box event'),
            ('route', 'route asked for'), ('other', 'A new line of'), ('route', 'routing state'), ('box', 'box event'), ('app', 'location started')])
        self.assertEqual((events[2]['lat'], events[2]['lon']), (10.0001, 20.0002))


class ShakeTest(unittest.TestCase):
    def shake(self, second, maximum, still=0, armed=0):
        return core('10-08', 18 * 3600 + second, 'OnShake', 'SHAKE ms=%d n=50 max=%d p90=%d p50=%d still=%d armed=%d '
                    'speed=0' % (LOGFMT_MS, maximum, maximum // 2, maximum // 4, still, armed),
                    file='nogps/inertial_navigator.cpp:1')

    def test_seconds_by_strength_and_what_came_before_a_failure(self):
        log = android_drive(seconds=20, stand=0)
        log += [self.shake(1, 50), self.shake(2, 99), self.shake(3, 150), self.shake(4, 2000, armed=1),
                self.shake(5, 40, still=1), self.shake(6, 300, still=1)]
        log.append(core('10-08', 18 * 3600 + 7, 'OnBoxEvent', 'EVENT box_event ms=%d Box event # 4 at 11 ms: '
                        'CAL_UP_FAILED' % LOGFMT_MS, level='W'))
        analysis = analyse(('app.log', log))
        # A SHAKE line is no event of the trip.
        self.assertFalse([e for e in analysis.groups[0].events if e['text'].startswith('SHAKE')])
        bands, failed = nogps_log.shake_days(analysis)
        self.assertEqual({k: dict(v) for k, v in bands.items()}, {
            ('Pixel_7-a3f9', '2026-10-08', 0): {'<100': 2, '100-300': 1, '>=1000': 1},
            ('Pixel_7-a3f9', '2026-10-08', 1): {'<100': 1, '300-1000': 1}})
        # The seconds 4..7 are within 3 s of the event at second 7.
        self.assertEqual([(f[3]) for f in failed], [2000])
        out = io.StringIO()
        with redirect_stdout(out):
            nogps_log.print_shake(analysis)
        self.assertIn('CAL_UP_FAILED Pixel_7-a3f9 2026-10-08 18:00:07: max of the 3 s before it 2000', out.getvalue())
        self.assertIn('50%', out.getvalue())

    def test_log_without_the_lines(self):
        out = io.StringIO()
        with redirect_stdout(out):
            nogps_log.print_shake(analyse(('app.log', android_drive(seconds=5, stand=0))))
        self.assertIn('no SHAKE lines', out.getvalue())


class CalibrationTest(unittest.TestCase):
    def test_trip_starts_with_the_last_line_before_the_car_moves(self):
        day = '10-08'
        log = android_drive(seconds=60, stand=10)
        log.append(core(day, 17 * 3600, 'LogCalibration', 'CALIBRATION car=42FD'))
        # The box of the trip is of another car: told while the car still stands, after the first TRIP lines.
        log.append(core(day, 18 * 3600 + 5, 'LogCalibration', 'CALIBRATION car=C47D scale=1.04', ms=500))
        # The values taken from the box on the way are of the next trip.
        log.append(core(day, 18 * 3600 + 30, 'LogCalibration', 'CALIBRATION car=C47D scale=1.04 table=1:2:3'))
        log += android_drive(start=19 * 3600, seconds=60, stand=0, header=False)
        analysis = analyse(('app.log', log))
        self.assertEqual([t.calibration() for t in analysis.trips], ['car=C47D scale=1.04',
                                                                    'car=C47D scale=1.04 table=1:2:3'])
        # A trip that only stands: the last line before it.
        stand = android_drive(seconds=8, stand=8)
        stand.append(core(day, 17 * 3600, 'LogCalibration', 'CALIBRATION car=42FD'))
        stand.append(core(day, 18 * 3600 + 5, 'LogCalibration', 'CALIBRATION car=C47D scale=1.04', ms=500))
        standing = analyse(('app.log', stand)).trips[0]
        self.assertFalse(standing.driven)
        self.assertEqual(standing.calibration(), 'car=42FD')
        events = [e for e in analysis.groups[0].events if e['text'].startswith('CALIBRATION')]
        self.assertEqual({(e['cat'], e['name']) for e in events}, {('box', 'car calibration')})
        out = io.StringIO()
        with redirect_stdout(out):
            nogps_log.print_trip(analysis.trips[1])
        # The time of the line comes with it: written before the trip, it misses what the drive before learned.
        self.assertIn('calibration: car=C47D scale=1.04 table=1:2:3 (written 18:00:30)\n', out.getvalue())
        self.assertEqual(analysis.trips[1].calibration_at(), analysis.trips[1].calibration_event()['t'])

    def test_log_without_the_line(self):
        trip = analyse(('app.log', android_drive(seconds=30, stand=0))).trips[0]
        self.assertIsNone(trip.calibration())
        self.assertIsNone(trip.calibration_at())


class ReplayLogsTest(unittest.TestCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'argv', ['nogps_replay.py', *argv]), redirect_stdout(out), \
                mock.patch.object(sys, 'stderr', err):
            try:
                nogps_replay.main()
            except SystemExit:
                pass
        self.last_out = out.getvalue()
        return out.getvalue(), err.getvalue()

    @staticmethod
    def drive(seconds):
        """A drive with the rotation of the box, which the input is made from."""
        return android_drive(seconds=seconds, stand=0) + [
            core('10-08', 18 * 3600 + 2 + s, 'OnMotion', 'GYRO 0.0 0 0 0 0 0 36 36 36 36 36', ms=600,
                 file='nogps/esp32_source.cpp:1') for s in range(seconds)]

    def two_phones(self, folder):
        write_tree(folder, {
            'Pixel_7-a3f9/2026-10-08/180000.log': with_logfmt(self.drive(20)),
            'SM_S918B-0b1c/2026-10-08/180000.log': with_logfmt(self.drive(30), 'SM_S918B-0b1c')})

    def test_days_of_a_tree_of_two_phones(self):
        with tempfile.TemporaryDirectory() as folder:
            self.two_phones(folder)
            out, _ = self.run_main('days', folder)
            self.assertIn('phone Pixel_7-a3f9\n10-08      20 TRIP lines', out)
            self.assertIn('phone SM_S918B-0b1c\n10-08      30 TRIP lines', out)
            out, _ = self.run_main('days', os.path.join(folder, 'Pixel_7-a3f9'))
            self.assertNotIn('SM_S918B-0b1c', out)

    @staticmethod
    def ios_run(utc, zone, seconds, launch=0.0):
        """One run of the iOS app: its two "Local time:" lines (UTC, then with the zone), the start and |seconds| TRIP
        lines."""
        lines = ['I(1) %.5f Local time: %s +0000' % (launch, utc),
                 'I(1) %.5f Local time: %s +0000 , Time Zone: %s' % (launch + 0.0004, utc, zone),
                 'I(1) %.5f Maps/main.mm:14 main: Organic Maps com.non-gps 2026.11.25 started, detected CPU cores: 6'
                 % (launch + 0.04),
                 'I(1) %.5f Maps/main.mm:20 foo: TRIP : not a core line' % (launch + 0.06)]
        lines += ['I(1) %.5f nogps/engine.cpp:2312 LogTrip(): %s' % (launch + 10 + s, trip_line())
                  for s in range(seconds)]
        return lines

    def test_days_and_input_of_an_ios_log_in_its_local_time(self):
        """An iOS line has no date: its time is the launch's "Local time:" (UTC) plus its zone, so a run started at
        23:00 UTC in GMT+2 is a day of the next date, as the folder of the trip is named."""
        run = self.ios_run('2026-11-25 22:59:50', 'GMT+2', 5) + self.ios_run('2026-11-26 00:00:00', 'GMT-0:30', 3, 7.0)
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'iPhone17_1-3b77/2026-11-26/005950.log': with_logfmt(run, 'iPhone17_1-3b77')})
            out, _ = self.run_main('days', folder)
            self.assertIn('phone iPhone17_1-3b77\n11-25       3 TRIP lines  made from\n11-26       5 TRIP lines', out)
            trips, others, started = nogps_replay.read([os.path.join(folder, 'iPhone17_1-3b77', '2026-11-26',
                                                                     '005950.log')], '11-26')
            # 22:59:50 UTC is 00:59:50 in GMT+2.
            self.assertEqual([t['ms'] for t in trips], [3590000 + 1000 * (10 + s) for s in range(5)])
            self.assertEqual(started, [3590040])
            self.assertEqual(others, [])

    def test_ios_file_without_the_zone_line_takes_the_zone_from_its_name(self):
        """Only the first file of a launch has "Time Zone:", and it can be "EST": the zone is then the distance of the
        file name (local) from the UTC time of the "Local time:" line."""
        for zone_line, utc, trip in ((None, '2026-11-25 22:30:00', '003000'),
                                     ('EST', '2026-11-26 05:30:00', '003000'),
                                     (None, '2026-11-26 05:30:00', '003000')):
            run = ['I(1) 0.00000 Local time: %s +0000' % utc]
            if zone_line:
                run.append('I(1) 0.00040 Local time: %s +0000 , Time Zone: %s' % (utc, zone_line))
            run.append('I(1) 10.00000 nogps/engine.cpp:2312 LogTrip(): %s' % trip_line())
            with tempfile.TemporaryDirectory() as folder:
                path = os.path.join(folder, 'iPhone17_1-3b77', '2026-11-26', trip + '.log')
                write_tree(folder, {'iPhone17_1-3b77/2026-11-26/%s.log' % trip:
                                    with_logfmt(run, 'iPhone17_1-3b77', trip=trip)})
                trips, _, _ = nogps_replay.read([path], '11-26')
                self.assertEqual([t['ms'] for t in trips], [1810000], (zone_line, utc))

    def test_ios_file_that_continues_a_launch_takes_the_zone_from_the_launch_start(self):
        """The name of a file can be the local time of the launch it continues: 45338 s before 05:47:23 UTC is 17:11:45
        UTC, 19:11:45 in GMT+2. A name that fits neither gives no zone and no lines, not a wrong day."""
        for trip, line_day in (('191145', '11-25'), ('185210', None)):
            run = ['I(1) 45338.00000 Local time: 2026-11-25 05:47:23 +0000',
                   'I(1) 45348.00000 nogps/engine.cpp:2312 LogTrip(): %s' % trip_line()]
            with tempfile.TemporaryDirectory() as folder:
                path = os.path.join(folder, 'iPhone17_1-3b77', '2026-11-25', trip + '.log')
                write_tree(folder, {'iPhone17_1-3b77/2026-11-25/%s.log' % trip:
                                    with_logfmt(run, 'iPhone17_1-3b77', trip=trip)})
                self.assertEqual(sorted(nogps_replay.trip_days([path])), [line_day] if line_day else [])

    def test_ios_file_that_continues_a_launch_of_an_earlier_file_takes_its_zone(self):
        """The name of a continuation file is the one of the previous file, reused in the next day folder: it fits
        neither the file nor the launch start, so the zone is the one of the file before."""
        first = ['I(1) 100.00000 Local time: 2026-11-23 10:00:29 +0000 , Time Zone: GMT+2',
                 'I(1) 110.00000 nogps/engine.cpp:2312 LogTrip(): %s' % trip_line()]
        second = ['I(1) 46906.38600 Local time: 2026-11-23 23:02:12 +0000',
                  'I(1) 46909.38600 nogps/engine.cpp:2312 LogTrip(): %s' % trip_line()]
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'iPhone17_1-ed9a/2026-11-23/120029.log': with_logfmt(first, 'iPhone17_1-ed9a',
                                                                                   trip='120029'),
                                'iPhone17_1-ed9a/2026-11-24/185210.log': with_logfmt(second, 'iPhone17_1-ed9a',
                                                                                   trip='185210')})
            paths = [os.path.join(folder, 'iPhone17_1-ed9a', d, n) for d, n in
                     (('2026-11-23', '120029.log'), ('2026-11-24', '185210.log'))]
            self.assertEqual(nogps_replay.trip_days(paths), {'11-23': 1, '11-24': 1})

    def test_ios_line_logged_late_does_not_drop_the_lines_after_it(self):
        run = ['I(1) 100.00000 Local time: 2026-11-25 10:00:00 +0000 , Time Zone: GMT+2',
               'I(1) 97.00000 nogps/engine.cpp:2252 operator()(): EVENT gps_signal ms=1 from=GOOD to=NONE late',
               'I(1) 100.10000 nogps/engine.cpp:2312 LogTrip(): %s' % trip_line()]
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'iPhone17_1-3b77', '2026-11-25', '115820.log')
            write_tree(folder, {'iPhone17_1-3b77/2026-11-25/115820.log': with_logfmt(run, 'iPhone17_1-3b77')})
            self.assertEqual(nogps_replay.trip_days([path]), {'11-25': 1})

    def test_input_of_a_tree_of_two_phones_is_a_file_a_phone(self):
        with tempfile.TemporaryDirectory() as folder:
            self.two_phones(folder)
            target = os.path.join(folder, 'in.txt')
            self.run_main('input', folder, '--day', '10-08', '-o', target)
            self.assertEqual(sorted(n for n in os.listdir(folder) if n.startswith('in-')),
                             ['in-Pixel_7-a3f9.txt', 'in-SM_S918B-0b1c.txt'])

    def test_input_of_a_fresh_trip_says_so_in_its_first_record(self):
        with tempfile.TemporaryDirectory() as folder:
            self.two_phones(folder)
            target = os.path.join(folder, 'in.txt')
            for flags, first in (([], 'D 10-08'), (['--fresh'], 'D 10-08 fresh')):
                self.run_main('input', os.path.join(folder, 'Pixel_7-a3f9'), '--day', '10-08', '-o', target, *flags)
                with open(target) as f:
                    self.assertEqual(f.readline().rstrip('\n'), first)

    def run_with_maps(self, logged, version, *flags, step=1800):
        """Whether `run` drove a day logged on the maps |logged| (None: no MAPS line) with --data_path <version>, and
        its output."""
        with tempfile.TemporaryDirectory() as folder:
            lines = self.drive(20)
            # A tuple is a MAPS line after each other, as when maps are downloaded in the middle of the day.
            for at, version_line in enumerate((logged,) if isinstance(logged, str) else logged or ()):
                lines.insert(1 + at, core('10-08', 18 * 3600 + step * at, 'Start',
                                          'MAPS ms=%d version=%s' % (LOGFMT_MS, version_line)))
            write_tree(folder, {'Pixel_7-a3f9/2026-10-08/180000.log': with_logfmt(lines)})
            maps = os.path.join(folder, 'maps')
            if version:
                os.makedirs(os.path.join(maps, version))
            else:
                os.makedirs(maps)
            tool = os.path.join(folder, 'tool.py')
            with open(tool, 'w') as f:
                f.write('#!%s\nimport sys\nopen(sys.argv[-1], "w").write("")\nopen(sys.argv[-1] + ".done", "w")\n'
                        % sys.executable)
            os.chmod(tool, 0o755)
            out_folder = os.path.join(folder, 'out')
            self.run_main('run', folder, '--tool', tool, '--data_path', maps, '-o', out_folder, '-j', '1', *flags)
            return os.path.exists(os.path.join(out_folder, 'Pixel_7-a3f9', '10-08-in.txt')), self.last_out

    def test_run_refuses_a_day_logged_on_other_maps(self):
        driven, _ = self.run_with_maps('261101,260714', '260714')
        self.assertTrue(driven)
        driven, out = self.run_with_maps('261101,260714', '250101')
        self.assertFalse(driven)
        self.assertIn('the log was driven on maps 261101,260714 and --data_path has 250101', out)
        driven, _ = self.run_with_maps('261101,260714', '250101', '--any-maps')
        self.assertTrue(driven)
        driven, out = self.run_with_maps('261101', None)
        self.assertFalse(driven)
        self.assertIn('the version of --data_path is not known', out)

    def test_run_refuses_a_day_with_newer_maps_later(self):
        driven, out = self.run_with_maps(('260714', '261101,260714'), '260714')
        self.assertTrue(driven)
        driven, out = self.run_with_maps(('260714', '261101'), '260714')
        self.assertFalse(driven)
        self.assertIn('--data_path has 260714', out)

    def test_run_checks_the_maps_only_up_to_to(self):
        driven, _ = self.run_with_maps(('260714', '261101'), '260714', '--to', '18:10')
        self.assertTrue(driven)
        driven, _ = self.run_with_maps(('260714', '261101'), '260714', '--to', '19:00')
        self.assertFalse(driven)

    def test_run_checks_the_maps_only_from_from(self):
        # The maps of 18:00:00 were replaced at 18:00:05: a window after that is driven on the later ones.
        driven, _ = self.run_with_maps(('260714', '261101'), '261101', '--from', '18:00:10', step=5)
        self.assertTrue(driven)
        driven, _ = self.run_with_maps(('260714', '261101'), '260714', '--from', '18:00:10', step=5)
        self.assertFalse(driven)

    def test_warn_builds_names_a_dirty_build_and_skips_a_build_without_git(self):
        for commit, noted in (('abcdef12-dirty', 'abcdef12-dirty'), ('00000000', None), ('00000000-dirty', None)):
            with tempfile.TemporaryDirectory() as folder:
                write_tree(folder, {'Pixel_7-a3f9/2026-10-08/180000.log':
                                    with_logfmt(self.drive(20), commit=commit)})
                err = io.StringIO()
                with mock.patch.object(sys, 'stderr', err):
                    nogps_replay.warn_builds([folder])
                if noted:
                    self.assertIn('the builds ' + noted + ',', err.getvalue())
                else:
                    self.assertEqual(err.getvalue(), '')

    def test_run_drives_a_day_with_no_maps_line(self):
        driven, _ = self.run_with_maps(None, '250101')
        self.assertTrue(driven)

    def test_compare_takes_one_phone(self):
        with tempfile.TemporaryDirectory() as folder:
            self.two_phones(folder)
            _, err = self.run_main('compare', folder, '--day', '10-08', '--replay', 'out.txt')
            self.assertIn('Pixel_7-a3f9, SM_S918B-0b1c: compare takes one phone', err)

    def test_run_drives_each_phone_into_its_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            self.two_phones(folder)
            tool = os.path.join(folder, 'tool.py')
            with open(tool, 'w') as f:
                f.write('#!%s\nimport sys\nopen(sys.argv[-1], "w").write("")\nopen(sys.argv[-1] + ".done", "w")\n'
                        % sys.executable)
            os.chmod(tool, 0o755)
            out_folder = os.path.join(folder, 'out')
            out, _ = self.run_main('run', os.path.join(folder, 'Pixel_7-a3f9'), os.path.join(folder, 'SM_S918B-0b1c'),
                                   '--tool', tool, '--data_path', 'maps', '-o', out_folder, '-j', '1')
            self.assertIn('phone Pixel_7-a3f9', out)
            self.assertIn('phone SM_S918B-0b1c', out)
            for phone in ('Pixel_7-a3f9', 'SM_S918B-0b1c'):
                self.assertTrue(os.path.exists(os.path.join(out_folder, phone, '10-08-in.txt')), phone)

    def test_an_old_file_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'log-08-10-26-Pixel_7-a3f9.log': android_drive(seconds=3)})
            _, err = self.run_main('days', folder)
            self.assertIn('not a log of LOGFMT 2', err)


class InputTest(unittest.TestCase):
    def test_zip_of_rotated_files(self):
        log = android_drive(seconds=60)
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            # The files overlap: the same lines are read once.
            z.writestr('logs/Pixel_7-a3f9/2026-10-08/180000.log', '\n'.join(with_logfmt(log[:40])))
            z.writestr('logs/Pixel_7-a3f9/2026-10-08/180100.log', '\n'.join(with_logfmt(log[:3] + log[30:])))
            z.writestr('logs/Pixel_7-a3f9/logcat.log', 'not read')
        analysis = nogps_log.Analysis([('logs.zip', data.getvalue())])
        self.assertEqual([f['name'] for f in analysis.files], ['logs.zip/logs/Pixel_7-a3f9/2026-10-08/180000.log',
                                                               'logs.zip/logs/Pixel_7-a3f9/2026-10-08/180100.log'])
        self.assertEqual(len(analysis.trips[0].rows), 60)

    def test_groups_by_the_phone_of_the_header(self):
        """The phone is what the file says, not what its path or name does."""
        log = android_drive(seconds=30, stand=0)
        analysis = analyse(('a.log', with_logfmt(log[:20])), ('a1.log', with_logfmt(log[20:])),
                           ('b.log', with_logfmt(log, 'SM_S918B-0b1c')))
        self.assertEqual([(g.platform, g.phone) for g in analysis.groups],
                         [('android', 'Pixel_7-a3f9'), ('android', 'SM_S918B-0b1c')])
        self.assertEqual([len(g.rows) for g in analysis.groups], [30, 30])
        self.assertEqual(sorted(t.summary()['phone'] for t in analysis.trips), ['Pixel_7-a3f9', 'SM_S918B-0b1c'])

    def test_header(self):
        header = nogps_trip_log.header_of('a.log', (logfmt_line() + '\nDatetime: 2026-10-08 18:00:00.000\n').encode())
        self.assertEqual((header['logfmt'], header['phone'], header['trip'], header['commit']),
                         (2, 'Pixel_7-a3f9', '180000', 'abcdef12'))
        self.assertEqual(nogps_trip_log.parse_header('a.log', '\ufeff' + logfmt_line() + '\r')['phone'], 'Pixel_7-a3f9')

    def test_files_that_cannot_be_placed_are_refused(self):
        refused = {
            'a format that is not known': logfmt_line(version=3),
            'a file of the earlier versions': 'Datetime: 2026-10-08 18:00:00.000',
            'a file with no phone': 'LOGFMT 2 ms=1 trip=180000',
            'an empty file': '',
        }
        for what, first_line in refused.items():
            with self.subTest(what), self.assertRaises(nogps_trip_log.LogFormatError):
                nogps_log.Analysis([('a.log', '\n'.join([first_line] + android_drive(seconds=3)).encode())])

    def test_tree_of_two_phones(self):
        """The zips of two phones unpacked into one folder, and a zip of the same tree."""
        first, second = android_drive(seconds=30, stand=0), android_drive(seconds=40, stand=0)
        files = {'Pixel_7-a3f9/2026-10-08/180000.log': with_logfmt(first[:20]),
                 'Pixel_7-a3f9/2026-10-08/180019.log': with_logfmt(first[20:], trip='180019'),
                 'SM_S918B-0b1c/2026-10-08/180000.log': with_logfmt(second, 'SM_S918B-0b1c'),
                 'Pixel_7-a3f9/logcat.log': ['not read']}
        data = io.BytesIO()
        with tempfile.TemporaryDirectory() as folder, zipfile.ZipFile(data, 'w') as z:
            write_tree(os.path.join(folder, 'logs'), files)
            for name, lines in files.items():
                z.writestr('logs/' + name, '\n'.join(lines))
            sources = nogps_log.load_paths([os.path.join(folder, 'logs')])
            # The same files in the order of their names, the system log left out.
            self.assertEqual([n for n in nogps_trip_log.log_files([folder]) if 'logcat' not in n],
                             [name for name, _ in sources])
        for analysis in (nogps_log.Analysis(sources), nogps_log.Analysis([('logs.zip', data.getvalue())])):
            self.assertEqual(sorted(f['phone'] for f in analysis.files),
                             ['Pixel_7-a3f9', 'Pixel_7-a3f9', 'SM_S918B-0b1c'])
            self.assertEqual([(g.platform, g.phone, len(g.rows)) for g in analysis.groups],
                             [('android', 'Pixel_7-a3f9', 30), ('android', 'SM_S918B-0b1c', 40)])

    def test_a_tree_file_without_the_logfmt_line_takes_the_phone_of_its_path(self):
        """iOS with the record in a file off writes the OSLog text of "Report a bug" into the tree, Logger.mm."""
        header = nogps_trip_log.parse_header('logs.zip/logs/Pixel_7-a3f9/2026-10-08/180000.log', 'I(1) 0.5 hello')
        self.assertEqual((header['logfmt'], header['phone'], header['trip']), (None, 'Pixel_7-a3f9', '180000'))
        analysis = nogps_log.Analysis([('logs/Pixel_7-a3f9/2026-10-08/180000.log',
                                        ('\n'.join(android_drive(seconds=3)) + '\n').encode())])
        self.assertEqual([(f['phone'], f['platform']) for f in analysis.files], [('Pixel_7-a3f9', 'android')])

    def test_a_tree_file_without_the_logfmt_line_read_from_inside_the_phone_folder(self):
        """The folder of one phone given as ".", or a day of it: the <phone> folder is above the path given."""
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'Pixel_7-a3f9/2026-10-08/180000.log': android_drive(seconds=3)})
            here = os.getcwd()
            os.chdir(os.path.join(folder, 'Pixel_7-a3f9'))
            try:
                for path in ('.', './2026-10-08/180000.log', '2026-10-08/180000.log'):
                    with self.subTest(path):
                        self.assertEqual(list(nogps_trip_log.files_by_phone([path])), ['Pixel_7-a3f9'])
            finally:
                os.chdir(here)
        # A name that is no file on disk is not a path of the tree: "." tells no phone.
        with self.assertRaises(nogps_trip_log.LogFormatError):
            nogps_trip_log.parse_header('./2026-10-08/180000.log', 'I(1) 0.5 hello')

    def test_analysis_skips_an_old_file_next_to_new_ones(self):
        """A zip of a phone that still keeps a file of an earlier version: the rest of it is read, as in load_paths."""
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr('logs/log-07-10-26-Pixel_7-a3f9.log', '\n'.join(android_drive(seconds=3)))
            z.writestr('logs/Pixel_7-a3f9/2026-10-08/180000.log', '\n'.join(with_logfmt(android_drive(seconds=3))))
        analysis = nogps_log.Analysis([('logs.zip', data.getvalue())])
        self.assertEqual([f['name'] for f in analysis.files], ['logs.zip/logs/Pixel_7-a3f9/2026-10-08/180000.log'])
        self.assertEqual([n.split(':')[0] for n in analysis.notes], ['Skipped'])

    def test_load_paths_refuses_an_old_file(self):
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'log-08-10-26-Pixel_7-a3f9.log': android_drive(seconds=3)})
            with self.assertRaises(nogps_trip_log.LogFormatError):
                nogps_log.load_paths([folder])

    def test_load_paths_skips_an_old_file_next_to_new_ones(self):
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'log-08-10-26-Pixel_7-a3f9.log': android_drive(seconds=3),
                                'Pixel_7-a3f9/2026-10-08/180000.log': with_logfmt(android_drive(seconds=3))})
            self.assertEqual(len(nogps_log.load_paths([folder])), 1)
            self.assertEqual(list(nogps_trip_log.files_by_phone([folder])), ['Pixel_7-a3f9'])

    def test_not_a_log(self):
        with self.assertRaises(nogps_trip_log.LogFormatError):
            nogps_log.Analysis([('notes.txt', b'hello')])
        analysis = analyse(('a.log', with_logfmt(['hello'])))
        self.assertEqual((analysis.trips, analysis.notes), ([], ['a.log: has no lines of the app']))


class ReplayInputTest(unittest.TestCase):
    def drive(self, seconds, tagged=False):
        lines = android_drive(day='10-08', seconds=seconds, stand=0)
        lines += [core('10-08', 18 * 3600 + 2 + s, 'OnMotion', 'GYRO 0.0 0 0 0 0 0 36 36 36 36 36', ms=600,
                       file='nogps/esp32_source.cpp:1') for s in range(seconds)]
        return logfmt2(lines) if tagged else lines

    def records(self, lines):
        with tempfile.TemporaryDirectory() as folder:
            log = os.path.join(folder, 'app.log')
            out = os.path.join(folder, 'in.txt')
            with open(log, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines) + '\n')
            with redirect_stdout(io.StringIO()):
                nogps_replay.make_input(argparse.Namespace(logs=[log], day='10-08', start=None, end=None,
                                                           output=out, no_taps=False, no_route=False))
            with open(out, encoding='ascii') as f:
                return [line.split() for line in f]

    def calibration_records(self, lines):
        return [r for r in self.records(lines) if r[0] == 'K']

    def test_calibration_of_the_log_before_the_box_data(self):
        """The last CALIBRATION line before the box data gives the car, without the unit and with the box first."""
        lines = self.drive(60, tagged=True)
        first = 'CALIBRATION ms=1760000001000 car=A1B2 scale=1.02'
        last = ('CALIBRATION ms=1760000002000 car=C47D scale=1.04 table=3:1,2 rough=3:4 factor=1.01 unit=1.609 '
                'lag=0.30 accel=C47D:0.9,1')
        lines[0:0] = [core('10-08', 18 * 3600 - 5, 'LogCalibration', first),
                      core('10-08', 18 * 3600 - 3, 'LogCalibration', last),
                      core('10-08', 18 * 3600 + 30, 'LogCalibration', 'CALIBRATION ms=1 car=ZZZZ scale=2')]
        got = self.calibration_records(lines)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0][2:], ['car=C47D', 'scale=1.04', 'table=3:1,2', 'rough=3:4', 'factor=1.01',
                                      'lag=0.30', 'accel=C47D:0.9,1'])

    def test_calibration_written_after_the_start_of_the_file(self):
        """The file begins with the start of the app: the line it writes a moment later is the one taken."""
        lines = self.drive(60, tagged=True)
        lines[0:0] = [core('10-08', 18 * 3600 - 9, 'LogCalibration', 'CALIBRATION ms=1 car=OLD1 scale=2'),
                      core('10-08', 18 * 3600 - 3, 'LogCalibration', 'CALIBRATION ms=2 car=C47D scale=1.04')]
        records = self.records(lines)
        started = min(int(r[1]) for r in records if r[0] == 'S')
        got = [r for r in records if r[0] == 'K']
        self.assertEqual([r[2:] for r in got], [['car=C47D', 'scale=1.04']])
        self.assertLessEqual(started, int(got[0][1]))

    def test_no_calibration_in_the_log(self):
        self.assertEqual(self.calibration_records(self.drive(60, tagged=True)), [])

    def switches(self, switch_lines, tagged=False):
        # The switches come while the car drives, after the first second of the box data.
        lines = self.drive(60, tagged)
        lines[30:30] = [core('10-08', 18 * 3600 + 20, f, t) for f, t in switch_lines]
        return [r for r in self.records(lines) if r[0] in ('X', 'A') and int(r[1]) >= (18 * 3600 + 20) * 1000]

    def test_current_wording(self):
        got = self.switches([('SetGpsDisabled', 'GPS ignored by the user = 1'), ('SetManualMode', 'Manual mode = 1'),
                             ('SetGpsDisabled', 'GPS ignored by the user = 0')])
        self.assertEqual([(r[0], r[2]) for r in got], [('X', '1'), ('A', '1'), ('X', '0')])

    def test_old_wording(self):
        got = self.switches([('SetGpsDisabled', 'disabled = 1'), ('SetManualMode', 'enabled = 1')])
        self.assertEqual([(r[0], r[2]) for r in got], [('X', '1'), ('A', '1')])

    def test_tagged_wording(self):
        """LOGFMT 2 writes the tag, the stable name and the keys before the sentence."""
        got = self.switches([('SetGpsDisabled', 'ACTION gps_off ms=1760000020000 disabled=1 by=user '
                                                'GPS ignored by the user = 1'),
                             ('SetManualMode', 'ACTION manual ms=1760000020000 enabled=1 by=user Manual mode = 1')],
                            tagged=True)
        self.assertEqual([(r[0], r[2]) for r in got], [('X', '1'), ('A', '1')])

    def test_tagged_actions_of_the_user(self):
        lines = self.drive(60, tagged=True)
        lines[30:30] = [
            core('10-08', 18 * 3600 + 20, 'PutMark', 'ACTION tap ms=1760000020000 tap = ms::LatLon(10.0, 20.0) '
                 'location = ms::LatLon(10.0, 20.0) bearing = 0 heading was = nullopt'),
            core('10-08', 18 * 3600 + 21, 'SwitchMark', 'ACTION switch_mark ms=1760000021000 Switching the mark'),
            core('10-08', 18 * 3600 + 22, 'Stop', 'ACTION stop ms=1760000022000 Stop'),
        ]
        got = [r[0] for r in self.records(lines)
               if r[0] in ('T', 'H', 'W', 'S') and int(r[1]) >= (18 * 3600 + 20) * 1000]
        self.assertEqual(got, ['T', 'H', 'W', 'S'])

    def ble_states(self, texts):
        """The L records of the Bluetooth states written while the car drives."""
        lines = self.drive(60)
        lines[30:30] = [core('10-08', 18 * 3600 + 20 + i, 'OnBleState', t) for i, t in enumerate(texts)]
        return [r for r in self.records(lines) if r[0] == 'L' and int(r[1]) >= (18 * 3600 + 20) * 1000]

    def test_bond_lost_flag(self):
        """The connection that probes a pairing thought lost is driven again as a probe and not as a link."""
        got = self.ble_states(['Bluetooth = BOND_LOST bond lost = 1', 'Bluetooth = CONNECTED bond lost = 1',
                               'Bluetooth = CONNECTED bond lost = 0'])
        self.assertEqual([(r[2], r[3]) for r in got],
                         [('BOND_LOST', '1'), ('CONNECTED', '1'), ('CONNECTED', '0')])

    def test_bond_lost_flag_of_older_logs(self):
        """A log written before the flag has none: the connection is a link, as it was then."""
        got = self.ble_states(['Bluetooth = CONNECTED'])
        self.assertEqual([(r[2], r[3]) for r in got], [('CONNECTED', '0')])

    def test_initial_gps_off(self):
        lines = [core('10-08', 18 * 3600 - 5, 'SetGpsDisabled', 'GPS ignored by the user = 1')]
        lines += self.drive(30)
        self.assertEqual([(r[0], r[2]) for r in self.records(lines) if r[0] == 'X'], [('X', '1')])

    def test_a_tagged_log_gives_the_same_input(self):
        """A log of LOGFMT 2 is driven again as the same log of LOGFMT 1: the data lines, and the switch of the
        user before the first line of the file."""
        plain = [core('10-08', 18 * 3600 - 5, 'SetGpsDisabled', 'GPS ignored by the user = 1')] + self.drive(30)
        tagged = [core('10-08', 18 * 3600 - 5, 'SetGpsDisabled', 'ACTION gps_off ms=%d disabled=1 by=restore '
                       'GPS ignored by the user = 1' % LOGFMT_MS)] + self.drive(30, tagged=True)
        records = self.records(plain)
        # The box data of the second: without it the two inputs would be equal and empty.
        self.assertTrue([r for r in records if r[0] == 'B'])
        self.assertEqual([(r[0], r[2]) for r in records if r[0] == 'X'], [('X', '1')])
        self.assertEqual(self.records(tagged), records)


class ExportTest(unittest.TestCase):
    def test_csv_and_gpx(self):
        trip = analyse(('app.log', android_drive(seconds=20, stand=0))).trips[0]
        csv = trip.csv().splitlines()
        self.assertTrue(csv[0].startswith('time,src,lat,lon,acc,bear,age,ref,err_m,along_m,across_m,'))
        self.assertTrue(csv[1].startswith('2026-10-08T18:00:02.000,INERTIAL,'))
        gpx = trip.gpx()
        self.assertEqual(gpx.count('<trk>'), 2)
        self.assertIn('<time>2026-10-08T18:00:02.000</time>', gpx)

    def test_replay(self):
        trip = analyse(('app.log', android_drive(seconds=60, stand=0))).trips[0]
        replay = android_drive(seconds=60, stand=0, header=False, error=lambda s: 40.0)
        result = trip.replay(('\n'.join(replay) + '\n').encode())
        stats = result['stats']
        self.assertEqual((stats['lines'], len(result['track'])), (60, 60))
        self.assertEqual(dict((name, e and round(e['median'])) for name, e in stats['errors']),
                         {'the trip, all': 3, 'the trip, same seconds': 3, 'driven again': 40})
        self.assertEqual([(s['kind'], s['start']) for s in result['stretches']], [('worse', trip.start + 1000)])

    def test_error_stats(self):
        self.assertEqual(nogps_replay.error_stats([]), None)
        self.assertEqual(nogps_replay.error_stats([10, 40, 60, 120])['over50'], 50)


class RulesTest(unittest.TestCase):
    def trip(self, lines, fields=lambda s: {}):
        log = android_drive(seconds=120, stand=0, fields=fields)
        log += [core('10-08', 18 * 3600 + sec, 'F', text) for sec, text in lines]
        return analyse(('app.log', log)).trips[0]

    def test_counts_and_what_came_next(self):
        trip = self.trip(
            [(10, 'Turn from 10 to 100 is moved to the crossing by 12 m'),
             (50, 'Bend: moved along the road by 20 m'),
             (51, 'Bend: moved along the road by 9 m, told repeatedly to a slow car'),
             (70, 'Turn from 10 to 100 has followed the roads, the crossing 40 m away would move the car by 50 m'),
             (72, 'tap = ms::LatLon(10.0, 20.0) location = ms::LatLon(10.0, 20.0) bearing = 0'),
             (105, 'FORK the car goes along the branch 5 m aside')],
            lambda s: dict(lost='1') if 55 <= s < 60 else {})
        counts = trip.rule_counts()
        self.assertEqual(counts['turn moved to a crossing'], dict(fired=1, ok=1, lost=0, tap=0))
        # 10 m/s: 300 m take 30 s, the loss at 55 s is within them.
        self.assertEqual(counts['bend moved'], dict(fired=1, ok=0, lost=1, tap=0))
        self.assertEqual(counts['bend moved, repeated'], dict(fired=1, ok=0, lost=1, tap=0))
        self.assertEqual(counts['turn left by "followed the roads"'], dict(fired=1, ok=0, lost=0, tap=1))
        self.assertEqual(counts['fork branch chosen'], dict(fired=1, ok=1, lost=0, tap=0))
        self.assertNotIn('loop', counts)

    def test_speed_not_fresh_does_not_stretch_the_window(self):
        # 10 m/s from the rule at 10 s, "speed=-1" (not fresh) from 20 s to 80 s: the car does not drive back, so the
        # 300 m are driven by 98 s and the loss at 99 s is outside the window.
        trip = self.trip([(10, 'Loop: the way driven lies on the roads 20 m away, moved there')],
                         lambda s: dict(speed='-1') if 20 <= s < 80 else dict(lost='1') if s >= 99 else {})
        self.assertEqual(trip.rule_counts()['loop'], dict(fired=1, ok=1, lost=0, tap=0))

    def test_the_gps_speed_does_not_drive_the_window(self):
        # The car stands (speed=0) from 20 s to 80 s while GPS still reports 36 km/h: the window follows the car, so
        # the 300 m are not driven before the loss at 90 s.
        trip = self.trip([(10, 'Loop: the way driven lies on the roads 20 m away, moved there')],
                         lambda s: dict(speed='0') if 20 <= s < 80 else dict(lost='1') if s >= 90 else {})
        self.assertEqual(trip.rule_counts()['loop'], dict(fired=1, ok=0, lost=1, tap=0))

    def test_a_tap_of_the_panel_is_not_a_map_tap(self):
        tap = 'ACTION tap ms=1760000020000 by=%s tap = ms::LatLon(10.0, 20.0) location = ms::LatLon(10.0, 20.0)'
        for by, key in (('gps', 'ok'), ('user', 'tap')):
            trip = self.trip([(10, 'Loop: the way driven lies on the roads 20 m away, moved there'),
                              (20, tap % by)])
            self.assertEqual(trip.rule_counts()['loop'][key], 1, by)

    def test_a_road_already_lost_is_not_a_new_loss(self):
        trip = self.trip([(30, 'Loop: the way driven lies on the roads 20 m away, moved there')],
                         lambda s: dict(lost='1') if 20 <= s < 60 else {})
        self.assertEqual(trip.rule_counts()['loop'], dict(fired=1, ok=1, lost=0, tap=0))

    def test_report(self):
        log = android_drive(seconds=120, stand=0) + [
            core('10-08', 18 * 3600 + 10, 'F', 'Loop: the way driven lies on the roads 20 m away, moved there')]
        out = io.StringIO()
        with redirect_stdout(out):
            nogps_log.print_rules(analyse(('app.log', log)))
        loop = next(line for line in out.getvalue().splitlines() if line.startswith('loop'))
        self.assertIn('rare: 1 trips', loop)


class SearchTest(unittest.TestCase):
    def search_log(self, day, lines):
        log = android_drive(day, seconds=3, stand=0)
        for i, (second, text) in enumerate(lines):
            log.append(core(day, 18 * 3600 + 10 + second, 'LogSearch', text, file='map/search_api.cpp:1'))
        return log

    def test_queries_taps_and_places_per_set(self):
        query = 'SEARCH query ms=%d chars=5 category=0 results=17 pivot=mark' % LOGFMT_MS
        tap = 'SEARCH tap ms=%d place=%d results=17 dist=840 errors=0 type=feature'
        # 2026-10-08 is made from, 2026-10-09 is held out by the list of the test.
        made = self.search_log('10-08', [(0, query), (1, tap % (LOGFMT_MS, 0)), (5, query), (6, tap % (LOGFMT_MS, 3)),
                                         (7, tap % (LOGFMT_MS, 6)), (9, query)])
        held = self.search_log('10-09', [(0, query), (1, tap % (LOGFMT_MS, 2))])
        out = io.StringIO()
        with mock.patch.object(nogps_replay, 'held_out_days', lambda: {'10-09'}), redirect_stdout(out):
            nogps_log.print_search(analyse(('a.log', made), ('b.log', held), year=2026))
        rows = {line.split()[0] + ' ' + line.split()[1]: line.split()[2:] for line in out.getvalue().splitlines()[1:]}
        self.assertEqual(rows['made from'], ['3', '3', '67%', '3.0', '3.0', '33%'])
        self.assertEqual(rows['held out'], ['1', '1', '100%', '2.0', '2.0', '0%'])


class LossesTest(unittest.TestCase):
    TAP = 'tap = ms::LatLon(10.0, 20.0) location = ms::LatLon(10.0, 20.0) bearing = 0'

    def losses(self, fields, taps=(), seconds=60, by=None):
        log = android_drive(seconds=seconds, stand=0, fields=fields)
        for sec in taps:
            head = 'ACTION tap ms=%d by=%s ' % (LOGFMT_MS, by) if by else ''
            log.append(core('10-08', 18 * 3600 + sec, 'PutMark', head + self.TAP, ms=500))
        return analyse(('app.log', log)).groups[0].road_losses()

    def lost(self, first, after, **extra):
        return lambda s: dict(lost='1', **extra) if first <= s < after else {}

    def test_fresh_fix_near_the_mark_is_fixable(self):
        (loss,) = self.losses(self.lost(10, 20))
        self.assertEqual((loss['seconds'], loss['fixable_s'], loss['taps']), (10, 0, False))

    def test_old_fix_is_fixed_when_a_new_one_comes(self):
        def fields(s):
            if 10 <= s < 20:
                return dict(lost='1', gps='%.6f,%.6f/5.0/36.0/0/%d.0/3' % (START_LAT + s * 10 * DEG_PER_M, START_LON,
                                                                          9 if s < 14 else 1))
            return {}
        (loss,) = self.losses(fields)
        self.assertEqual(loss['fixable_s'], 4)

    def test_reasons(self):
        (loss,) = self.losses(self.lost(10, 20, spoofed='1'))
        self.assertEqual((loss['fixable_s'], loss['why']), (None, 'GPS is spoofed'))
        (loss,) = self.losses(self.lost(10, 20, gps='%.6f,%.6f/400.0/36.0/0/0.00/3' % (START_LAT, START_LON)))
        self.assertEqual(loss['why'], 'fix accuracy over 300 m')
        # The mark is 3 m ahead of the fix: 1000 m away is farther than the loss, the accuracies and 50 m allow.
        (loss,) = self.losses(self.lost(10, 20, gps='%.6f,%.6f/5.0/36.0/0/0.00/3' % (START_LAT + 1000 * DEG_PER_M,
                                                                                        START_LON)))
        self.assertEqual(loss['why'], 'fix too far from the mark')

    def test_distance_driven_since_the_loss_allows_a_farther_fix(self):
        # 10 m/s: a fix 150 m behind the mark is within driven + 10 + 5 + 50 m once the car has driven 85 m.
        def fields(s):
            if 10 <= s < 30:
                return dict(lost='1', gps='%.6f,%.6f/5.0/36.0/0/0.00/3' % (START_LAT + (s * 10 + 3 - 150) * DEG_PER_M,
                                                                              START_LON))
            return {}
        (loss,) = self.losses(fields)
        self.assertEqual(loss['fixable_s'], 9)

    def test_tap_and_no_loss(self):
        losses = self.losses(self.lost(10, 20, spoofed='1'), taps=[14])
        self.assertTrue(losses[0]['taps'])
        self.assertEqual(self.losses(lambda s: {}), [])

    def test_the_gps_tap_of_the_panel_is_no_tap_on_the_map(self):
        """Engine::PutMark writes the same line for the user, the road lost panel, the peer place and the guess of
        the core: its by= tells them apart. The manual mode is on during a loss, so "ACTION manual" is not written
        there and cannot tell."""
        for by in ('gps_mark', 'peer', 'core'):
            losses = self.losses(self.lost(10, 20, spoofed='1'), taps=[14], by=by)
            self.assertFalse(losses[0]['taps'], by)
        for by in ('tap', 'user'):
            losses = self.losses(self.lost(10, 20, spoofed='1'), taps=[14], by=by)
            self.assertTrue(losses[0]['taps'], by)

    def test_a_stale_speed_drives_nothing(self):
        """"speed=-1" is a speed not fresh: it neither drives the loss on nor takes back what the car has driven."""
        # The fix is 9 s old for 200 s, then a fresh one comes 60 m behind the mark: the 10 m of the mark, the 5 m
        # of the fix and the 50 m of margin allow it, and a speed of -1 km/h would have eaten them.
        def fields(s):
            if s < 10:
                return {}
            fresh = s >= 210
            return dict(lost='1', speed='-1',
                        gps='%.6f,%.6f/5.0/36.0/0/%d.00/3' % (START_LAT + (s * 10 + 3 - (60 if fresh else 0))
                                                              * DEG_PER_M, START_LON, 1 if fresh else 9))
        (loss,) = self.losses(fields, seconds=230)
        self.assertEqual(loss['fixable_s'], 200)

    def test_a_loss_across_a_stand_is_one_loss(self):
        """The car stands lost between two drives: standing splits the trips, the loss is one."""
        lost = self.lost(0, 10 ** 9)
        log = android_drive(seconds=20, stand=0, fields=lost)
        # The core writes a standing car every 35 s, see STAND_TRIP_S, and the stand is longer than STAND_SPLIT_S.
        log += [core('10-08', 18 * 3600 + 22 + s, 'LogTrip',
                     trip_line(lat=START_LAT + 200 * DEG_PER_M, kmh=0.0, lost='1', speed='0'),
                     file='nogps/engine.cpp:1526') for s in range(0, 400, 35)]
        log += android_drive(start=18 * 3600 + 422, seconds=20, stand=0, fields=lost, header=False)
        analysis = analyse(('app.log', log))
        self.assertEqual([trip.driven for trip in analysis.trips], [True, False, True])
        (loss,) = analysis.groups[0].road_losses()
        self.assertEqual((loss['t'], loss['seconds']), (DAY_MS + (18 * 3600 + 2) * 1000, 441))

    def test_a_loss_after_a_pause_of_the_log_is_another_loss(self):
        """The app was not running for an hour: what the core kept of the loss across it is not known."""
        lost = self.lost(0, 10 ** 9)
        log = android_drive(seconds=20, stand=0, fields=lost)
        log += android_drive(start=18 * 3600 + 3600, seconds=20, stand=0, fields=lost, header=False)
        first, second = analyse(('app.log', log)).groups[0].road_losses()
        self.assertEqual((first['seconds'], second['seconds']), (19, 19))

    def test_report_per_set(self):
        log = android_drive(seconds=60, stand=0, fields=self.lost(10, 20))
        out = io.StringIO()
        with redirect_stdout(out):
            nogps_log.print_losses(analyse(('app.log', log)))
        self.assertIn('made from        1         1         0                 0', out.getvalue())


class TaggedLinesTest(unittest.TestCase):
    """A line of LOGFMT 2 counts as the sentence of LOGFMT 1 did: a trip of an old log is compared with a replay."""

    def test_rules_of_a_tagged_log_are_counted(self):
        log = logfmt2(android_drive(seconds=120, stand=0))
        log += [core('10-08', 18 * 3600 + sec, 'F', text) for sec, text in (
            (10, 'RULE bend_moved ms=1760000010000 kind=bend Bend: moved along the road by 20 m'),
            (15, 'RULE bend_moved_repeated ms=1760000015000 kind=bend Bend: moved along the road by 20 m, '
                 'told repeatedly'),
            (20, 'RULE bend_confirmed ms=1760000020000 kind=bend Bend: the position fits the road, ahead by 1 m'),
            (30, 'RULE loop ms=1760000030000 Loop: the way driven lies on the roads 20 m away, moved there'),
            (40, 'RULE fork_branch ms=1760000040000 FORK the car goes along the branch 5 m aside'),
            (50, 'RULE followed_apart ms=1760000050000 The car maneuvers 30 m off the roads at up to 10 km/h'),
            (60, 'RULE late_turn ms=1760000060000 deg=40 The car has turned by 40 degrees from its road'),
            (70, 'RULE road_lost ms=1760000070000 jump=0 The road is lost after 120 m, stopping at 10.0,20.0'),
            (80, 'RULE mark_switched_turn ms=1760000080000 The car is shown on another road it may be on: '
                 'WAY misses the roads at 3 points where it was shown, at 1 there, marks 2'))]
        counts = analyse(('app.log', log)).trips[0].rule_counts()
        self.assertEqual({name for name, count in counts.items() if count['fired']},
                         {'bend moved', 'bend moved, repeated', 'bend confirmed', 'loop', 'fork branch chosen',
                          'followed apart', 'late turn', 'road lost', 'mark switched by the way'})

    def test_repeated_bend_is_counted_apart_from_bend(self):
        """Both kinds of bend_moved_repeated count, the ordinary bend and the gentle one."""
        for name, texts in (
                ('LOGFMT 1', ['Bend: moved along the road by 20 m', 'Bend: moved along the road by 30 m, told '
                              'repeatedly to a slow car', 'Bend: moved along the road by 40 m, told repeatedly',
                              'Gentle bend: moved along the road by 50 m, told repeatedly',
                              'Gentle bend: moved along the road by 60 m',
                              'Gentle bend: the position fits the road, ahead by 2 m']),
                ('LOGFMT 2', ['RULE bend_moved ms=1 kind=bend Bend: moved along the road by 20 m',
                              'RULE bend_moved_repeated ms=2 kind=bend Bend: moved along the road by 30 m, '
                              'told repeatedly',
                              'RULE bend_moved_repeated ms=3 kind=bend Bend: moved along the road by 40 m, '
                              'told repeatedly',
                              'RULE bend_moved_repeated ms=4 kind=gentle Gentle bend: moved along the road by '
                              '50 m, told repeatedly',
                              'RULE bend_moved ms=5 kind=gentle Gentle bend: moved along the road by 60 m',
                              'RULE bend_confirmed ms=6 kind=gentle Gentle bend: the position fits the road, '
                              'ahead by 2 m'])):
            with self.subTest(name):
                log = android_drive(seconds=120, stand=0)
                log += [core('10-08', 18 * 3600 + 10 * (i + 1), 'F', t) for i, t in enumerate(texts)]
                if name == 'LOGFMT 2':
                    log = logfmt2(log)
                counts = analyse(('app.log', log)).trips[0].rule_counts()
                self.assertEqual(counts['bend moved']['fired'], 2)
                self.assertEqual(counts['bend moved, repeated']['fired'], 3)
                self.assertEqual(counts['bend confirmed']['fired'], 1)

    def test_events_of_a_tagged_log_keep_their_category(self):
        day, t = '10-08', 18 * 3600
        log = logfmt2(android_drive(seconds=30, stand=0)) + [
            core(day, t + 5, 'PutMark', 'ACTION tap ms=1760000005000 tap = ms::LatLon(10.0001, 20.0002) '
                 'location = ms::LatLon(10.0, 20.0) bearing = 0 heading was = nullopt'),
            core(day, t + 6, 'LogStateChanges', 'EVENT gps_signal ms=1760000006000 from=GOOD to=NONE '
                 'GPS signal GOOD -> NONE'),
            core(day, t + 7, 'Lost', 'RULE road_lost ms=1760000007000 jump=0 The road is lost after 120 m, '
                 'stopping at ms::LatLon(10.0, 20.0)'),
            # The replay tool writes its notifications as "EVENT <event>", without a name and ms=.
            core(day, t + 8, 'OnEvent', 'EVENT GpsBack'),
        ]
        events = analyse(('app.log', log)).trips[0].events
        self.assertEqual([(e['cat'], e['name']) for e in events
                          if e['name'] not in ('app started', 'navigation started')],
                         [('user', 'tap'), ('state', 'GPS signal'), ('road', 'road lost'), ('app', 'notification')])

    def test_data_lines_of_a_tagged_log_are_read(self):
        """The series of the viewer, the TRIP rows and the calibration of the trip are the same of both formats."""
        log = android_drive(seconds=30, stand=10) + [
            core('10-08', 18 * 3600 + 3, 'LogCalibration', 'CALIBRATION car=C47D scale=1.04 table=3',
                 file='nogps/inertial_navigator.cpp:393'),
            core('10-08', 18 * 3600 + 15, 'OnMotion', 'GYRO 12.5 0.10 0.20 0.30 0.40 0.50 36 36 36 36 36',
                 file='nogps/inertial_navigator.cpp:1254')]
        for name, lines in (('LOGFMT 1', log), ('LOGFMT 2', logfmt2(log))):
            with self.subTest(name):
                analysis = analyse(('app.log', lines))
                group = analysis.groups[0]
                self.assertEqual([round(value, 2) for _, value in group.series['gyro']], [0.5, 1.0, 1.5, 2.0, 2.5])
                self.assertEqual(len(group.series['accb']), 100)
                self.assertEqual(len(group.rows), 30)
                self.assertEqual(analysis.trips[0].calibration(), 'car=C47D scale=1.04 table=3')

    def test_the_trip_csv_reads_a_tagged_log(self):
        lines = logfmt2(android_drive(seconds=10, stand=0))
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'app.log')
            with open(path, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines) + '\n')
            rows = nogps_trip_log.read_rows([path], 2026)
        self.assertEqual(len(rows), 10)
        self.assertEqual({row['src'] for row in rows}, {'INERTIAL'})

    def test_compare_counts_a_tagged_replay_as_the_trip(self):
        sentences = ['Bend: moved along the road by 20 m', 'FORK the car goes along the branch 5 m aside',
                     'The car is shown on another road it may be on: the shown one stands lost']
        heads = ['RULE bend_moved ms=1760000010000 kind=bend ', 'RULE fork_branch ms=1760000020000 ',
                 'RULE mark_switched_stand_lost ms=1760000030000 ']
        trip = [core('10-08', 18 * 3600 + 10 * i, 'F', text) for i, text in enumerate(sentences)]
        replay = [core('10-08', 18 * 3600 + 10 * i, 'F', head + text)
                  for i, (head, text) in enumerate(zip(heads, sentences))]
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for name, lines in (('trip.log', trip), ('replay.log', replay)):
                paths.append(os.path.join(folder, name))
                with open(paths[-1], 'w', encoding='utf-8') as f:
                    f.write('\n'.join(lines) + '\n')
            _, others, _ = nogps_replay.read(paths[:1], '10-08')
            _, replayed, _ = nogps_replay.read(paths[1:], '10-08')
        stats = nogps_replay.compare_stats([], others, [], replayed, 0, 86_400_000, 15)
        counts = {name: (a, b) for name, a, b in stats['events']}
        self.assertEqual(counts['bend moved'], (1, 1))
        self.assertEqual(counts['seconds on another branch of a fork'], (1, 1))
        self.assertEqual(counts['mark switched to another road'], (1, 1))


class TripCsvTest(unittest.TestCase):
    """nogps_trip_log.py: the rows of one phone."""

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'argv', ['nogps_trip_log.py', *argv]), redirect_stdout(out), \
                mock.patch.object(sys, 'stderr', err):
            try:
                nogps_trip_log.main()
            except SystemExit:
                pass
        return out.getvalue(), err.getvalue()

    def test_the_logs_of_two_phones_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {
                'Pixel_7-a3f9/2026-10-08/180000.log': with_logfmt(android_drive(seconds=3, stand=0)),
                'SM_S918B-0b1c/2026-10-08/180000.log': with_logfmt(android_drive(seconds=3, stand=0),
                                                                   'SM_S918B-0b1c')})
            out, err = self.run_main(folder)
            self.assertIn('the logs of Pixel_7-a3f9, SM_S918B-0b1c: give the logs of one phone', err)
            self.assertEqual(out, '')

    def test_the_rows_of_one_phone(self):
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'Pixel_7-a3f9/2026-10-08/180000.log': with_logfmt(android_drive(seconds=3, stand=0))})
            out, _ = self.run_main(folder, '--year', '2026')
            self.assertEqual(len(out.splitlines()), 4)


class HeldOutTest(unittest.TestCase):
    def test_days_and_sets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'days.txt')
            with open(path, 'w') as f:
                f.write('# comment\n10-09  # another car\n\n')
            held_out = nogps_replay.held_out_days(path)
            self.assertEqual(held_out, {'10-09'})
            self.assertEqual([nogps_replay.set_of(d, held_out) for d in ('10-08', '10-09')],
                             ['made from', 'held out'])
            log = os.path.join(folder, 'log.log')
            with open(log, 'w') as f:
                f.write('\n'.join(android_drive('10-08', seconds=3, stand=0) + android_drive('10-09', seconds=2,
                                                                                            stand=0)) + '\n')
            out = io.StringIO()
            with redirect_stdout(out):
                nogps_replay.days(argparse.Namespace(logs=[log]))
            self.assertEqual(out.getvalue().splitlines()[:2], ['10-08       3 TRIP lines  made from',
                                                               '10-09       2 TRIP lines  made from'])

    def test_file_of_the_repo_parses(self):
        self.assertIsInstance(nogps_replay.held_out_days(), set)


class HeldOutRuleTest(unittest.TestCase):
    def test_days_of_the_rule_and_of_the_list(self):
        listed = {'10-09'}
        self.assertEqual({day: nogps_replay.set_of(day, listed)
                          for day in ('2026-11-24', '2026-11-28', '2026-11-23', '2026-10-08', '2026-10-09', '11-24')},
                         {'2026-11-24': 'held out', '2026-11-28': 'held out', '2026-11-23': 'made from',
                          '2026-10-08': 'made from', '2026-10-09': 'held out', '11-24': 'made from'})

    def test_days_take_the_year_of_their_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            write_tree(folder, {'Pixel_7-a3f9/2026-11-24/180000.log': with_logfmt(android_drive('11-24', seconds=3,
                                                                                                stand=0)),
                                'Pixel_7-a3f9/2026-11-23/180000.log': with_logfmt(android_drive('11-23', seconds=2,
                                                                                                stand=0))})
            out = io.StringIO()
            with mock.patch.object(nogps_replay, 'held_out_days', lambda: set()), redirect_stdout(out):
                nogps_replay.days(argparse.Namespace(logs=nogps_trip_log.log_files([folder])))
            self.assertEqual(out.getvalue().splitlines(), ['11-23       2 TRIP lines  made from',
                                                           '11-24       3 TRIP lines  held out',
                                                           'held out 1 of 2 days'])


def write_flag(folder, name, values, png=True, m4a=False):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, name + '.json'), 'w') as f:
        f.write(json.dumps(values))
    for ext, wanted in (('png', png), ('m4a', m4a)):
        if wanted:
            with open(os.path.join(folder, '%s.%s' % (name, ext)), 'wb') as f:
                f.write(b'data')


def ios_drive(utc_start, seconds):
    """An iOS log of a drive that starts at |utc_start| (datetime, UTC): the app writes UTC times."""
    lines = ['I(1) 0.00000 Local time: %s +0000 , Time Zone: EET' % utc_start.strftime('%Y-%m-%d %H:%M:%S')]
    lines += ['I(2) %d.00000 nogps/engine.cpp:1526 LogTrip(): %s'
              % (s + 1, trip_line(lat=START_LAT + s * 10 * DEG_PER_M)) for s in range(seconds)]
    return lines


class FlagsTest(unittest.TestCase):
    """A flag goes on the trip of its phone: an Android trip by the local time of the flag's name, an iOS trip by
    UTC, from the offset its day's logs tell (the phone is 2 h ahead of UTC here)."""
    IOS_START = nogps_log.datetime(2026, 11, 24, 15, 0, 0)

    def tree(self, folder):
        ios_header = logfmt_line('iPhone-1111', trip='170000').replace(
            'ms=%d' % LOGFMT_MS, 'ms=%d' % nogps_log.to_ms(self.IOS_START))
        write_tree(folder, {
            'Pixel_7-a3f9/2026-11-24/180000.log': with_logfmt(android_drive('11-24', seconds=120, stand=0)),
            'iPhone-1111/2026-11-24/170000.log': [ios_header] + ios_drive(self.IOS_START, 120)})
        android = os.path.join(folder, 'Pixel_7-a3f9', '2026-11-24', 'flags')
        write_flag(android, '20261124-180100', dict(n=1, lat=10.0, lon=20.0, voice_s=7, sent=False), m4a=True)
        write_flag(android, '20261124-200000', dict(n=2, voice_s=0, sent=True))
        write_flag(os.path.join(folder, 'iPhone-1111', '2026-11-24', 'flags'), '20261124-170030',
                   dict(n=4, lat=10.0, lon=20.0, voice_s=0, sent=False))

    def run_main(self, *args):
        out = io.StringIO()
        with mock.patch.object(sys, 'argv', ['nogps_log.py', *args]), redirect_stdout(out):
            nogps_log.main()
        return out.getvalue()

    def test_flags_on_their_trips(self):
        with tempfile.TemporaryDirectory() as folder:
            self.tree(folder)
            analysis = nogps_log.Analysis(nogps_log.load_paths([folder]), flags=nogps_log.load_flags([folder]))
            by_phone = {t.group.phone: t for t in analysis.trips}
            android, ios = by_phone['Pixel_7-a3f9'], by_phone['iPhone-1111']
            day = nogps_log.to_ms(nogps_log.datetime(2026, 11, 24))
            self.assertEqual([(f['n'], f['t']) for f in android.flags], [(1, day + (18 * 60 + 1) * 60_000)])
            self.assertEqual([(f['n'], f['t']) for f in ios.flags], [(4, nogps_log.to_ms(self.IOS_START) + 30_000)])
            late = next(f for f in analysis.flags if f['n'] == 2)
            self.assertEqual((late['trip'], late['t']), (None, day + 20 * 3600_000))
            self.assertEqual(android.summary()['flags'], 1)

    def test_reports(self):
        with tempfile.TemporaryDirectory() as folder:
            self.tree(folder)
            out = self.run_main('flags', folder)
            lines = out.splitlines()
            self.assertEqual(lines[-1], '3 flags, 2 on a trip')
            android = next(t.id for t in nogps_log.Analysis(nogps_log.load_paths([folder])).trips
                           if t.group.phone == 'Pixel_7-a3f9')
            day = nogps_log.to_ms(nogps_log.datetime(2026, 11, 24))
            self.assertIn('Pixel_7-a3f9       2026-11-24 %4d  18:01:00 18:01:00   7 s    no  #trip=%d&t=%d'
                          % (android, android, day + (18 * 60 + 1) * 60_000), out)
            self.assertIn('Pixel_7-a3f9       2026-11-24    -  20:00:00 -            -   yes  no trip', out)
            self.assertIn('iPhone-1111        2026-11-24', out)
            self.assertNotRegex(out, r'\d+\.\d+,\s*\d+\.\d+')
            self.assertRegex(self.run_main('trips', folder), r'\n +%d +2026-11-24 18:00 .* +1 \d+\n' % android)
            trip_out = self.run_main('trip', folder, '--trip', str(android))
            self.assertIn('flags: 1\n  18:01:00 flag 1 18:01:00 voice 7 s (#trip=%d&t=%d)'
                          % (android, day + (18 * 60 + 1) * 60_000), trip_out)
            state = self.run_main('state', folder, '--trip', str(android), '--at', '18:01:10')
            self.assertIn('flags within 30 s: -10 s flag 1 18:01:00 voice 7 s', state)
            # A file given takes the flags of its day folder.
            log = os.path.join(folder, 'Pixel_7-a3f9', '2026-11-24', '180000.log')
            self.assertIn('2 flags, 1 on a trip', self.run_main('flags', log))


class RunTest(unittest.TestCase):
    @staticmethod
    def drive(day, seconds):
        """A drive with the rotation and the speed of the box, which the input is made from."""
        return android_drive(day, seconds=seconds, stand=0) + [
            core(day, 18 * 3600 + 2 + s, 'OnMotion', 'GYRO 0.0 0 0 0 0 0 36 36 36 36 36', ms=600,
                 file='nogps/inertial_navigator.cpp:1001') for s in range(seconds)]

    def test_days_driven_by_the_tool(self):
        with tempfile.TemporaryDirectory() as folder:
            log = os.path.join(folder, 'log.log')
            with open(log, 'w') as f:
                f.write('\n'.join(self.drive('10-08', 60) + self.drive('10-09', 40)) + '\n')
            # The tool drives every day 40 m ahead of GPS, and tells what it was given.
            replayed = os.path.join(folder, 'replayed.log')
            with open(replayed, 'w') as f:
                f.write('\n'.join(android_drive('10-08', seconds=60, stand=0, header=False, error=lambda s: 40.0) +
                                  android_drive('10-09', seconds=40, stand=0, header=False, error=lambda s: 40.0)))
            tool = os.path.join(folder, 'tool.py')

            def write_tool(failing_day):
                with open(tool, 'w') as f:
                    f.write('#!%s\nimport shutil, sys\nshutil.copy(%r, sys.argv[-1])\n'
                            'open(sys.argv[-1] + ".args", "w").write(" ".join(sys.argv[1:-2]))\n'
                            'if %r in sys.argv[-1]:\n    sys.exit(3)\nopen(sys.argv[-1] + ".done", "w")\n'
                            % (sys.executable, replayed, failing_day))
                os.chmod(tool, 0o755)

            write_tool('none')
            out = os.path.join(folder, 'out')
            args = argparse.Namespace(logs=[log], tool=tool, data_path='maps', resources_path='data',
                                      settings='settings.ini', day=None, start=None, end=None, jobs=2, output=out,
                                      no_taps=False, no_route=False, change=15, fresh=False, any_maps=False)
            lines = io.StringIO()
            with mock.patch.object(nogps_replay, 'held_out_days', lambda: {'10-09'}), redirect_stdout(lines):
                nogps_replay.run(args)
            lines = lines.getvalue().splitlines()
            # The held-out days come first, each set with its seconds of all days.
            self.assertEqual([line[:15] for line in lines[2:6]],
                             ['10-09 held out ', 'held out, all  ', '10-08 made from', 'made from, all '])
            self.assertEqual(lines[2].split()[3:11], ['40', '3', '3', '40', '40', '37', '37', '0/0'])
            self.assertEqual(lines[5].split()[3:7], ['59', '3', '3', '40'])
            with open(os.path.join(out, '10-08-out.txt.args')) as f:
                self.assertEqual(f.read(), '--data_path maps --resources_path data --settings settings.ini')
            for name in ('in.txt', 'tool.log', 'compare.txt'):
                self.assertTrue(os.path.exists(os.path.join(out, '10-08-' + name)), name)

            # A day the tool has not driven to the end is told, the other days are compared.
            write_tool('10-09')
            lines = io.StringIO()
            with mock.patch.object(nogps_replay, 'held_out_days', lambda: {'10-09'}), redirect_stdout(lines):
                nogps_replay.run(args)
            lines = lines.getvalue().splitlines()
            self.assertTrue(lines[2].startswith('10-09 held out  the tool has not driven it to the end, exit code 3'),
                            lines[2])
            self.assertEqual(lines[3][:15], '10-08 made from')


class ReportTest(unittest.TestCase):
    def report(self, function, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            function(*args)
        return out.getvalue().splitlines()

    def test_moment_after_midnight(self):
        trip = analyse(('app.log', android_drive(start=23 * 3600 + 59 * 60, seconds=120, stand=0))).trips[0]
        self.assertEqual(nogps_log.moment(trip, '23:59:30'), trip.start + 28_000)
        self.assertEqual(nogps_log.moment(trip, '00:00:30'), trip.start + 88_000)

    def test_state(self):
        log = android_drive(seconds=30, stand=0,
                            fields=lambda s: dict(snapwhy='ANGLE', wait='12', bf='9B') if s >= 10 else {})
        log.append(core('10-08', 18 * 3600 + 14, 'Check', 'Untrusted location = ms::LatLon(10.0, 20.0) 80',
                        level='W'))
        trip = analyse(('app.log', log)).trips[0]
        lines = self.report(nogps_log.print_state, trip, nogps_log.moment(trip, '18:00:12'), False)
        self.assertEqual(lines[0], '18:00:12, TRIP line 11 of 30 of trip 0 (in the viewer: #trip=0&t=%d), * changed '
                                   'since the line before' % (trip.start + 10_000))
        box = next(line for line in lines if line.startswith('Box: '))
        self.assertIn('bf=9B (IMU_OK BIAS_OK FWD_OK OBD_OK MOUNT_MOVED)*', box)
        road = next(line for line in lines if line.startswith('Road matching: '))
        self.assertIn('snapwhy=ANGLE*', road)
        self.assertIn('wait=12*', road)
        self.assertFalse(any(line.startswith('Other: ') for line in lines))
        self.assertIn('    +2 s W gps/untrusted location: Untrusted location = ms::LatLon(10.0, 20.0) 80', lines)
        # The TRIP and sensor lines are left out of the log lines.
        self.assertEqual(lines[-1][-len('80'):], '80')

    def test_rows(self):
        trip = analyse(('app.log', android_drive(seconds=30, stand=0))).trips[0]
        lines = self.report(nogps_log.print_rows, trip, trip.start, trip.start + 10_000, ['src', 'err_m', 'x'], 5)
        self.assertEqual(lines, ['time      src       err_m     x', '18:00:02  INERTIAL  3.0       -',
                                 '18:00:07  INERTIAL  3.0       -', '18:00:12  INERTIAL  3.0       -'])


if __name__ == '__main__':
    unittest.main()
