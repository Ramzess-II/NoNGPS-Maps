#!/usr/bin/env python3
"""Tests of nogps_logs.py fetch: the copy of an app folder into the tree, the flags, the import of the days that
changed. The phones are replaced by --from: a folder of logs/ and flags/ as the app keeps them.

  python3 tools/python/nogps_logs_test.py
"""

import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_db  # noqa: E402
import nogps_logs  # noqa: E402
from nogps_db_test import GOOD, header, utc_ms, write, write_flag  # noqa: E402

PHONE = 'Pixel_7-a3f9'
# Every pair of numbers, as nogps_db.NUMBER_PAIR finds a coordinate.
COORDINATE = re.compile(r'-?\d+\.\d+\s*,\s*-?\d+\.\d+')


class FetchTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.app = os.path.join(self.dir.name, 'app')
        self.tree = os.path.join(self.dir.name, 'trip-logs')

    def app_log(self, day, name, lines):
        return write(os.path.join(self.app, 'logs', PHONE, day), name, lines)

    def fetch(self):
        out = io.StringIO()
        with mock.patch.object(sys, 'argv', ['nogps_logs.py', 'fetch', '--to', self.tree, '--from', self.app]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            nogps_logs.main()
        return out.getvalue()

    def tree_file(self, *parts):
        return os.path.join(self.tree, PHONE, *parts)

    def databases(self):
        folder = os.path.join(self.tree, 'db')
        return {name: os.path.getmtime(os.path.join(folder, name)) for name in os.listdir(folder)}

    def test_into_an_empty_tree_and_again(self):
        self.app_log('2026-11-23', '180000.log', [header(utc_ms('2026-11-23 16:00:00'))] + GOOD[1:])
        first = self.app_log('2026-11-24', '180000.log', [header(utc_ms('2026-11-24 16:00:00'))] + GOOD[1:5])
        # The names of the earlier versions and a log without LOGFMT are not taken.
        write(os.path.join(self.app, 'logs'), 'log-24-11-26-%s.log' % PHONE, GOOD)
        write(os.path.join(self.app, 'logs', PHONE, '2026-11-24'), '190000.log', ['I(1) 0.1 OSLog text'])
        flags = os.path.join(self.app, 'flags')
        write_flag(flags, '20261124-180130', dict(n=1, lat=10.5, lon=20.5, voice_s=3, sent=False), m4a=b'v' * 10)

        out = self.fetch()
        self.assertIn('2 new logs, 3 new flag files, 1 logs of the earlier names skipped, 1 OSLog texts without LOGFMT '
                      'skipped', out)
        self.assertIn('%s 2026-11-23: imported' % PHONE, out)
        self.assertIn('%s 2026-11-24: imported' % PHONE, out)
        self.assertNotRegex(out, COORDINATE)
        self.assertTrue(os.path.isfile(self.tree_file('2026-11-24', 'flags', '20261124-180130.m4a')))
        self.assertFalse(os.path.exists(self.tree_file('2026-11-24', '190000.log')))
        conn = nogps_db.open_db(os.path.join(self.tree, 'db', '%s-2026-11-24.sqlite' % PHONE))
        self.assertEqual([tuple(r) for r in conn.execute('SELECT name, ms, voice_s FROM flag')],
                         [('20261124-180130', utc_ms('2026-11-24 16:01:30'), 3)])
        conn.close()

        # Nothing new: nothing is copied or imported again.
        before = self.databases()
        self.assertEqual(self.fetch().split('\n')[0].split(': ', 1)[1],
                         '1 logs of the earlier names skipped, 1 OSLog texts without LOGFMT skipped')
        self.assertEqual(self.databases(), before)

        # The last log grew, a log is new, the flag was sent and its voice note is longer; the phone forgot the day
        # before. Only the day that changed is imported again, and nothing of the tree is deleted.
        write(os.path.dirname(first), '180000.log', [header(utc_ms('2026-11-24 16:00:00'))] + GOOD[1:])
        self.app_log('2026-11-24', '200000.log', [header(utc_ms('2026-11-24 18:00:00'), '200000')] + GOOD[1:])
        os.remove(os.path.join(self.app, 'logs', PHONE, '2026-11-23', '180000.log'))
        write_flag(flags, '20261124-180130', dict(n=1, lat=10.5, lon=20.5, voice_s=5, sent=True), png=False,
                   m4a=b'v' * 20)
        out = self.fetch()
        self.assertIn('1 new logs, 1 grown logs, 2 changed flag files, 1 logs of the earlier names skipped', out)
        self.assertNotIn('2026-11-23: imported', out)
        self.assertNotRegex(out, COORDINATE)
        after = self.databases()
        self.assertEqual(after['%s-2026-11-23.sqlite' % PHONE], before['%s-2026-11-23.sqlite' % PHONE])
        self.assertTrue(os.path.isfile(self.tree_file('2026-11-23', '180000.log')))
        with open(self.tree_file('2026-11-24', 'flags', '20261124-180130.json')) as f:
            self.assertTrue(json.load(f)['sent'])
        self.assertEqual(os.path.getsize(self.tree_file('2026-11-24', 'flags', '20261124-180130.m4a')), 20)
        conn = nogps_db.open_db(os.path.join(self.tree, 'db', '%s-2026-11-24.sqlite' % PHONE))
        self.assertEqual(conn.execute('SELECT COUNT(*) FROM file').fetchone()[0], 2)
        self.assertEqual([tuple(r) for r in conn.execute('SELECT voice_s, sent FROM flag')], [(5, 1)])
        conn.close()

    def test_a_smaller_copy_on_the_phone_is_not_taken(self):
        self.app_log('2026-11-24', '180000.log', [header(utc_ms('2026-11-24 16:00:00'))] + GOOD[1:5])
        os.makedirs(self.tree_file('2026-11-24'))
        with open(self.tree_file('2026-11-24', '180000.log'), 'w') as f:
            f.write('\n'.join([header(utc_ms('2026-11-24 16:00:00'))] + GOOD[1:]) + '\n')
        self.assertIn('nothing new', self.fetch())

    def test_a_flag_of_a_day_without_logs_takes_the_phone_of_the_app(self):
        self.app_log('2026-11-24', '180000.log', [header(utc_ms('2026-11-24 16:00:00'))] + GOOD[1:])
        write_flag(os.path.join(self.app, 'flags'), '20261120-100000', dict(n=1, voice_s=0, sent=False))
        out = self.fetch()
        self.assertTrue(os.path.isfile(self.tree_file('2026-11-20', 'flags', '20261120-100000.json')))
        self.assertIn('%s 2026-11-20: no logs, not imported' % PHONE, out)

    def test_a_flag_whose_phone_is_unknown_is_skipped(self):
        write_flag(os.path.join(self.app, 'flags'), '20261120-100000', dict(n=1, voice_s=0, sent=False))
        out = self.fetch()
        self.assertIn('flags/20261120-100000.json: no log of its day tells its phone, skipped', out)
        self.assertFalse(os.path.exists(self.tree))


    def test_a_phone_id_that_is_no_folder_name_is_skipped(self):
        self.app_log('2026-11-24', '180000.log', [header(utc_ms('2026-11-24 16:00:00'), phone='..')] + GOOD[1:])
        out = self.fetch()
        self.assertIn("the phone id '..' is no folder name, skipped", out)
        self.assertEqual(os.listdir(self.dir.name), ['app'])


class DevicesTest(unittest.TestCase):
    def test_without_the_tools_of_the_platforms(self):
        notes = []
        with mock.patch.object(nogps_logs.shutil, 'which', lambda name: None):
            self.assertEqual(nogps_logs.ios_containers(None, '.', notes), [])
            self.assertEqual(nogps_logs.android_containers(None, '.', notes), [])
        self.assertEqual(notes, ['no xcrun: iOS skipped, it is fetched on macOS', 'no adb: Android skipped'])

    def test_devicectl_without_its_result_is_a_note(self):
        def run(command, timeout=0):
            with open(command[-1], 'w') as f:
                f.write('{"info": {}}')
            return 0, '', ''
        notes = []
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.object(nogps_logs.shutil, 'which', lambda name: '/bin/' + name), \
                mock.patch.object(nogps_logs, 'run', run):
            self.assertEqual(nogps_logs.ios_containers(None, folder, notes), [])
        self.assertEqual(notes, ["list devices: devicectl gave no devices: KeyError('result')"])

    def test_a_wireless_serial_makes_a_folder(self):
        self.assertEqual(nogps_logs.folder_name('192.168.1.5:5555-ua.nogps.maps'), '192.168.1.5_5555-ua.nogps.maps')

    def test_android_refusing_its_data_folder_is_told(self):
        answers = {('adb', 'devices'): 'List of devices attached\nR58\tdevice\nX1\tunauthorized\n',
                   ('adb', '-s', 'R58', 'shell', 'pm', 'list', 'packages', 'ua.nogps'): 'package:ua.nogps.maps\n',
                   ('adb', '-s', 'R58', 'shell', 'ls', '/sdcard/Android/data/ua.nogps.maps/files'):
                       'ls: /sdcard/Android/data/ua.nogps.maps/files: Permission denied\n'}
        notes = []
        with mock.patch.object(nogps_logs.shutil, 'which', lambda name: '/bin/' + name), \
                mock.patch.object(nogps_logs, 'run', lambda command, timeout=0: (0, answers[tuple(command)], '')):
            self.assertEqual(nogps_logs.android_containers(None, '.', notes), [])
        self.assertEqual(notes, ['X1: adb sees it as unauthorized',
                                 'R58 ua.nogps.maps: the phone refuses access to Android/data, nothing fetched'])


if __name__ == '__main__':
    unittest.main()
