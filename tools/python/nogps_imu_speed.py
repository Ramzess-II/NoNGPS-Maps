#!/usr/bin/env python3
"""How well the box could tell the speed of the car from its accelerometer and gyro alone, without OBD.

Runs the estimator of a USB-only box (issue #312) on the ACCB and GYRO lines of recorded trips and compares its
speed with the OBD speed of the same trips: the path of each stretch between stops and of each segment between turns
of 30 degrees or more, where the core puts the mark back on the road. The logs have the horizontal acceleration and
the yaw rate in 0.2 s slices, but not the pitch and roll rates: the gravity leak measured at a stop is kept until the
next stop, so a slope met on the way is taken for acceleration. That makes the result a pessimistic bound for a
firmware that tracks gravity with all three gyro axes.

The estimator, in the horizontal plane of the box:
  - each stretch between stops starts at v = 0, the leak of gravity is the mean acceleration while the car stood;
  - v' = a - g - w x v: the velocity is integrated in the axes of the box and turned back by the yaw, so the forward
    axis of the box is not needed; the speed is |v|;
  - in a turn (|w| > 5 deg/s, |v| > 3 m/s) the speed is pulled towards a_lat / w;
  - after a minute of driving, the forward axis is where the velocity has pointed, and only the speed along it is
    integrated: a car does not slide sideways (--free: without it).
What else can be tried: --carry takes the error found at a stop into the next stretches, --closure corrects the path
after each stop by the speed left at it, --turn-obd takes the OBD speed in turns, as a radius from the map would give.

The forward axis and the error carried from a stop are learned over the trips of a log in time order, as one box
would: --trip changes what they have learned before the trips chosen.

Usage:
  nogps_imu_speed.py <logs or folders>... [--trip N] [--lag 0.2] [--no-turns] [--free] [--carry] [--closure]
                     [--turn-obd] [--stretches] [--sign -1]
"""

import argparse
import bisect
import math
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nogps_log  # noqa: E402

SLICES = nogps_log.SLICES
SLICE_MS = 1000 // SLICES
SENSOR_LINE = re.compile(r'\): (ACCB_BEFORE|ACCB|GYRO) (.+)$')
# Slices closer than this belong to one stretch of driving.
MAX_GAP_MS = 2 * SLICE_MS + 50
TURN_MIN_RATE = math.radians(5)
TURN_MIN_MPS = 3
# How fast the speed follows a_lat / w in a turn.
TURN_TIME_S = 1.0
# The OBD speed of the GYRO lines comes this late after the ACCB slices, s: fitted on the trips of October 2026.
DEFAULT_LAG_S = 0.2
# Only stretches this long, by OBD, are compared.
MIN_STRETCH_M = 100
FAST_KMH = 80
# Seconds of driving faster than 3 m/s before the forward axis is used.
FORWARD_READY_S = 60


def slices_of(t, words, count):
    """(time, values, number) of each slice of the second before |t| that has |count| values."""
    result = []
    for i, word in enumerate(words[:SLICES]):
        try:
            values = [float(x) for x in word.split(',')[:count]]
        except ValueError:
            continue
        # A line cut off at the end of a log.
        if len(values) == count:
            result.append((t - 1000 + (i + 1) * SLICE_MS, values, i))
    return result


