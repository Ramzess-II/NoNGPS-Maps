#!/usr/bin/env python3
"""Tests of nogps_rating.py: the same cases as NoGps_SpeedingMeter_* in libs/map/map_tests/nogps_speeding_tests.cpp.

  python3 tools/python/nogps_rating_test.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_log  # noqa: E402
import nogps_rating  # noqa: E402


class Car:
    def __init__(self):
        self.meter = nogps_rating.Meter()
        self.t = 100000

    def drive(self, seconds, kmh, limit):
        for _ in range(seconds):
            self.t += 1000
            self.meter.sample(self.t, kmh, limit)

    def result(self):
        self.meter.flush()
        return self.meter.result()


class MeterTest(unittest.TestCase):
    def test_starts_after_three_seconds(self):
        car = Car()
        car.drive(5, 60, 60)
        for dt in (1000, 1000, 900):
            car.t += dt
            car.meter.sample(car.t, 85, 60)
        car.drive(10, 60, 60)
        self.assertEqual(car.result()['episodes'], [])

        car = Car()
        car.drive(5, 60, 60)
        car.drive(4, 85, 60)
        car.drive(10, 60, 60)
        episodes = car.result()['episodes']
        self.assertEqual(len(episodes), 1)
        self.assertEqual((episodes[0]['lim'], episodes[0]['peak'], episodes[0]['band']), (60, 85, 1))

    def test_tolerance_is_not_over(self):
        car = Car()
        car.drive(20, 80, 60)
        self.assertEqual(car.result()['episodes'], [])

    def test_hysteresis_keeps_the_episode(self):
        car = Car()
        car.drive(4, 90, 60)
        car.drive(5, 78, 60)
        car.drive(1, 60, 60)
        car.drive(4, 90, 60)
        car.drive(10, 60, 60)
        episodes = car.result()['episodes']
        self.assertEqual(len(episodes), 1)
        self.assertGreater(episodes[0]['dur'], 12)

    def test_merges_episodes_closer_than_five_seconds(self):
        for gap, count in ((4, 1), (6, 2)):
            car = Car()
            car.drive(5, 90, 60)
            car.drive(gap - 1, 60, 60)
            car.drive(5, 90, 60)
            car.drive(10, 60, 60)
            self.assertEqual(len(car.result()['episodes']), count, gap)

    def test_lower_limit_counts_after_150_m(self):
        car = Car()
        car.drive(5, 100, 100)
        car.drive(5, 100, 50)
        car.drive(10, 100, 100)
        self.assertEqual(car.result()['episodes'], [])

        car = Car()
        car.drive(5, 100, 100)
        car.drive(20, 100, 50)
        episodes = car.result()['episodes']
        self.assertEqual([e['lim'] for e in episodes], [50])

        car = Car()
        car.drive(5, 50, 50)
        car.drive(10, 90, 100)
        self.assertEqual(car.result()['episodes'], [])

    def test_unrated_ends_the_episode(self):
        for kmh, limit in ((90, 0), (90, None), (None, 60)):
            car = Car()
            car.drive(5, 90, 60)
            car.drive(3, kmh, limit)
            car.drive(10, 60, 60)
            result = car.result()
            self.assertEqual(len(result['episodes']), 1)
            self.assertAlmostEqual(result['episodes'][0]['dur'], 4.0, delta=1.01)
            self.assertAlmostEqual(result['rated_s'], 14.0, delta=1.01)

    def test_bands(self):
        self.assertEqual([nogps_rating.band_of(x) for x in (25, 39.9, 40, 59, 60)], [1, 1, 2, 2, 3])
        car = Car()
        car.drive(5, 100, 50)
        car.drive(5, 60, 50)
        car.drive(5, 130, 50)
        car.drive(10, 50, 50)
        result = car.result()
        self.assertEqual(result['bands'], [0, 1, 1])
        self.assertAlmostEqual(result['weighted_s'], 3 * result['episodes'][0]['dur'] + 8 * result['episodes'][1]['dur'])

    def test_score(self):
        self.assertEqual([nogps_rating.score_of(m * 60, 3600) for m in (0, 1, 5, 10)], [100, 85, 43, 19])

    def test_window_takes_the_newest_500_km(self):
        def trip(km, weighted):
            return dict(rated_km=km, rated_s=3600, weighted_s=weighted, bands=[0, 0, 0])
        trips = [trip(100, 1800)] + [trip(100, 0)] * 5
        w = nogps_rating.window(trips)
        self.assertEqual((w['rated_km'], w['score'], w['enough']), (500, 100, True))
        self.assertFalse(nogps_rating.window([trip(19, 0)])['enough'])
        self.assertTrue(nogps_rating.window([trip(20, 0)])['enough'])


class RowsTest(unittest.TestCase):
    def test_rows_with_lim_and_speed(self):
        rows = []
        t = 0
        for kmh, lim in [(50, '50')] * 5 + [(90, '50')] * 6 + [(50, '50')] * 8 + [(90, '-')] * 3:
            t += 1000
            rows.append(dict(t=t, speed=str(kmh), scale='1.000', lim=lim))
        result = nogps_rating.rate_rows(rows, nogps_log.num)
        self.assertEqual(result['bands'], [0, 1, 0])
        self.assertEqual(result['episodes'][0]['lim'], 50)

    def test_rows_lim_is_not_graced_again(self):
        rows = []
        t = 0
        # The core logs lim=100 for the grace, then lim=50, and starts its episode 3 s later.
        for kmh, lim in [(85, '100')] * 10 + [(85, '50')] * 6:
            t += 1000
            rows.append(dict(t=t, speed=str(kmh), scale='1.000', lim=lim))
        t += 1000
        rows.append(dict(t=t, speed='50', scale='1.000', lim='50'))
        for _ in range(3):
            t += 1000
            rows.append(dict(t=t, speed='50', scale='1.000', lim='50'))
        result = nogps_rating.rate_rows(rows, nogps_log.num)
        self.assertEqual(len(result['episodes']), 1)
        self.assertEqual(result['episodes'][0]['lim'], 50)


if __name__ == '__main__':
    unittest.main()
