#!/usr/bin/env python3
"""Tests of nogps_db.py and nogps_logs.py: the import maps every table, and a line it cannot map fails it."""

import contextlib
import io
import os
import sqlite3
import tempfile
import unittest

import nogps_db
import nogps_logs
import nogps_trip_log

T0 = 1763800000000
HEADER = ('LOGFMT 2 ms=%d phone=Pixel_7-a3f9 trip=180000 app=2026.11.22-3-Google build=26112203 commit=abcdef12 '
          'om=2026.10.27-10' % T0)


def core(func, body, ms=0):
    return '11-22 18:00:00.000 (main) I/OMcore: nogps/engine.cpp:1 %s(): %s' % (func, body)


def trip(ms, **extra):
    fields = ('src=INERTIAL pos=10.000100,20.000000 acc=10 bear=0 age=0.0 gps=10.000000,20.000000/5.0/36.0/0.0/0.50/3.0 '
              'fused=10.000000,20.000000/6.0/-/-/0.10/- cmp=90/5/0.20 gpsAge=0.5 fill=4 spoofed=0 gpsst=GOOD '
              'net=10.00000,20.00000 acc=50 age=2.0 nav=0 obd=CONNECTED speed=36 sage=200 link=BLE/CONNECTED '
              'box=5/220 bf=1F fw=1.2 scale=1.040 table=3 factor=1.000 rough=0 lag=0.30/DEFAULT boxacc=0.90/+1.0 '
              'phoneacc=0.50/- gyro=DONE turn=NaN hdg=0/GPS road=1 lost=0 back=0 turning=0 odo=5 offm=0 offv=0 '
              'cand=- snap=1.0 rdiff=- snapwhy=ROAD wait=- fix=0 ready=1 ring=0')
    for k, v in extra.items():
        fields += ' %s=%s' % (k, v)
    return core('LogTrip', 'TRIP ms=%d %s' % (ms, fields))


GOOD = [
    HEADER,
    core('Start', 'ACTION start ms=%d Start' % (T0 + 100)),
    core('LogCalibration', 'CALIBRATION ms=%d car=C47D scale=1.04 table=1:2:3' % (T0 + 200)),
    core('LogMapsVersion', 'MAPS ms=%d version=261101,260714' % (T0 + 300)),
    trip(T0 + 1000),
    trip(T0 + 2000),
    core('SetGpsDisabled', 'ACTION gps_off ms=%d disabled=1 by=user GPS ignored by the user = 1' % (T0 + 2100)),
    core('PutMark', 'ACTION tap ms=%d by=user tap = ms::LatLon(10.0, 20.0) location = ms::LatLon(10.1, 20.1) '
         'bearing = 45 heading was = 40' % (T0 + 2200)),
    core('X', 'RULE road_lost ms=%d m=42 jump=0 The road is lost after 120 m' % (T0 + 2300)),
    core('X', 'EVENT gps_spoofed ms=%d spoofed=1 GPS spoofed = 1' % (T0 + 2400)),
    core('OnData', 'ACCB ms=%d ' % (T0 + 2500) + ' '.join(['0.10,0.00,9.80,0.5'] * 5)),
    core('OnData', 'ACCB_BEFORE ms=%d 2 ' % (T0 + 2500) + ' '.join(['0.10,0.00,9.80,0.5'] * 5)),
    core('OnMotion', 'GYRO ms=%d 12.5 0.1 0.2 0.3 0.4 0.5 10 11 12 13 14' % (T0 + 2600)),
    core('X', 'BOXACC ms=%d dir=- n=0 corr=0.00' % (T0 + 2700)),
    '11-22 18:00:01.000 (main) I/OrganicMaps: Foo.java:1 bar(): an ordinary line',
    trip(T0 + 1000_000),
]