def read_sensors(group):
    """Acceleration slices (t, h1, h2, before) and gyro slices (t, yaw deg/s, OBD km/h) of a group of log lines."""
    acc, gyro = [], []
    for t, _, line in group.lines:
        m = SENSOR_LINE.search(line.split('\n', 1)[0])
        if not m:
            continue
        kind, words = m.group(1), m.group(2).split(' ')
        if kind == 'GYRO' and len(words) >= 1 + 2 * SLICES:
            speeds = words[1 + SLICES:1 + 2 * SLICES]
            for ts, values, i in slices_of(t, words[1:1 + SLICES], 1):
                try:
                    kmh = float(speeds[i])
                except ValueError:
                    kmh = -1
                gyro.append((ts, values[0] * SLICES, kmh))
        elif kind == 'ACCB_BEFORE' and words[0].isdigit():
            acc += [(ts, v[0], v[1], True) for ts, v, _ in slices_of(t - int(words[0]) * 1000, words[1:], 2)]
        elif kind == 'ACCB':
            acc += [(ts, v[0], v[1], False) for ts, v, _ in slices_of(t, words, 2)]
    acc.sort()
    gyro.sort()
    # Lines logged twice (a log of two runs) give the same slices.
    acc = [a for i, a in enumerate(acc) if i == 0 or a[0] != acc[i - 1][0]]
    gyro = [g for i, g in enumerate(gyro) if i == 0 or g[0] != gyro[i - 1][0]]
    return acc, gyro


class Series:
    """Values at times, looked up at the nearest time within a slice."""

    def __init__(self, items, index):
        self.times = [x[0] for x in items]
        self.values = [x[index] for x in items]

    def at(self, t, default=None):
        i = bisect.bisect_left(self.times, t)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(self.times) and abs(self.times[j] - t) <= SLICE_MS // 2 + 10:
                if best is None or abs(self.times[j] - t) < abs(self.times[best] - t):
                    best = j
        return self.values[best] if best is not None else default


def stretches(acc):
    """Runs of acceleration slices without a gap, each a list of slices."""
    result = []
    for a in acc:
        if result and a[0] - result[-1][-1][0] <= MAX_GAP_MS and not (a[3] and not result[-1][-1][3]):
            result[-1].append(a)
        else:
            result.append([a])
    return result


class Forward:
    """The forward axis of the box in (h1, h2), learned from where the velocity points, as the box would."""

    def __init__(self):
        self.sum = [0.0, 0.0]
        self.seconds = 0.0

    def learn(self, v1, v2, dt):
        speed = math.hypot(v1, v2)
        if speed < TURN_MIN_MPS:
            return
        # A car backing up: its velocity points backward.
        sign = 1 if v1 * self.sum[0] + v2 * self.sum[1] >= 0 else -1
        self.sum[0] += sign * v1 / speed * dt
        self.sum[1] += sign * v2 / speed * dt
        self.seconds += dt

    def axis(self):
        if self.seconds < FORWARD_READY_S:
            return None
        norm = math.hypot(*self.sum)
        return self.sum[0] / norm, self.sum[1] / norm


def turn_speed(lateral, w):
    """The speed by the centripetal acceleration of a turn, or None."""
    if abs(w) <= TURN_MIN_RATE:
        return None
    speed = lateral / w
    return speed if speed > 0 else None


class Options:
    def __init__(self, sign=1, turns=True, lag_s=DEFAULT_LAG_S, carry=False, closure=False, turn_obd=False):
        self.sign = sign
        self.turns = turns
        self.lag_ms = round(lag_s * 1000)
        # Take the error found at a stop into the next stretches.
        self.carry = carry
        # After the stop, spread the speed left over the time since the last turn: the path afterwards.
        self.closure = closure
        # In a turn the speed is the OBD speed: as if the radius of the turn came from the map.
        self.turn_obd = turn_obd


class Stretch:
    """What the estimator has found on a stretch between stops."""

    def __init__(self):
        self.speeds = []
        # The signed speed along the forward axis, None before the axis is known.
        self.along = []
        # The last slice where a turn has told the speed.
        self.turn_index = 0


