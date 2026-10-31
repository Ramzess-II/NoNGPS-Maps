#!/usr/bin/env python3
"""Tests of nogps_log.py on made-up logs: the places are not real.

  python3 tools/python/nogps_log_test.py
"""

import io
import os
import sys
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_log  # noqa: E402
import nogps_replay  # noqa: E402

DEG_PER_M = 1 / 111320.0
START_LAT, START_LON = 10.0, 20.0
DAY_MS = nogps_log.to_ms(nogps_log.datetime(2026, 10, 8))


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
                  snapwhy='ROAD', fix='0', ready='1', ring='0')
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
        log = android_drive(seconds=30, stand=0) + [
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

    def test_not_a_log(self):
        analysis = nogps_log.Analysis([('notes.txt', b'hello')])
        self.assertEqual((analysis.trips, analysis.notes), ([], ['notes.txt: not a log of the app']))


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
        self.assertEqual([(s['kind'], s['start']) for s in stats['stretches']], [('worse', trip.start + 1000)])

    def test_error_stats(self):
        self.assertEqual(nogps_replay.error_stats([]), None)
        self.assertEqual(nogps_replay.error_stats([10, 40, 60, 120])['over50'], 50)


if __name__ == '__main__':
    unittest.main()