# A second run of the engine in one file: the application went to the background and came back 10 minutes later.
RESTARTED = [
    HEADER,
    core('Start', 'ACTION start ms=%d Start' % (T0 + 100)),
    trip(T0 + 110),
    trip(T0 + 1110),
    core('Stop', 'ACTION stop ms=%d Stop' % (T0 + 1200)),
    core('Start', 'ACTION start ms=%d Start' % (T0 + 600_000)),
    core('LogMapsVersion', 'MAPS ms=%d version=261101,260714' % (T0 + 600_001)),
    core('LogCalibration', 'CALIBRATION ms=%d car=C47D scale=1.04' % (T0 + 600_001)),
    core('RestoreCarPosition', 'ACTION restore_car ms=%d The car is where it was left = ms::LatLon(10.0, 20.0)'
         % (T0 + 600_002)),
    core('SetGpsDisabled', 'ACTION gps_off ms=%d disabled=1 by=restore GPS ignored = 1' % (T0 + 600_002)),
    core('LogStateChanges', 'EVENT position_source ms=%d Position source = INERTIAL' % (T0 + 600_004)),
    trip(T0 + 600_005),
    trip(T0 + 601_005),
]


# The lines of the core that carry a tag and a name but no keys: their sentence is the data (#563).
PROSE = [
    ('OnBleState', 'ACTION ble_state', 'Bluetooth = CONNECTED'),
    ('operator()', 'ACTION route', 'Route state = RouteBuilding was NoValidRoute'),
    ('operator()', 'ACTION route_follow', 'Route state = OnRoute was RouteNotStarted'),
    ('OnInfo', 'ACTION box_info', 'Box C47D firmware = 1.2 ESP32 S3 rev 1 updates = 1'),
    ('RestoreTrustedPosition', 'EVENT last_trusted', 'Last trusted position = 10.000000,20.000000,%d' % T0),
    ('OnLine', 'EVENT obd_state', 'OBD state = NO_ADAPTER'),
    ('OnEvent', 'EVENT box_event', 'Box event # 4 at 11 ms: MOUNT_MOVED the mount moved'),
    ('LearnRoughSpeed', 'EVENT speed_factor',
     'Speed factor: the turn tells the calculated distance is 5 m off in 100 m, factor = 1.02'),
    ('LearnRoughSpeed', 'EVENT speed_rough_table',
     'Rough speed table: the turn tells the calculated distance is 5 m off in 100 m, table = 1:2:3'),
    ('LogSpeedCalibration', 'EVENT speed_table',
     'Speed table = 1:2:3 factor = 1.0 unit = KMH lag = 0.3 measured = 1 scale = 1.04 rough = 1:2:3'),
    ('ClearSpeedCalibration', 'EVENT speed_table_cleared', 'Speed table was 1:2:3 factor 1.0 rough 1:2:3 unit KMH'),
]


