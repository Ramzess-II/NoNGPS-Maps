#!/usr/bin/env python3
"""Tests of nogps_log.py on made-up logs: the places are not real.

  python3 tools/python/nogps_log_test.py
"""

import argparse
import io
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


def analyse(*logs, year=None):
    return nogps_log.Analysis([(name, ('\n'.join(lines) + '\n').encode()) for name, lines in logs], year)


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

    def test_sensors(self):
        group = analyse(('app.log', android_drive(seconds=12))).groups[0]
        self.assertEqual(len(group.series['accb']), 10)
        self.assertEqual(group.series['accb'][0][1:], [0.1, 0.0, 0.0, 0.5])


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
            '%s (main) D/LocationState: LocationHelper.java:525 start(): ' % android_time(day, t + 11),
            '%s (main) I/Other: Other.java:1 run(): not a NoGPS line' % android_time(day, t + 12),
        ]
        events = analyse(('app.log', log)).trips[0].events
        self.assertEqual([(e['cat'], e['name']) for e in events if e['name'] not in ('app started',
                                                                                   'navigation started')], [
            ('user', 'tap'), ('state', 'GPS signal'), ('road', 'road lost'), ('box', 'box event'),
            ('route', 'route asked for'), ('other', 'A new line of'), ('app', 'location started')])
        self.assertEqual((events[2]['lat'], events[2]['lon']), (10.0001, 20.0002))


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
    def test_logs_of_two_phones_are_refused(self):
        log = '\n'.join(android_drive(seconds=20, stand=0))
        with tempfile.TemporaryDirectory() as folder:
            for phone in ('Pixel_7-a3f9', 'SM_S918B-0b1c'):
                os.makedirs(os.path.join(folder, phone, '2026-10-08'))
                with open(os.path.join(folder, phone, '2026-10-08', '180000.log'), 'w', encoding='utf-8') as f:
                    f.write(log)
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(sys, 'argv', ['nogps_replay.py', 'days', os.path.join(folder, 'Pixel_7-a3f9')]), \
                    redirect_stdout(out):
                nogps_replay.main()
            self.assertIn('10-08      20 TRIP lines', out.getvalue())
            with mock.patch.object(sys, 'argv', ['nogps_replay.py', 'days', folder]), \
                    mock.patch.object(sys, 'stderr', err), self.assertRaises(SystemExit):
                nogps_replay.main()
            self.assertIn('Pixel_7-a3f9, SM_S918B-0b1c: give the logs of one phone', err.getvalue())