def estimate(stretch, rate, obd, options, forward, bias):
    """The IMU speeds of a stretch that starts with the car standing, or None.

    |bias| is [the error of the acceleration along the forward axis found at earlier stops, m/s2]."""
    still = [a for a in stretch if a[3]]
    if len(still) < SLICES:
        return None
    # The car stood during the lines before the start but the last one: the OBD speed comes a second late.
    quiet = still[:-SLICES] or still[:SLICES]
    g1 = statistics.fmean(a[1] for a in quiet)
    g2 = statistics.fmean(a[2] for a in quiet)
    v1 = v2 = 0.0
    result = Stretch()
    previous = None
    for i, a in enumerate(stretch):
        # The quiet slices are the first ones of the stretch.
        if i < len(quiet):
            result.speeds.append(0.0)
            result.along.append(None)
            result.turn_index = i
            previous = a[0]
            continue
        dt = (a[0] - previous) / 1000 if previous is not None else SLICE_MS / 1000
        previous = a[0]
        # Right turn is plus in the log; the rotation about up is then minus.
        w = -options.sign * math.radians(rate.at(a[0], 0.0))
        a1, a2 = a[1] - g1, a[2] - g2
        axis = forward.axis() if forward else None
        if axis:
            # The car does not slide sideways: only the speed along the forward axis is integrated.
            f1, f2 = axis
            along = v1 * f1 + v2 * f2 + (a1 * f1 + a2 * f2 - bias[0]) * dt
            if options.turns and abs(along) > TURN_MIN_MPS:
                # Centripetal: a = w up x v, up x f = (-f2, f1).
                by_turn = turn_speed((a1 * -f2 + a2 * f1) * math.copysign(1, along), w)
                if by_turn and options.turn_obd:
                    kmh = obd.at(a[0] + options.lag_ms, -1)
                    by_turn = kmh / 3.6 if kmh >= 0 else None
                    if by_turn:
                        along = math.copysign(by_turn, along)
                        result.turn_index = i
                elif by_turn:
                    along += min(1.0, dt / TURN_TIME_S) * (math.copysign(by_turn, along) - along)
                    result.turn_index = i
            v1, v2 = along * f1, along * f2
            result.speeds.append(abs(along))
            result.along.append(along)
            continue
        # The velocity in the axes of the box turns back as the box turns: v' = a - w up x v, up x (v1, v2) = (-v2, v1).
        c, s = math.cos(w * dt), math.sin(w * dt)
        v1, v2 = c * v1 + s * v2, -s * v1 + c * v2
        v1 += a1 * dt
        v2 += a2 * dt
        speed = math.hypot(v1, v2)
        if options.turns and speed > TURN_MIN_MPS:
            by_turn = turn_speed((a1 * -v2 + a2 * v1) / speed, w)
            if by_turn:
                scale = (speed + min(1.0, dt / TURN_TIME_S) * (by_turn - speed)) / speed
                v1, v2 = v1 * scale, v2 * scale
                speed *= scale
        if forward is not None:
            forward.learn(v1, v2, dt)
        result.speeds.append(speed)
        result.along.append(None)
    return result


def close(stretch, found):
    """(speed left at the stop, first and last slice since the last turn, seconds), or None."""
    known = next((i for i, x in enumerate(found.along) if x is not None), None)
    # The forward axis has become known on the way: the speed then is not known to be right.
    if known is None or not stretch[known - 1][3]:
        return None
    # Before the first slice of a known axis the speed was 0: the car stood.
    first = max(found.turn_index, known - 1)
    last = len(found.along) - 1
    if found.along[first] is None:
        found.along[first] = 0.0
    if last - first < 10 * SLICES:
        return None
    left = found.along[last]
    seconds = (stretch[last][0] - stretch[first][0]) / 1000
    return left, first, last, seconds


# A turn that ends a segment: this many degrees with no pause longer than 2 s under 5 deg/s.
SEGMENT_TURN_DEG = 30
MIN_SEGMENT_M = 50