def write(folder, name, lines):
    path = os.path.join(folder, *name.split('/'))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    return path


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.logs = os.path.join(self.dir.name, 'logs')
        self.out = os.path.join(self.dir.name, 'db')

    def run_import(self, lines, name='Pixel_7-a3f9/2026-11-22/180000.log'):
        write(self.logs, name, lines)
        return nogps_db.import_tree([self.logs], self.out)

    def db(self):
        return nogps_db.open_db(os.path.join(self.out, 'Pixel_7-a3f9-2026-11-22.sqlite'))

    def fails(self, lines, text):
        with self.assertRaises(nogps_db.ImportError_) as e:
            self.run_import(lines)
        self.assertIn(text, str(e.exception))
        self.assertFalse(os.path.exists(os.path.join(self.out, 'Pixel_7-a3f9-2026-11-22.sqlite')))

    def test_speed_limit_key(self):
        self.run_import([HEADER, trip(T0 + 1000, lim=50), trip(T0 + 2000, lim='-')])
        rows = self.db().execute('SELECT limit_kmh FROM sample ORDER BY ms').fetchall()
        self.assertEqual([r['limit_kmh'] for r in rows], [50, None])

    def test_tables(self):
        self.run_import(GOOD)
        conn = self.db()
        f = conn.execute('SELECT * FROM file').fetchone()
        self.assertEqual((f['phone'], f['day'], f['logfmt'], f['trip_name'], f['build'], f['build_commit'],
                          f['om_version'], f['map_version']),
                         ('Pixel_7-a3f9', '2026-11-22', 2, '180000', '26112203', 'abcdef12', '2026.10.27-10',
                          '261101,260714'))
        trips = conn.execute('SELECT * FROM trip ORDER BY id').fetchall()
        # Two TRIP lines a second apart, then one 1000 s later: two trips, 1 s moving in the first.
        self.assertEqual([(t['started_ms'], t['ended_ms'], t['moving_s']) for t in trips],
                         [(T0 + 1000, T0 + 2000, 1.0), (T0 + 1000_000, T0 + 1000_000, 0.0)])
        self.assertIsNone(trips[0]['in_check_set'])
        s = conn.execute('SELECT * FROM sample WHERE trip_id = ? ORDER BY ms', (trips[0]['id'],)).fetchall()
        self.assertEqual(len(s), 2)
        self.assertEqual((s[0]['src'], s[0]['lat'], s[0]['acc_m'], s[0]['gps_age_s'], s[0]['box_flags'],
                          s[0]['lag'], s[0]['lag_default'], s[0]['boxacc_ahead_m'], s[0]['phoneacc_ahead_m'],
                          s[0]['turn_m'], s[0]['hdg'], s[0]['hdg_src'], s[0]['cmp_deg']),
                         ('INERTIAL', 10.0001, 10.0, 0.5, 0x1F, 0.3, 1, 1.0, None, None, 0.0, 'GPS', 90.0))
        fixes = {r['kind']: r for r in conn.execute('SELECT * FROM fix WHERE ms = ?', (T0 + 1000,))}
        self.assertEqual(set(fixes), {'gps', 'fused', 'net'})
        self.assertEqual((fixes['gps']['acc_m'], fixes['gps']['kmh'], fixes['gps']['bearing'],
                          fixes['gps']['bearing_acc_deg'], fixes['gps']['age_s']), (5.0, 36.0, 0.0, 3.0, 0.5))
        self.assertEqual((fixes['fused']['kmh'], fixes['fused']['bearing_acc_deg']), (None, None))
        self.assertEqual((fixes['net']['acc_m'], fixes['net']['age_s']), (50.0, 2.0))
        sensor = conn.execute('SELECT kind, slice, ms, v1, v2, v3, v4 FROM sensor ORDER BY kind, ms, slice').fetchall()
        self.assertEqual(len(sensor), 15)
        self.assertEqual(tuple(sensor[0]), ('accb', 0, T0 + 500, 0.1, 0.0, 9.8, 0.5))  # ACCB_BEFORE 2 s earlier
        gyro = [r for r in sensor if r['kind'] == 'gyro']
        self.assertEqual([tuple(r)[1:] for r in gyro][3], (3, T0 + 2600, 0.4, 13.0, 12.5, None))
        c = conn.execute('SELECT * FROM calibration').fetchone()
        self.assertEqual((c['car'], c['scale'], c['tbl'], c['rough']), ('C47D', 1.04, '1:2:3', None))
        self.assertEqual([(r['kind'], r['ms']) for r in conn.execute('SELECT * FROM action ORDER BY ms')],
                         [('start', T0 + 100), ('gps_off', T0 + 2100), ('tap', T0 + 2200)])
        gps_off = conn.execute("SELECT * FROM action WHERE kind = 'gps_off'").fetchone()
        self.assertEqual(gps_off['payload'], '{"by": "user", "disabled": "1"}')
        tap = conn.execute("SELECT payload FROM action WHERE kind = 'tap'").fetchone()[0]
        self.assertIn('"bearing": "45"', tap)
        rule = conn.execute('SELECT * FROM rule').fetchone()
        self.assertEqual((rule['name'], rule['payload'], rule['text']),
                         ('road_lost', '{"jump": "0", "m": "42"}', 'The road is lost after 120 m'))
        self.assertEqual(conn.execute('SELECT name FROM event').fetchone()[0], 'gps_spoofed')
        self.assertEqual(sorted(r[0] for r in conn.execute('SELECT tag FROM note')), ['BOXACC', 'MAPS'])
        # The lines before the first TRIP and in the pause belong to the first trip and the line after it.
        self.assertEqual({r[0] for r in conn.execute('SELECT trip_id FROM action')}, {trips[0]['id']})

    def test_lines_of_a_second_start_belong_to_its_trip(self):
        """The lines Engine::Start writes a few ms before the first TRIP line of its run belong to that trip."""
        self.run_import(RESTARTED)
        conn = self.db()
        trips = conn.execute('SELECT * FROM trip ORDER BY id').fetchall()
        self.assertEqual([(t['started_ms'], t['ended_ms']) for t in trips],
                         [(T0 + 110, T0 + 1110), (T0 + 600_005, T0 + 601_005)])
        first, second = trips[0]['id'], trips[1]['id']
        self.assertEqual([(r['kind'], r['trip_id']) for r in conn.execute('SELECT * FROM action ORDER BY ms')],
                         [('start', first), ('stop', first), ('start', second), ('restore_car', second),
                          ('gps_off', second)])
        self.assertEqual(conn.execute('SELECT trip_id FROM calibration').fetchone()[0], second)
        self.assertEqual(conn.execute('SELECT trip_id FROM event').fetchone()[0], second)
        self.assertEqual(conn.execute("SELECT trip_id FROM note WHERE tag = 'MAPS'").fetchone()[0], second)

    def test_prose_lines_of_the_core(self):
        """The lines the core tags with a name but writes as a sentence: every name has a table (#563)."""
        self.run_import([HEADER] + [core(func, '%s ms=%d %s' % (head, T0 + 100 + i, rest)) for i, (func, head, rest)
                                    in enumerate(PROSE)])
        conn = self.db()
        self.assertEqual([r[0] for r in conn.execute('SELECT kind FROM action ORDER BY ms')],
                         ['ble_state', 'route', 'route_follow', 'box_info'])
        self.assertEqual([r[0] for r in conn.execute('SELECT name FROM event ORDER BY ms')],
                         ['last_trusted', 'obd_state', 'box_event', 'speed_factor', 'speed_rough_table',
                          'speed_table', 'speed_table_cleared'])
        self.assertEqual(conn.execute("SELECT text FROM action WHERE kind = 'ble_state'").fetchone()[0],
                         'Bluetooth = CONNECTED')

    def test_reimport_replaces(self):
        self.run_import(GOOD)
        self.run_import(GOOD[:2])
        self.assertEqual(self.db().execute('SELECT COUNT(*) FROM sample').fetchone()[0], 0)

    def test_failed_import_keeps_the_database(self):
        self.run_import(GOOD)
        with self.assertRaises(nogps_db.ImportError_):
            self.run_import(GOOD + [core('X', 'RULE reworded ms=%d hi' % T0)])
        self.assertEqual(self.db().execute('SELECT COUNT(*) FROM sample').fetchone()[0], 3)

    def test_unmapped_lines_fail(self):
        """A reworded or new machine line is an error, as it was a silent miss for the sentence parsers (#463)."""
        for line, text in [
            (core('X', 'RULE reworded ms=%d hi' % T0), 'unknown rule name reworded'),
            (core('X', 'ACTION gps_off ms=%d disabled=1 GPS ignored' % T0), 'needs disabled= and by='),
            (core('X', 'EVENT nothing ms=%d x' % T0), 'unknown event name'),
            (core('X', 'NEWTAG ms=%d x' % T0), 'unknown tag NEWTAG'),
            (core('X', 'ACTION tap ms=%d by=user tap = nowhere' % T0), 'tap has no positions'),
            (core('X', 'GYRO ms=%d 1 2 3' % T0), 'GYRO has 3 values'),
            (core('X', 'ACCB ms=%d 1,2,3,4' % T0), 'ACCB has 1 slices'),
            (core('X', 'CALIBRATION ms=%d car=A mystery=1' % T0), 'CALIBRATION with keys'),
            (core('X', 'MAPS ms=%d none' % T0), 'MAPS has no version='),
            (trip(T0, newkey=1), 'unknown key newkey'),
            (trip(T0, nav=2), 'not 0 or 1'),
        ]:
            with self.subTest(text):
                self.fails(GOOD[:1] + [line], text)

    def test_line_number_in_error(self):
        with self.assertRaises(nogps_db.ImportError_) as e:
            self.run_import([HEADER, 'ordinary', core('X', 'NEWTAG ms=1 x')])
        self.assertIn('180000.log:3:', str(e.exception))

    def test_error_has_no_coordinate(self):
        """The quoted line is printed (nogps_logs.py) and must have no position in it."""
        for line in [trip(T0, newkey=1),
                     core('X', 'ACTION tap ms=%d by=user tap = ms::LatLon(10.0, 20.0) nowhere' % T0)]:
            with self.subTest(line[:60]):
                with self.assertRaises(nogps_db.ImportError_) as e:
                    self.run_import([HEADER, line])
                message = str(e.exception)
                self.assertNotIn('10.0', message)
                self.assertNotIn('20.0', message)
                self.assertIn('<pos>', message)

    def test_unknown_logfmt(self):
        with self.assertRaises(nogps_trip_log.LogFormatError):
            self.run_import([HEADER.replace('LOGFMT 2', 'LOGFMT 9')] + GOOD[1:])

    def test_file_without_logfmt(self):
        with self.assertRaises((nogps_db.ImportError_, nogps_db.nogps_trip_log.LogFormatError)) as e:
            nogps_db.import_day([('a.log', b'I(1) 0.5 plain OSLog text\n')], os.path.join(self.out, 'x.sqlite'),
                                'Pixel_7-a3f9', '2026-11-22')
        self.assertIn('LOGFMT', str(e.exception))

    def test_tree_skips_file_without_logfmt(self):
        write(self.logs, 'Pixel_7-a3f9/2026-11-22/180000.log', GOOD)
        write(self.logs, 'Pixel_7-a3f9/2026-11-22/190000.log', ['I(1) 0.5 plain OSLog text'])
        write(self.logs, 'Pixel_7-a3f9/2026-11-23/000000.log', GOOD)
        got = nogps_db.import_tree([self.logs], self.out)
        self.assertEqual(sorted(os.path.basename(p) for p, _ in got),
                         ['Pixel_7-a3f9-2026-11-22.sqlite', 'Pixel_7-a3f9-2026-11-23.sqlite'])

    def test_file_with_no_trip(self):
        self.run_import(GOOD[:3])
        conn = self.db()
        t = conn.execute('SELECT * FROM trip').fetchone()
        self.assertEqual((t['started_ms'], t['ended_ms'], t['moving_s']), (T0 + 100, T0 + 200, 0.0))

    def test_phones_and_days_make_databases(self):
        write(self.logs, 'Pixel_7-a3f9/2026-11-22/180000.log', GOOD)
        write(self.logs, 'Pixel_7-a3f9/2026-11-23/000000.log', GOOD)
        write(self.logs, 'iPhone-1111/2026-11-22/100000.log', [HEADER.replace('Pixel_7-a3f9', 'iPhone-1111')])
        got = nogps_db.import_tree([self.logs], self.out)
        self.assertEqual(sorted(os.path.basename(p) for p, _ in got),
                         ['Pixel_7-a3f9-2026-11-22.sqlite', 'Pixel_7-a3f9-2026-11-23.sqlite',
                          'iPhone-1111-2026-11-22.sqlite'])

    def test_old_schema_refused(self):
        self.run_import(GOOD)
        path = os.path.join(self.out, 'Pixel_7-a3f9-2026-11-22.sqlite')
        conn = sqlite3.connect(path)
        conn.execute("UPDATE meta SET value = '0'")
        conn.commit()
        conn.close()
        with self.assertRaisesRegex(nogps_db.ImportError_, 'import the logs again'):
            nogps_db.open_db(path)

    def test_command_line(self):
        write(self.logs, 'Pixel_7-a3f9/2026-11-22/180000.log', GOOD)
        import sys
        old = sys.argv
        sys.argv = ['nogps_logs.py', 'import', self.logs, '-o', self.out]
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                nogps_logs.main()
            self.assertIn('1 databases', out.getvalue())
            sys.argv = ['nogps_logs.py', 'summary', os.path.join(self.out, 'Pixel_7-a3f9-2026-11-22.sqlite')]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                nogps_logs.main()
            self.assertIn('sample 3', out.getvalue())
        finally:
            sys.argv = old


