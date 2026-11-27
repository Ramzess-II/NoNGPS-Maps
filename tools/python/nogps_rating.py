"""The driver rating of the core, rebuilt from the TRIP lines of a trip log, to tune its constants on trips.

The rules and the constants are those of SpeedingMeter (libs/map/nogps/speeding_meter.hpp), see "Driver rating" in
docs/nogps/navigation-rules.md. A TRIP line has the real speed (speed times scale) and lim=, the limit in force, or "-"
where the core did not rate the second.

  nogps_log.py rating <logs>
"""

import math

TOLERANCE_KMH = 20
HYSTERESIS_KMH = 3
START_S = 3
END_S = 2
MERGE_S = 5
LOWER_LIMIT_GRACE_M = 150
BAND2_KMH = 40
BAND3_KMH = 60
BAND_WEIGHTS = (1, 3, 8)
SCORE_SCALE_S = 360
SCORE_WINDOW_KM = 500
SCORE_MIN_KM = 20
# A longer pause between the lines breaks the driving.
MAX_GAP_MS = 2500


MIN_RATED_KMH = 5


def band_of(excess_kmh):
    """1, 2 or 3."""
    if excess_kmh >= BAND3_KMH:
        return 3
    return 2 if excess_kmh >= BAND2_KMH else 1


def score_of(weighted_s, rated_s):
    if rated_s <= 0:
        return 100
    return int(math.floor(100 * math.exp(-weighted_s / (rated_s / 3600) / SCORE_SCALE_S) + 0.5))


class Stretch:
    """The sums of a stretch over the limit."""

    def __init__(self, start_ms):
        self.start_ms = self.end_ms = start_ms
        self.duration_ms = 0
        self.distance_m = 0.0
        self.kmh_ms = 0.0
        self.peak_excess = -1000
        self.peak_kmh = 0
        self.limit = 0

    def add(self, kmh, limit, dt_ms, t):
        self.end_ms = t
        self.duration_ms += dt_ms
        self.distance_m += kmh / 3.6 * dt_ms / 1000
        self.kmh_ms += kmh * dt_ms
        if kmh - limit > self.peak_excess:
            self.peak_excess, self.peak_kmh, self.limit = kmh - limit, kmh, limit

    def merge(self, other):
        self.end_ms = other.end_ms
        self.duration_ms += other.duration_ms
        self.distance_m += other.distance_m
        self.kmh_ms += other.kmh_ms
        if other.peak_excess > self.peak_excess:
            self.peak_excess, self.peak_kmh, self.limit = other.peak_excess, other.peak_kmh, other.limit


class Meter:
    """SpeedingMeter in Python: feed one second at a time, then flush()."""

    def __init__(self, grace_m=LOWER_LIMIT_GRACE_M):
        self._grace_m = grace_m
        self.rated_m = 0.0
        self.rated_s = 0.0
        self.weighted_s = 0.0
        self.episodes = []
        self._prev = None
        self._limit = None
        self._lower_m = 0.0
        self._over = None
        self._confirmed = False
        self._under = None
        self._held = None

    def sample(self, t, kmh, limit):
        """\\param kmh the real speed, None if not known; \\param limit the limit in force, None or <= 0 unrated."""
        gap = self._prev is None or t <= self._prev or t - self._prev > MAX_GAP_MS
        dt = 0 if gap else t - self._prev
        self._prev = t
        rated = kmh is not None and kmh >= MIN_RATED_KMH and limit is not None and limit > 0
        if gap:
            self._end_rated()
            self._limit, self._lower_m = None, 0.0
        elif not rated:
            self._end_rated()
        if rated:
            self._rated(t, kmh, limit, dt)
        held = self._held
        if (held and t - held.end_ms > MERGE_S * 1000
                and not (self._over and self._over.start_ms - held.end_ms <= MERGE_S * 1000)):
            self._emit(held)
            self._held = None

    def flush(self):
        self._end_rated()
        if self._held:
            self._emit(self._held)
            self._held = None

    def _rated(self, t, kmh, limit, dt):
        distance = kmh / 3.6 * dt / 1000
        self.rated_m += distance
        self.rated_s += dt / 1000
        if self._limit is None or limit > self._limit:
            self._limit, self._lower_m = limit, 0.0
        elif limit == self._limit:
            self._lower_m = 0.0
        else:
            self._lower_m += distance
            if self._lower_m >= self._grace_m:
                self._limit, self._lower_m = limit, 0.0
        limit = self._limit
        excess = kmh - limit
        if not self._confirmed:
            if excess <= TOLERANCE_KMH:
                self._over = None
                return
            if self._over is None:
                self._over = Stretch(t)
            self._over.add(kmh, limit, dt, t)
            if self._over.duration_ms >= START_S * 1000:
                self._confirmed, self._under = True, None
            return
        if excess >= TOLERANCE_KMH - HYSTERESIS_KMH:
            if self._under:
                self._over.merge(self._under)
                self._under = None
            self._over.add(kmh, limit, dt, t)
            return
        if self._under is None:
            self._under = Stretch(t)
        self._under.add(kmh, limit, dt, t)
        if t - self._under.start_ms >= END_S * 1000:
            self._finish()

    def _end_rated(self):
        if self._confirmed:
            self._finish()
        self._over = self._under = None
        self._confirmed = False

    def _finish(self):
        done = self._over
        self._over = self._under = None
        self._confirmed = False
        if self._held and done.start_ms - self._held.end_ms <= MERGE_S * 1000:
            self._held.merge(done)
            return
        if self._held:
            self._emit(self._held)
        self._held = done

    def _emit(self, s):
        band = band_of(s.peak_excess)
        seconds = s.duration_ms / 1000
        self.weighted_s += BAND_WEIGHTS[band - 1] * seconds
        mean = s.kmh_ms / s.duration_ms if s.duration_ms else s.peak_kmh
        self.episodes.append(dict(ms=s.start_ms, dur=seconds, dist=round(s.distance_m), lim=s.limit,
                                  peak=round(s.peak_kmh), mean=round(mean), band=band))

    def result(self):
        counts = [sum(1 for e in self.episodes if e['band'] == b) for b in (1, 2, 3)]
        return dict(rated_km=self.rated_m / 1000, rated_s=self.rated_s, weighted_s=self.weighted_s,
                    episodes=self.episodes, bands=counts, score=score_of(self.weighted_s, self.rated_s))


def rate_rows(rows, num):
    """The rating of the TRIP rows of a trip. \\param num nogps_log.num: the number at the start of a field."""
    # The lim= of a row is the limit in force: the core has applied the grace of a lower limit already.
    meter = Meter(grace_m=0)
    for row in rows:
        speed = num(row, 'speed')
        kmh = None if speed is None or speed < 0 else speed * (num(row, 'scale') or 1)
        limit = num(row, 'lim')
        meter.sample(row['t'], kmh, limit)
    meter.flush()
    return meter.result()


def window(results):
    """The rating over the newest of the trips, given the oldest first: the trips that add up to SCORE_WINDOW_KM."""
    km = rated_s = weighted_s = 0.0
    bands = [0, 0, 0]
    for r in reversed(results):
        if km >= SCORE_WINDOW_KM:
            break
        km += r['rated_km']
        rated_s += r['rated_s']
        weighted_s += r['weighted_s']
        bands = [a + b for a, b in zip(bands, r['bands'])]
    return dict(rated_km=km, enough=km >= SCORE_MIN_KM, score=score_of(weighted_s, rated_s), bands=bands)