def turn_ends(stretch, rate):
    """Indexes of the slices where turns of SEGMENT_TURN_DEG or more end."""
    ends = []
    angle = 0.0
    quiet = 0
    for i, a in enumerate(stretch):
        r = rate.at(a[0], 0.0)
        if abs(r) > 5:
            angle += r * SLICE_MS / 1000
            quiet = 0
        elif angle:
            quiet += 1
            if quiet > 2 * SLICES:
                if abs(angle) >= SEGMENT_TURN_DEG:
                    ends.append(i - quiet)
                angle = 0.0
    return ends


def compare(trip, acc, gyro, options, forward, bias):
    """(a dict per stretch of the trip, a dict per segment between turns): path and speed of the IMU against OBD."""
    lag_ms = options.lag_ms
    rate = Series(gyro, 1)
    obd = Series(gyro, 2)
    result = []
    segments = []
    for stretch in stretches([a for a in acc if trip.start - 5000 <= a[0] <= trip.end]):
        found = estimate(stretch, rate, obd, options, forward, bias)
        if found is None:
            continue
        speeds = found.speeds
        closed = close(stretch, found)
        if closed:
            left, first, last, seconds = closed
            if options.closure:
                for i in range(first, last + 1):
                    found.along[i] -= left * (stretch[i][0] - stretch[first][0]) / 1000 / seconds
                    speeds[i] = abs(found.along[i])
            if options.carry and seconds >= 20:
                # The error found is on top of the one already taken off.
                bias[0] += 0.5 * left / seconds
        ends = set(turn_ends(stretch, rate))
        imu_m = obd_m = seg_imu = seg_obd = 0.0
        errors = []
        max_kmh = seg_max_kmh = 0
        for i, (a, b) in enumerate(zip(stretch, stretch[1:])):
            speed = speeds[i + 1]
            dt = (b[0] - a[0]) / 1000
            kmh = obd.at(b[0] + lag_ms, None)
            if kmh is None:
                # No GYRO line late enough: the car has stopped, a standing car writes none.
                kmh = obd.at(b[0], 0)
            # A stale OBD speed (-1) tells nothing: the slice counts for neither path.
            if kmh >= 0:
                imu_m += speed * dt
                obd_m += kmh / 3.6 * dt
                seg_imu += speed * dt
                seg_obd += kmh / 3.6 * dt
                errors.append(speed * 3.6 - kmh)
                max_kmh = max(max_kmh, kmh)
                seg_max_kmh = max(seg_max_kmh, kmh)
            if i + 1 in ends or i + 2 == len(stretch):
                if seg_obd >= MIN_SEGMENT_M:
                    segments.append(dict(obd_m=seg_obd, imu_m=seg_imu, error=(seg_imu - seg_obd) / seg_obd,
                                         fast=seg_max_kmh > FAST_KMH))
                seg_imu = seg_obd = 0.0
                seg_max_kmh = 0
        if obd_m < MIN_STRETCH_M:
            continue
        result.append(dict(trip=trip.id, start=stretch[0][0], seconds=(stretch[-1][0] - stretch[0][0]) / 1000,
                           obd_m=obd_m, imu_m=imu_m, error=(imu_m - obd_m) / obd_m, max_kmh=max_kmh,
                           fast=max_kmh > FAST_KMH, rmse=math.sqrt(statistics.fmean(e * e for e in errors)),
                           errors=errors))
    return result, segments