class InputTest(unittest.TestCase):
    def test_zip_of_rotated_files(self):
        log = android_drive(seconds=60)
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            # The files overlap: the same lines are read once.
            z.writestr('logs/app.1.log', '\n'.join(log[:40]))
            z.writestr('logs/app.log', '\n'.join(log[:3] + log[30:]))
            z.writestr('logs/logcat.log', 'not read')
        analysis = nogps_log.Analysis([('logs.zip', data.getvalue())])
        self.assertEqual([f['name'] for f in analysis.files], ['logs.zip/logs/app.1.log', 'logs.zip/logs/app.log'])
        self.assertEqual(len(analysis.trips[0].rows), 60)

    def test_groups_by_phone(self):
        log = android_drive(seconds=30, stand=0)
        analysis = analyse(('log-08-10-26-Pixel_7-a3f9.log', log[:20]), ('log-08-10-26-Pixel_7-a3f9.1.log', log[20:]),
                           ('log-08-10-26-SM_S918B-0b1c.log', log), ('app.log', log))
        self.assertEqual([(g.platform, g.phone) for g in analysis.groups],
                         [('android', ''), ('android', 'Pixel_7-a3f9'), ('android', 'SM_S918B-0b1c')])
        self.assertEqual([len(g.rows) for g in analysis.groups], [30, 30, 30])
        self.assertEqual(sorted(t.summary()['phone'] for t in analysis.trips), ['', 'Pixel_7-a3f9', 'SM_S918B-0b1c'])

    def test_phone_of_name(self):
        self.assertEqual(nogps_trip_log.phone_of('logs.zip/logs/log-01-11-26-iPhone15_2-a3f9.12.log'), 'iPhone15_2-a3f9')
        self.assertEqual(nogps_trip_log.phone_of('log-01-11-26-Pixel_7-a3f9.log'), 'Pixel_7-a3f9')
        self.assertEqual(nogps_trip_log.phone_of('logs/app.1.log'), '')
        self.assertEqual(nogps_trip_log.phone_of('log.txt'), '')

    def test_phone_of_folder(self):
        self.assertEqual(nogps_trip_log.phone_of('logs.zip/logs/iPhone15_2-a3f9/2026-11-01/081500.log'), 'iPhone15_2-a3f9')
        self.assertEqual(nogps_trip_log.phone_of('trip-logs/Pixel_7-a3f9/2026-11-01/235907.log'), 'Pixel_7-a3f9')
        self.assertEqual(nogps_trip_log.phone_of('Pixel_7-a3f9/2026-11-01/235907.log'), 'Pixel_7-a3f9')
        self.assertEqual(nogps_trip_log.phone_of('C:\\logs\\Pixel_7-a3f9\\2026-11-01\\235907.log'), 'Pixel_7-a3f9')
        # A file taken out of its folders, the system log of "Report a bug", a folder that is not a day.
        self.assertEqual(nogps_trip_log.phone_of('235907.log'), '')
        self.assertEqual(nogps_trip_log.phone_of('logs/Pixel_7-a3f9/logcat.log'), '')
        self.assertEqual(nogps_trip_log.phone_of('logs/Pixel_7-a3f9/notes/235907.log'), '')

    def test_tree_of_two_phones(self):
        """The zips of two phones unpacked into one folder, and a zip of the same tree."""
        first, second = android_drive(seconds=30, stand=0), android_drive(seconds=40, stand=0)
        files = {'Pixel_7-a3f9/2026-10-08/180000.log': first[:20], 'Pixel_7-a3f9/2026-10-08/180019.log': first[20:],
                 'SM_S918B-0b1c/2026-10-08/180000.log': second, 'Pixel_7-a3f9/logcat.log': ['not read'],
                 'log-08-10-26-Pixel_7-a3f9.log': first}
        data = io.BytesIO()
        with tempfile.TemporaryDirectory() as folder, zipfile.ZipFile(data, 'w') as z:
            for name, lines in files.items():
                path = os.path.join(folder, 'logs', *name.split('/'))
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, 'w', encoding='utf-8') as f:
                    f.write('\n'.join(lines))
                z.writestr('logs/' + name, '\n'.join(lines))
            sources = nogps_log.load_paths([os.path.join(folder, 'logs')])
            # The same files in the order of their names.
            self.assertEqual(nogps_trip_log.log_files([folder]), [name for name, _ in sources])
        for analysis in (nogps_log.Analysis(sources), nogps_log.Analysis([('logs.zip', data.getvalue())])):
            self.assertEqual(sorted(f['phone'] for f in analysis.files),
                             ['Pixel_7-a3f9', 'Pixel_7-a3f9', 'Pixel_7-a3f9', 'SM_S918B-0b1c'])
            # The file named as before the tree has the lines of the phone again: read once.
            self.assertEqual([(g.platform, g.phone, len(g.rows)) for g in analysis.groups],
                             [('android', 'Pixel_7-a3f9', 30), ('android', 'SM_S918B-0b1c', 40)])

    def test_not_a_log(self):
        analysis = nogps_log.Analysis([('notes.txt', b'hello')])
        self.assertEqual((analysis.trips, analysis.notes), ([], ['notes.txt: not a log of the app']))


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
                              'Gentle bend: moved along the road by 50 m, told repeatedly']),
                ('LOGFMT 2', ['RULE bend_moved ms=1 kind=bend Bend: moved along the road by 20 m',
                              'RULE bend_moved_repeated ms=2 kind=bend Bend: moved along the road by 30 m, '
                              'told repeatedly',
                              'RULE bend_moved_repeated ms=3 kind=bend Bend: moved along the road by 40 m, '
                              'told repeatedly',
                              'RULE bend_moved_repeated ms=4 kind=gentle Gentle bend: moved along the road by '
                              '50 m, told repeatedly'])):
            with self.subTest(name):
                log = android_drive(seconds=120, stand=0)
                log += [core('10-08', 18 * 3600 + 10 * (i + 1), 'F', t) for i, t in enumerate(texts)]
                if name == 'LOGFMT 2':
                    log = logfmt2(log)
                counts = analyse(('app.log', log)).trips[0].rule_counts()
                self.assertEqual(counts['bend moved']['fired'], 1)
                self.assertEqual(counts['bend moved, repeated']['fired'], 3)

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
                                      no_taps=False, no_route=False, change=15)
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
