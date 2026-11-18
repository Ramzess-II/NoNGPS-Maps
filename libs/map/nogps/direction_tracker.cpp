#include "map/nogps/direction_tracker.hpp"

#include "base/logging.hpp"

#include <algorithm>
#include <cmath>

namespace nogps
{
void DirectionTracker::OnSpeed(int speedKmh, double pathM)
{
  int64_t const now = m_clock.NowMs();
  if (speedKmh == 0)
  {
    if (!m_standMs)
    {
      m_standMs = now;
      StartStopCheck();
    }
    CheckStop();
    m_startMs.reset();
    m_slowMs.reset();
    m_startAfterSlow = false;
    // The next start is a start forward until the accelerometer tells the other.
    m_direction = 1;
    return;
  }
  if (speedKmh > kSlowSpeedKmh)
  {
    if (m_slowMs)
    {
      m_startMs.reset();
      m_startAfterSlow = true;
    }
    m_slowMs.reset();
  }
  else if (m_startMs && m_fasterSinceStart && !m_slowMs)
  {
    m_slowMs = now;
  }
  int64_t const lagMs = static_cast<int64_t>(m_lag.Get() * 1000);
  if (!m_startMs)
  {
    m_startMs = now;
    m_fasterSinceStart = false;
    m_startM = 0;
    m_startMarkM = 0;
    m_startFeltMps = 0;
    m_segMaxKmh = 0;
    m_stopCheck.reset();
    m_startFelt = false;
    m_crawlCheck = false;
    m_otherWayMs.reset();
    // It stood for sure until the lag of its speed and a margin before it has reported that it moves.
    m_startStandToMs = now - lagMs - kStandMarginMs;
    m_startFromMps = m_startAfterSlow ? m_direction * kSlowSpeedKmh / 3.6 : 0;
  }
  if (speedKmh > kSlowSpeedKmh)
    m_fasterSinceStart = true;
  if (speedKmh >= m_segMaxKmh)
  {
    m_segMaxKmh = speedKmh;
    m_segPeakMs = now;
  }
  int direction = m_direction;
  if (!m_startFelt && now - *m_startMs >= kStartFeltAfterMs)
  {
    m_startFelt = true;
    // A start the accelerometer tells nothing about is a start forward, unless the car didn't stand.
    if (!m_startAfterSlow)
      direction = 1;
    std::optional<double> stand;
    if (m_standMs)
    {
      int64_t standFrom = std::max(*m_standMs, m_startStandToMs - kMaxStandFeltMs);
      if (m_startStandToMs - standFrom < kMinStandFeltMs)
        standFrom = std::max(*m_standMs - lagMs + kStandMarginMs, m_startStandToMs - kMinStandFeltMs);
      if (m_startStandToMs - standFrom >= kMinStandFeltMs)
        stand = m_accel.GetAccelAlong(standFrom, m_startStandToMs);
    }
    double const stoodSec = m_standMs ? (*m_startMs - *m_standMs) / 1000.0 : -1;
    m_standMs.reset();
    bool const kept = !stand && m_standAccel;
    if (stand)
    {
      m_standAccel = stand;
      m_standAccelMs = now;
      m_standAccelPathM = pathM;
    }
    else if (now - m_standAccelMs > kKeepStandFeltMs || pathM - m_standAccelPathM > kKeepStandFeltM)
    {
      m_standAccel.reset();
    }
    auto const start = m_accel.GetAccelAlong(m_startStandToMs, now);
    if (m_standAccel && start)
    {
      double const feltMps = m_startFromMps + (*start - *m_standAccel) * (now - m_startStandToMs) / 1000.0;
      m_startFeltMps = feltMps;
      // An accelerometer that doesn't follow the car now may look the other way: a box put in turned around
      // feels every start backward.
      bool const usable = m_accel.IsUsable();
      if (m_startAfterSlow)
        direction = feltMps >= kReverseStartSpeedMps ? 1 : direction;
      else
        direction = feltMps <= -kReverseStartSpeedMps && usable ? -1 : 1;
      m_crawlCheck = !m_startAfterSlow && !kept && feltMps < kCrawlClearForwardMps;
      LOG(LINFO, ("The car has started", direction > 0 ? "forward" : "backward", "the accelerometer has felt", feltMps,
                  "m/s, standing", *m_standAccel, "starting", *start, "m/s2, it stood", stoodSec, "s",
                  m_startAfterSlow ? "after driving at 1 km/h, the stand before it is taken"
                  : kept           ? "too short, the stand before it is taken"
                                   : "",
                  usable ? "" : "the accelerometer is not usable, it doesn't tell a start backward"));
    }
    else
    {
      LOG(LINFO,
          ("The car has started, the accelerometer tells nothing: its direction is known =", m_accel.IsDirectionKnown(),
           "it stood", stoodSec, "s", m_startAfterSlow ? "after driving at 1 km/h, the way is kept" : ""));
    }
  }
  else if (m_startFelt && m_standAccel && now - *m_startMs <= kStartCheckMs)
  {
    // The car reports the speed it had the lag ago: what the accelerometer had felt by then is the same speed
    // with its sign. A crawling car told forward is checked by what was felt till now.
    bool const crawl = m_crawlCheck && speedKmh <= kCrawlSpeedKmh && direction > 0;
    int64_t const tillMs = crawl ? now : now - lagMs;
    int64_t const checkBackMs = crawl ? kCrawlCheckBackMs : kStartCheckBackMs;
    auto const start = m_accel.GetAccelAlong(m_startStandToMs, tillMs);
    double const feltMps = start ? m_startFromMps + (*start - *m_standAccel) * (tillMs - m_startStandToMs) / 1000.0 : 0;
    double const speedMps = speedKmh / 3.6;
    m_startFeltMps = feltMps;
    int const felt = feltMps < 0 ? -1 : 1;
    bool const clear = std::fabs(feltMps) >= std::max(kReverseStartSpeedMps, kMinFeltSpeedRatio * speedMps) &&
                       std::fabs(feltMps) <= kMaxFeltSpeedRatio * speedMps + kMaxFeltSpeedExtraMps;
    if (!clear || felt == direction ||
        (felt < 0 && (now - *m_startMs > checkBackMs || m_startAfterSlow || !m_accel.IsUsable())))
    {
      m_otherWayMs.reset();
    }
    else if (!m_otherWayMs)
    {
      m_otherWayMs = now;
    }
    else if (now - *m_otherWayMs >= kStartCheckHoldMs)
    {
      m_otherWayMs.reset();
      direction = felt;
      LOG(LINFO, ("The car drives", direction > 0 ? "forward" : "backward", "by the accelerometer, it has felt",
                  feltMps, "m/s and the car reports", speedMps, "m/s,", now - *m_startMs, "ms after the start and",
                  std::round(m_startM), "m", crawl ? "crawling, felt till now" : ""));
    }
  }
  // Nobody drives that fast backwards.
  if (speedKmh >= kMaxBackSpeedKmh && direction < 0)
  {
    LOG(LINFO, ("The car drives fast: it has driven forward since the start,", std::round(m_startM), "m"));
    direction = 1;
  }
  SetDirection(direction);
}

void DirectionTracker::SetDirection(int direction)
{
  if (direction == m_direction)
    return;
  // What the car has driven since the start was counted the other way.
  m_moveStartSegment(direction - m_direction);
  m_direction = direction;
  if (direction < 0)
    m_forgetWay();
}

void DirectionTracker::StartStopCheck()
{
  // The car has reported 0 the lag after it stood.
  int64_t const lagMs = static_cast<int64_t>(m_lag.Get() * 1000);
  m_stopCheck.reset();
  if (!m_startMs || !m_startFelt || m_startAfterSlow || m_startM <= 0 || m_startM > kStopCheckMaxM ||
      m_segMaxKmh > kStopCheckMaxKmh)
  {
    return;
  }
  // A start felt clearly the way it was told is not turned.
  if (m_direction * m_startFeltMps >= kCrawlClearForwardMps)
    return;
  int64_t const stopMs = m_clock.NowMs() - lagMs;
  // The speed of the car falls from its top one: before that the car speeds up.
  m_stopCheck = StopCheck{m_direction, stopMs, std::max(stopMs - kStopBrakeMs, m_segPeakMs - lagMs), m_segMaxKmh / 3.6};
}

void DirectionTracker::CheckStop()
{
  if (!m_stopCheck)
    return;
  auto const check = *m_stopCheck;
  int64_t const now = m_clock.NowMs();
  int64_t const standFromMs = check.m_stopMs + kStandMarginMs;
  if (now - standFromMs < kMinStandFeltMs)
    return;
  m_stopCheck.reset();
  if (check.m_stopMs - check.m_brakeFromMs < kMinStandFeltMs || !m_accel.IsUsable())
    return;
  auto const stand = m_accel.GetAccelAlong(standFromMs, now);
  auto const brake = m_accel.GetAccelAlong(check.m_brakeFromMs, check.m_stopMs);
  if (!stand || !brake)
    return;
  // The car driving forward loses its speed: what was felt is negative, backward positive.
  double const feltMps = (*brake - *stand) * (check.m_stopMs - check.m_brakeFromMs) / 1000.0;
  int const way = feltMps < 0 ? 1 : -1;
  if (way == check.m_way || std::fabs(feltMps) < kStopFeltSpeedMps ||
      std::fabs(feltMps) > kMaxFeltSpeedRatio * check.m_peakMps + kMaxFeltSpeedExtraMps)
  {
    return;
  }
  LOG(LINFO, ("The car has stopped after driving", check.m_way > 0 ? "forward" : "backward", "the stop was felt",
              feltMps, "m/s: the segment is turned", std::round(m_startM), "m"));
  m_moveStartSegment(way - check.m_way);
  if (way < 0)
    m_lastBackMs = now;
  m_forgetWay();
}

void DirectionTracker::Reset()
{
  m_direction = 1;
  m_standMs.reset();
  m_startMs.reset();
  m_fasterSinceStart = false;
  m_slowMs.reset();
  m_startAfterSlow = false;
  m_standAccel.reset();
  m_otherWayMs.reset();
  m_startFelt = true;
  m_crawlCheck = false;
  m_startM = 0;
  m_startMarkM = 0;
  m_stopCheck.reset();
}

bool DirectionTracker::HasDrivenBackLately() const
{
  return m_lastBackMs && m_clock.NowMs() - *m_lastBackMs < kAccelAfterBackMs;
}
}  // namespace nogps
