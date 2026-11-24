#!/usr/bin/env python3
"""Tests of nogps_globe_coastline.py on made-up coasts.

  python3 tools/python/nogps_globe_coastline_test.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_globe_coastline as m  # noqa: E402


def line(coords):
    return {"type": "Feature", "geometry": {"type": "LineString", "coordinates": coords}}


class CoastlineTest(unittest.TestCase):
    def test_straight_line_thins_to_its_ends(self):
        stroke = [(0.0, float(i)) for i in range(50)]
        self.assertEqual(m.douglas_peucker(stroke, 0.1), [stroke[0], stroke[-1]])

    def test_corner_stays(self):
        stroke = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0)]
        self.assertEqual(m.douglas_peucker(stroke, 1.0), stroke)

    def test_geojson_is_read_as_lat_lon_and_cut_at_the_pole(self):
        coast = {"features": [line([[10, 50], [11, 51], [12, -89], [13, -89.5], [14, -60], [15, -61]])]}
        self.assertEqual(m.strokes_of(coast), [[(50, 10), (51, 11)], [(-60, 14), (-61, 15)]])

    def test_thin_keeps_the_cap(self):
        coast = [[(float(i % 7), float(i) / 10 + k * 20) for i in range(300)] for k in range(8)]
        thinned = m.thin(coast, 120)
        self.assertLessEqual(sum(len(s) for s in thinned), 120)
        self.assertGreater(len(thinned), 1)

    def test_flat_has_a_separator_between_strokes_only(self):
        flat = m.flatten([[(1.0, 2.0), (3.0, 4.0)], [(-5.5, 6.0), (7.0, -8.0)]])
        self.assertEqual(flat, [10, 20, 30, 40, m.SEPARATOR, m.SEPARATOR, -55, 60, 70, -80])

    def test_output_fits_int16(self):
        flat = m.flatten([[(-85.0, -180.0), (83.6, 180.0)]])
        self.assertTrue(all(-32768 <= v <= 32767 for v in flat))


    def test_land_is_the_cells_inside_the_rings_less_the_holes(self):
        outer = [[0, 0], [20, 0], [20, 10], [0, 10], [0, 0]]
        hole = [[5, 2], [10, 2], [10, 6], [5, 6], [5, 2]]
        land = {"features": [{"geometry": {"type": "Polygon", "coordinates": [outer, hole]}}]}
        rows = m.land_rows(land, step=1)
        self.assertEqual(len(rows), 180)
        for runs in rows:
            self.assertEqual(sum(runs), 360)
        # The row of lat 0.5 is the bottom of the box: sea up to lon 0, 20 cells of land, then sea.
        self.assertEqual(rows[89], [180, 20, 160])
        # The row of lat 3.5 crosses the hole from lon 5 to 10.
        self.assertEqual(rows[86], [180, 5, 5, 10, 160])
        self.assertEqual(rows[0], [360])
        self.assertEqual(m.flatten_land([[360], [180, 20, 160]]), [1, 360, 3, 180, 20, 160])


if __name__ == "__main__":
    unittest.main()