def utc_ms(text):
    """The unix ms of 'yyyy-MM-dd HH:mm:ss' UTC."""
    return int(nogps_db.datetime.strptime(text, '%Y-%m-%d %H:%M:%S').replace(
        tzinfo=nogps_db.timezone.utc).timestamp() * 1000)


def header(ms, trip='180000', phone='Pixel_7-a3f9'):
    return HEADER.replace('ms=%d' % T0, 'ms=%d' % ms).replace('trip=180000', 'trip=' + trip).replace(
        'Pixel_7-a3f9', phone)


def write_flag(folder, name, values, png=True, m4a=b''):
    import json
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, name + '.json'), 'w') as f:
        json.dump(values, f)
    if png:
        with open(os.path.join(folder, name + '.png'), 'wb') as f:
            f.write(b'\x89PNG')
    if m4a:
        with open(os.path.join(folder, name + '.m4a'), 'wb') as f:
            f.write(m4a)


class OffsetTest(unittest.TestCase):
    # The phone is 2 h ahead of UTC: a file named 180000 was started at 16:00:00 UTC.
    DAY = '2026-11-24'

    def test_median_rounded_to_a_quarter(self):
        starts = [('180000.log', utc_ms('2026-11-24 16:00:01')), ('190500.log', utc_ms('2026-11-24 17:04:58')),
                  ('190500-2.log', utc_ms('2026-11-24 17:05:03'))]
        self.assertEqual(nogps_db.utc_offset_ms(self.DAY, starts), 2 * 3600_000)

    def test_continuation_after_midnight_does_not_move_it(self):
        # The trip started at 23:30 the day before goes on in this day's folder under its name, from 00:00 local.
        starts = [('233000.log', utc_ms('2026-11-23 22:00:00')), ('180000.log', utc_ms('2026-11-24 16:00:00'))]
        self.assertEqual(nogps_db.utc_offset_ms(self.DAY, starts), 2 * 3600_000)
        self.assertIsNone(nogps_db.utc_offset_ms(self.DAY, starts[:1]))

    def test_a_day_without_logs(self):
        self.assertIsNone(nogps_db.utc_offset_ms(self.DAY, []))
        self.assertIsNone(nogps_db.utc_offset_ms(self.DAY, [('log.log', T0)]))


class FlagTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.day = os.path.join(self.dir.name, 'logs', 'Pixel_7-a3f9', '2026-11-24')
        self.out = os.path.join(self.dir.name, 'db')

    def flags(self):
        conn = nogps_db.open_db(os.path.join(self.out, 'Pixel_7-a3f9-2026-11-24.sqlite'))
        rows = [dict(r) for r in conn.execute('SELECT * FROM flag ORDER BY name')]
        conn.close()
        return rows

    def test_flags_of_the_day(self):
        write(self.day, '180000.log', [header(utc_ms('2026-11-24 16:00:00'))] + GOOD[1:])
        flags = os.path.join(self.day, 'flags')
        write_flag(flags, '20261124-180130', dict(n=2, lat=10.5, lon=20.5, voice_s=7, sent=True), m4a=b'voice')
        # No voice, and no position: the phone had none.
        write_flag(flags, '20261124-181000', dict(n=3, voice_s=0, sent=False), png=False)
        # A screenshot without its json is no flag.
        with open(os.path.join(flags, '20261124-182000.png'), 'wb') as f:
            f.write(b'\x89PNG')
        nogps_db.import_tree([os.path.join(self.dir.name, 'logs')], self.out)
        self.assertEqual(self.flags(), [
            dict(name='20261124-180130', ms=utc_ms('2026-11-24 16:01:30'), n=2, lat=10.5, lon=20.5, voice_s=7, sent=1,
                 png='flags/20261124-180130.png', m4a='flags/20261124-180130.m4a'),
            dict(name='20261124-181000', ms=utc_ms('2026-11-24 16:10:00'), n=3, lat=None, lon=None, voice_s=0, sent=0,
                 png=None, m4a=None)])

    def test_a_day_whose_logs_tell_no_offset(self):
        # The only log goes on from the day before: its name is no start of this day.
        write(self.day, '233000.log', [header(utc_ms('2026-11-23 22:00:00'), '233000')] + GOOD[1:])
        write_flag(os.path.join(self.day, 'flags'), '20261124-080000', dict(n=1, voice_s=0, sent=False))
        nogps_db.import_tree([os.path.join(self.dir.name, 'logs')], self.out)
        self.assertEqual([(f['name'], f['ms']) for f in self.flags()], [('20261124-080000', None)])

    def test_a_database_of_schema_1_is_refused(self):
        write(self.day, '180000.log', GOOD)
        nogps_db.import_tree([os.path.join(self.dir.name, 'logs')], self.out)
        path = os.path.join(self.out, 'Pixel_7-a3f9-2026-11-24.sqlite')
        conn = sqlite3.connect(path)
        conn.execute("UPDATE meta SET value = '1'")
        conn.commit()
        conn.close()
        with self.assertRaisesRegex(nogps_db.ImportError_, 'schema 1, the tools read 3'):
            nogps_db.open_db(path)


if __name__ == '__main__':
    unittest.main()
