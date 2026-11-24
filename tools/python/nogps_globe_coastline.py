#!/usr/bin/env python3
"""Turns the Natural Earth 110 m coastline and land (public domain) into the outline and the land of the globe of
About NonGPS Maps.

  nogps_globe_coastline.py ne_110m_coastline.geojson ne_110m_land.geojson \
      --swift iphone/Maps/UI/NoGps/GlobeCoastline.swift \
      --java android/app/src/main/java/app/organicmaps/nogps/GlobeCoastline.java

The geojsons are https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_coastline.geojson and
ne_110m_land.geojson next to it. Both outputs are generated: change this script and run it again, never the files.

The outline is a flat array of lat, lon pairs in tenths of a degree (int16), a stroke after a stroke, a pair of
SEPARATOR between two strokes, thinned with Douglas-Peucker to at most MAX_POINTS points: the globe is about 90 dp
wide. The land is a grid of LAND_STEP_DEG cells, a row of a latitude after a row, from the north: each row is the
number of its runs, then the runs of cells along it from lon -180, sea first, so the first run can be 0. The coast
cannot be filled instead: its strokes are cut at the antimeridian and along the south pole.
"""

import argparse
import json
import math
import sys

MAX_POINTS = 400
# Tenths of a degree: int16 holds 3276.7 degrees.
SCALE = 10
SEPARATOR = -32768
# The coast of Antarctica runs along the pole in the data: a line there is no coast.
POLE_LAT = -85.0
SPECK = 4
LAND_STEP_DEG = 1


def douglas_peucker(points, tolerance):
    """The points of the stroke that stay when no point is further than tolerance (degrees) from the line."""
    if len(points) < 3:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        (ay, ax), (by, bx) = points[a], points[b]
        far, far_i = 0.0, -1
        for i in range(a + 1, b):
            d = distance(points[i], (ay, ax), (by, bx))
            if d > far:
                far, far_i = d, i
        if far > tolerance:
            keep[far_i] = True
            stack += [(a, far_i), (far_i, b)]
    return [p for p, k in zip(points, keep) if k]


def distance(p, a, b):
    """The distance of p from the segment a-b, all as (lat, lon) in degrees on a plane."""
    (py, px), (ay, ax), (by, bx) = p, a, b
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def strokes_of(geojson):
    """The strokes of the geojson as lists of (lat, lon), cut where the coast runs along the south pole."""
    result = []
    for feature in geojson["features"]:
        geometry = feature["geometry"]
        lines = [geometry["coordinates"]] if geometry["type"] == "LineString" else geometry["coordinates"]
        for line in lines:
            stroke = []
            for lon, lat in line:
                if lat < POLE_LAT:
                    if len(stroke) > 1:
                        result.append(stroke)
                    stroke = []
                else:
                    stroke.append((lat, lon))
            if len(stroke) > 1:
                result.append(stroke)
    return result


def thin(strokes, max_points=MAX_POINTS):
    """The strokes thinned with the smallest tolerance that leaves at most max_points points. A stroke that is not
    SPECK tolerances across is dropped: an island that small is a dot at this size."""
    low, high = 0.0, 90.0
    best = None
    for _ in range(40):
        tolerance = (low + high) / 2
        thinned = []
        for stroke in strokes:
            kept = douglas_peucker(stroke, tolerance)
            lats, lons = [p[0] for p in kept], [p[1] for p in kept]
            if math.hypot(max(lats) - min(lats), max(lons) - min(lons)) > SPECK * tolerance:
                thinned.append(kept)
        if sum(len(s) for s in thinned) <= max_points:
            best, high = thinned, tolerance
        else:
            low = tolerance
    return best