def segment_summary(rows):
    if not rows:
        return 'no segments'
    errors = sorted(abs(r['error']) for r in rows)
    meters = sorted(abs(r['imu_m'] - r['obd_m']) for r in rows)
    lengths = sorted(r['obd_m'] for r in rows)
    return ('%3d segments, median %4.0f m: median |path error| %5.1f%%, within 10%%: %3d%%, '
            '|error| median %4.0f m, p90 %4.0f m'
            % (len(rows), lengths[len(lengths) // 2], 100 * errors[len(errors) // 2],
               100 * sum(1 for e in errors if e <= 0.1) // len(errors), meters[len(meters) // 2],
               meters[min(len(meters) - 1, int(0.9 * len(meters)))]))


def summary(rows):
    if not rows:
        return 'no stretches'
    errors = sorted(abs(r['error']) for r in rows)
    signed = statistics.median(r['error'] for r in rows)
    squares = [e * e for r in rows for e in r['errors']]
    total_obd = sum(r['obd_m'] for r in rows)
    total_imu = sum(r['imu_m'] for r in rows)
    within = sum(1 for e in errors if e <= 0.10)
    return ('%3d stretches, %6.1f km: median |path error| %5.1f%% (signed %+5.1f%%), within 10%%: %3d%%, '
            'p90 %5.1f%%, total %+5.1f%%, speed RMSE %5.1f km/h (median of stretches %4.1f)'
            % (len(rows), total_obd / 1000, 100 * statistics.median(errors), 100 * signed, 100 * within // len(rows),
               100 * errors[min(len(errors) - 1, int(0.9 * len(errors)))], 100 * (total_imu - total_obd) / total_obd,
               math.sqrt(statistics.fmean(squares)), statistics.median(r['rmse'] for r in rows)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('logs', nargs='+', help='the trip logs of the app, files, folders or zips')
    parser.add_argument('--trip', type=int, action='append', help='only these trips, ids of nogps_log.py trips')
    parser.add_argument('--lag', type=float, help='the OBD speed is this late, s (%.1f)' % DEFAULT_LAG_S)
    parser.add_argument('--no-turns', action='store_true', help='without the speed from the turns')
    parser.add_argument('--free', action='store_true', help='integrate the velocity in 2D, without the forward axis')
    parser.add_argument('--sign', type=int, choices=(1, -1), default=1, help='the sign of the yaw in the logs')
    parser.add_argument('--stretches', action='store_true', help='print every stretch')
    parser.add_argument('--carry', action='store_true', help='take the error found at a stop into the next stretches')
    parser.add_argument('--closure', action='store_true', help='correct the path after the stop by the speed left')
    parser.add_argument('--turn-obd', action='store_true', help='the OBD speed in turns, as from the radius on the map')
    args = parser.parse_args()

    analysis = nogps_log.Analysis(nogps_log.load_paths(args.logs))
    sensors = {id(g): read_sensors(g) for g in analysis.groups}
    options = Options(args.sign, not args.no_turns, DEFAULT_LAG_S if args.lag is None else args.lag, args.carry,
                      args.closure, args.turn_obd)
    rows = []
    segments = []
    forwards = {}
    biases = {}
    for trip in analysis.trips:
        if not trip.driven or (args.trip and trip.id not in args.trip):
            continue
        acc, gyro = sensors[id(trip.group)]
        forward = None if args.free else forwards.setdefault(id(trip.group), Forward())
        trip_rows, trip_segments = compare(trip, acc, gyro, options, forward, biases.setdefault(id(trip.group), [0.0]))
        segments += trip_segments
        if not trip_rows:
            continue
        rows += trip_rows
        print('trip %3d  %s' % (trip.id, summary(trip_rows)))
        if args.stretches:
            for r in trip_rows:
                print('    %s  %5.0f s  OBD %6.0f m  IMU %6.0f m  %+6.1f%%  max %3.0f km/h  RMSE %5.1f km/h'
                      % (nogps_log.clock(r['start']), r['seconds'], r['obd_m'], r['imu_m'], 100 * r['error'],
                         r['max_kmh'], r['rmse']))
    print()
    print('all       ', summary(rows))
    print('city      ', summary([r for r in rows if not r['fast']]))
    print('fast road ', summary([r for r in rows if r['fast']]))
    print('between turns of %d deg or more and stops:' % SEGMENT_TURN_DEG)
    print('all       ', segment_summary(segments))
    print('city      ', segment_summary([r for r in segments if not r['fast']]))
    print('fast road ', segment_summary([r for r in segments if r['fast']]))


if __name__ == '__main__':
    main()
