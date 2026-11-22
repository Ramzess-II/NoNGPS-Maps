#!/usr/bin/env python3
"""Tests of nogps_imu_speed.py on made-up drives.

  python3 tools/python/nogps_imu_speed_test.py
"""

import math
import os
import sys
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_imu_speed as m  # noqa: E402

DT = m.SLICE_MS / 1000
# The leak of gravity into the horizontal axes of the box: a mount not quite level.
LEAK = (0.3, -0.5)
FORWARD = (0.6, 0.8)


class Drive:
    """Acceleration and gyro slices of a made-up drive; the car moves along FORWARD in the axes of the box."""

    def __init__(self):
        self.acc = []
        self.gyro = []
        self.t = 0
        self.speed = 0.0

    def stand(self, seconds):
        for _ in range(round(seconds / DT)):
            self.t += m.SLICE_MS
            self.acc.append((self.t, LEAK[0], LEAK[1], True))
            self.gyro.append((self.t, 0.0, 0.0))

    def drive(self, seconds, along=0.0, yaw_dps=0.0, error=0.0):
        """|along|: m/s2 forward, |yaw_dps|: right turn plus, |error|: m/s2 forward the sensor adds."""
        for _ in range(round(seconds / DT)):
            self.t += m.SLICE_MS
            self.speed += along * DT
            # Centripetal: a = w up x v, w about up is minus for a right turn, up x f = (-f2, f1).
            w = -math.radians(yaw_dps)
            lateral = w * self.speed
            a1 = LEAK[0] + (along + error) * FORWARD[0] - lateral * FORWARD[1]
            a2 = LEAK[1] + (along + error) * FORWARD[1] + lateral * FORWARD[0]
            self.acc.append((self.t, a1, a2, False))
            self.gyro.append((self.t, yaw_dps, self.speed * 3.6))

    def estimate(self, forward=None, **options):
        stretch = m.stretches(self.acc)
        self.assert_one(stretch)
        return m.estimate(stretch[0], m.Series(self.gyro, 1), m.Series(self.gyro, 2), m.Options(**options), forward,
                          [0.0])

    @staticmethod
    def assert_one(stretches):
        assert len(stretches) == 1, len(stretches)


def ready_forward():
    forward = m.Forward()
    forward.learn(FORWARD[0] * 10, FORWARD[1] * 10, m.FORWARD_READY_S)
    return forward