def land_rows(geojson, step=LAND_STEP_DEG):
    """The land as runs per row: a cell is land when its centre is inside an odd number of rings (holes included)."""
    edges = []
    for feature in geojson["features"]:
        geometry = feature["geometry"]
        polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
        for polygon in polygons:
            for ring in polygon:
                edges += [(a, b) for a, b in zip(ring, ring[1:] + ring[:1]) if a != b]
    cols = round(360 / step)
    result = []
    for row in range(round(180 / step)):
        lat = 90 - (row + 0.5) * step
        # Where the edges cross the parallel: even-odd between the crossings, a row as a scanline.
        crossings = sorted(
            (lon1 + (lat - lat1) * (lon2 - lon1) / (lat2 - lat1))
            for (lon1, lat1), (lon2, lat2) in edges
            if (lat1 <= lat) != (lat2 <= lat)
        )
        land = [False] * cols
        for start, end in zip(crossings[::2], crossings[1::2]):
            for col in range(cols):
                if start <= -180 + (col + 0.5) * step < end:
                    land[col] = True
        runs, value, length = [], False, 0
        for cell in land:
            if cell == value:
                length += 1
            else:
                runs.append(length)
                value, length = cell, 1
        runs.append(length)
        result.append(runs)
    return result


def flatten_land(rows_of_runs):
    flat = []
    for runs in rows_of_runs:
        flat += [len(runs)] + runs
    return flat


def flatten(strokes):
    """lat, lon pairs in SCALE, the separator pair between two strokes."""
    flat = []
    for i, stroke in enumerate(strokes):
        if i:
            flat += [SEPARATOR, SEPARATOR]
        for lat, lon in stroke:
            flat += [round(lat * SCALE), round(lon * SCALE)]
    return flat


def rows(flat, indent):
    """Eight numbers a line."""
    lines = []
    for i in range(0, len(flat), 8):
        lines.append(indent + ", ".join(str(v) for v in flat[i : i + 8]) + ",")
    return "\n".join(lines)


HEADER = "Generated by tools/python/nogps_globe_coastline.py from Natural Earth 110 m (public domain): don't edit."


def swift(flat, land):
    return f"""// {HEADER}

/// The outline and the land of the continents for GlobeScene.
enum GlobeCoastline {{
  /// lat, lon pairs in 1/{SCALE} of a degree, a pair of `separator` between two strokes.
  // swiftformat:disable wrap
  static let points: [Int16] = [
{rows(flat, "    ")}
  ]

  /// Rows of `landStepDeg` from the north, each the number of its runs and then the runs of cells from lon -180, sea
  /// first.
  static let landRuns: [Int16] = [
{rows(land, "    ")}
  ]
  // swiftformat:enable wrap

  static let scale = {SCALE}
  static let separator = Int16.min
  static let maxPoints = {MAX_POINTS}
  static let landStepDeg = {LAND_STEP_DEG}
}}
"""


def java(flat, land):
    return f"""// {HEADER}
package app.organicmaps.nogps;

/**
 * The outline and the land of the continents for GlobeScene.
 */
final class GlobeCoastline
{{
  /** lat, lon pairs in 1/{SCALE} of a degree, a pair of SEPARATOR between two strokes. */
  // clang-format off
  static final short[] POINTS = {{
{rows(flat, "      ")}
  }};

  /**
   * Rows of LAND_STEP_DEG from the north, each the number of its runs and then the runs of cells from lon -180, sea
   * first.
   */
  static final short[] LAND_RUNS = {{
{rows(land, "      ")}
  }};
  // clang-format on

  static final int SCALE = {SCALE};
  static final short SEPARATOR = Short.MIN_VALUE;
  static final int MAX_POINTS = {MAX_POINTS};
  static final int LAND_STEP_DEG = {LAND_STEP_DEG};

  private GlobeCoastline() {{}}
}}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("geojson")
    parser.add_argument("land_geojson")
    parser.add_argument("--swift", required=True)
    parser.add_argument("--java", required=True)
    args = parser.parse_args()
    with open(args.geojson, encoding="utf-8") as f:
        strokes = thin(strokes_of(json.load(f)))
    with open(args.land_geojson, encoding="utf-8") as f:
        land = flatten_land(land_rows(json.load(f)))
    flat = flatten(strokes)
    with open(args.swift, "w", encoding="utf-8") as f:
        f.write(swift(flat, land))
    with open(args.java, "w", encoding="utf-8") as f:
        f.write(java(flat, land))
    print(f"{sum(len(s) for s in strokes)} points in {len(strokes)} strokes", file=sys.stderr)


if __name__ == "__main__":
    main()