class ImuSpeedTest(unittest.TestCase):
    def test_speed_from_the_stop_takes_off_the_leak(self):
        d = Drive()
        d.stand(3)
        d.drive(5, along=2)
        d.drive(10)
        d.drive(5, along=-2)
        speeds = d.estimate().speeds
        self.assertAlmostEqual(max(speeds), 10, delta=0.01)
        self.assertAlmostEqual(speeds[-1], 0, delta=0.01)

    def test_a_turn_keeps_the_speed(self):
        # Right and left: the velocity in the axes of the box must turn back by the yaw, or a turn changes the speed.
        for yaw in (20, -20):
            d = Drive()
            d.stand(3)
            d.drive(5, along=2)
            d.drive(9, yaw_dps=yaw)
            speeds = d.estimate(turns=False).speeds
            self.assertAlmostEqual(speeds[-1], 10, delta=0.05, msg=yaw)

    def test_a_turn_tells_the_speed(self):
        # The sensor adds 0.2 m/s2 on the way: 2 m/s too fast after 10 s; a turn of 90 degrees brings it back.
        d = Drive()
        d.stand(3)
        d.drive(5, along=2, error=0.2)
        d.drive(5, error=0.2)
        before = d.estimate(ready_forward()).speeds[-1]
        d.drive(4.5, yaw_dps=20, error=0.2)
        speeds = d.estimate(ready_forward()).speeds
        self.assertAlmostEqual(before, 12, delta=0.05)
        self.assertLess(abs(speeds[-1] - 10), 0.3)
        self.assertGreater(abs(d.estimate(ready_forward(), turns=False).speeds[-1] - 10), 2.5)

    def test_closure_spreads_the_speed_left_at_the_stop(self):
        d = Drive()
        d.stand(3)
        d.drive(5, along=2, error=0.1)
        d.drive(20, error=0.1)
        d.drive(5, along=-2, error=0.1)
        stretch = m.stretches(d.acc)[0]
        found = d.estimate(ready_forward())
        left, first, last, seconds = m.close(stretch, found)
        # 30 s of driving, and the last second at the stop, when the OBD speed was still 0.
        self.assertAlmostEqual(left, 0.1 * 30, delta=0.01)
        self.assertAlmostEqual(seconds, 31, delta=0.01)
        self.assertEqual(last, len(stretch) - 1)

    def test_a_segment_after_a_fast_road_is_a_city_one(self):
        d = Drive()
        d.stand(3)
        d.drive(12.5, along=2)
        d.drive(30)
        d.drive(8.5, along=-2)
        d.drive(4.5, yaw_dps=20)
        d.drive(30)
        d.drive(4, along=-2)
        trip = SimpleNamespace(id=0, start=0, end=d.t)
        stretches, segments = m.compare(trip, d.acc, d.gyro, m.Options(lag_s=0), ready_forward(), [0.0])
        self.assertEqual(len(stretches), 1)
        self.assertTrue(stretches[0]['fast'])
        self.assertEqual([s['fast'] for s in segments], [True, False])
        self.assertAlmostEqual(segments[1]['obd_m'], 8 * 30 + 16, delta=5)

    def test_read_sensors_skips_cut_and_bad_words(self):
        lines = [
            'I(1) 10.0 nogps/esp32_source.cpp:1 OnData(): ACCB_BEFORE 1 0.10,0.20,0.00,0.1 0.10,0.20,0.00,0.1',
            'I(1) 10.0 nogps/esp32_source.cpp:1 OnData(): ACCB 1.00,2.00,0.00,0.1 1.10 1.20,2.20,0.00,0.1',
            'I(1) 10.0 nogps/inertial_navigator.cpp:1 OnMotion(): GYRO 5.0 0.20 - 0.40 0.60 0.80 10 20 30 40 50',
        ]
        group = SimpleNamespace(lines=[(10_000, 'I', line) for line in lines])
        acc, gyro = m.read_sensors(group)
        self.assertEqual(acc, [(8_200, 0.1, 0.2, True), (8_400, 0.1, 0.2, True), (9_200, 1.0, 2.0, False),
                               (9_600, 1.2, 2.2, False)])
        # The yaw of each slice goes with the OBD speed of the same slice, also after a word that is not a number.
        self.assertEqual([(t, round(w, 2), kmh) for t, w, kmh in gyro],
                         [(9_200, 1.0, 10), (9_600, 2.0, 30), (9_800, 3.0, 40), (10_000, 4.0, 50)])

    def test_read_sensors_reads_the_tagged_lines_of_logfmt_2(self):
        def group(head):
            lines = ['I(1) 10.0 nogps/esp32_source.cpp:1 OnData(): ACCB %s1.00,2.00,0.00,0.1 1.20,2.20,0.00,0.1'
                     % head,
                     'I(1) 10.0 nogps/inertial_navigator.cpp:1 OnMotion(): GYRO %s5.0 0.20 0.40 0.60 0.80 1.00 '
                     '10 20 30 40 50' % head]
            return SimpleNamespace(lines=[(10_000, 'I', line) for line in lines])

        plain = m.read_sensors(group(''))
        self.assertEqual(len(plain[0]), 2)
        self.assertEqual(len(plain[1]), m.SLICES)
        self.assertEqual(m.read_sensors(group('ms=1763800000000 ')), plain)


if __name__ == '__main__':
    unittest.main()
