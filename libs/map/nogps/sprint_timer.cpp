#include "map/nogps/sprint_timer.hpp"

#include "base/assert.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>

namespace nogps
{
std::string DebugPrint(SprintKind kind)
{
  switch (kind)
  {
  case SprintKind::To100: return "to100";
  case SprintKind::QuarterMile: return "quarter";
  }
  UNREACHABLE();
}

std::string SerializeSprint(Sprint const & sprint)
{
  return DebugPrint(sprint.m_kind) + ":" + std::to_string(sprint.m_unixTimeMs) + ":" +
         std::to_string(std::lround(sprint.m_sec * 100)) + ":" + std::to_string(sprint.m_trapKmh);
}

std::vector<Sprint> ParseSprints(std::string_view sprints)
{
  std::vector<Sprint> result;
  strings::Tokenize(sprints, ",", [&result](std::string_view item)
  {
    std::vector<std::string_view> fields;
    strings::Tokenize(item, ":", [&fields](std::string_view field) { fields.push_back(field); });
    if (fields.size() != 4)
      return;
    Sprint sprint;
    if (fields[0] == DebugPrint(SprintKind::To100))
      sprint.m_kind = SprintKind::To100;
    else if (fields[0] == DebugPrint(SprintKind::QuarterMile))
      sprint.m_kind = SprintKind::QuarterMile;
    else
      return;
    int centisec = 0;
    if (!strings::to_int(fields[1], sprint.m_unixTimeMs) || !strings::to_int(fields[2], centisec) ||
        !strings::to_int(fields[3], sprint.m_trapKmh))
    {
      return;
    }
    sprint.m_sec = centisec / 100.0;
    result.push_back(sprint);
  });
  return result;
}

std::vector<SprintTimer::Result> SprintTimer::OnSample(double kmh, int64_t timeMs)
{
  std::vector<Result> results;
  auto const raw = m_raw;
  if (raw && (timeMs <= raw->m_timeMs || (kmh == raw->m_kmh && timeMs - raw->m_timeMs < kMinSampleGapMs)))
    return results;
  m_raw = Sample{kmh, timeMs};
  if (!raw || timeMs - raw->m_timeMs > kSpeedStaleMs)
  {
    m_window.clear();
    m_last.reset();
    m_run.reset();
  }
  m_window.push_back(*m_raw);
  if (m_window.size() < 3)
    return results;
  if (m_window.size() > 3)
    m_window.erase(m_window.begin());

  // A single 0 before the speed rises is the start, though the median of it is not 0.
  if (!m_run && m_window[0].m_kmh <= 0 && m_window[1].m_kmh > 0 && m_window[2].m_kmh >= m_window[1].m_kmh)
    OnFilteredSample(0, m_window[0].m_timeMs);

  // The median of three drops a bad sample of the car speed, it is told at the time of the middle one.
  double const median = std::max(std::min(m_window[0].m_kmh, m_window[1].m_kmh),
                                 std::min(std::max(m_window[0].m_kmh, m_window[1].m_kmh), m_window[2].m_kmh));
  return OnFilteredSample(median, m_window[1].m_timeMs);
}

std::vector<SprintTimer::Result> SprintTimer::OnFilteredSample(double kmh, int64_t timeMs)
{
  std::vector<Result> results;
  auto const last = m_last;
  m_last = Sample{kmh, timeMs};
  if (kmh <= 0)
  {
    m_run = Run{.m_startMs = timeMs};
    return results;
  }
  if (!m_run || !last)
    return results;

  // The speed changes evenly between the samples.
  double const dtSec = (timeMs - last->m_timeMs) / 1000.0;
  double const v0 = last->m_kmh / 3.6;
  double const accelMps2 = (kmh - last->m_kmh) / 3.6 / dtSec;
  double const segmentM = (v0 + kmh / 3.6) / 2 * dtSec;
  double const lastSec = (last->m_timeMs - m_run->m_startMs) / 1000.0;

  if (!m_run->m_to100Done && last->m_kmh < kTo100Kmh && kmh >= kTo100Kmh)
  {
    m_run->m_to100Done = true;
    double const sec = lastSec + (kTo100Kmh - last->m_kmh) / (kmh - last->m_kmh) * dtSec;
    if (sec <= kSprintMaxSec)
      results.push_back({SprintKind::To100, sec, 0});
  }
  if (!m_run->m_quarterDone && m_run->m_distanceM + segmentM >= kQuarterMileM)
  {
    m_run->m_quarterDone = true;
    // v0 * t + a * t^2 / 2 = the distance left.
    double const leftM = kQuarterMileM - m_run->m_distanceM;
    double t = std::abs(accelMps2) < 1e-9
                 ? leftM / v0
                 : (std::sqrt(std::max(0.0, v0 * v0 + 2 * accelMps2 * leftM)) - v0) / accelMps2;
    t = std::clamp(t, 0.0, dtSec);
    double const sec = lastSec + t;
    double const trapKmh = (v0 + accelMps2 * t) * 3.6;
    if (sec <= kQuarterMaxSec && trapKmh >= kQuarterMinTrapKmh)
      results.push_back({SprintKind::QuarterMile, sec, trapKmh});
  }
  m_run->m_distanceM += segmentM;
  m_run->m_maxKmh = std::max(m_run->m_maxKmh, kmh);
  bool const finished = (m_run->m_to100Done && m_run->m_quarterDone) || lastSec + dtSec > kQuarterMaxSec;
  if (finished || kmh <= m_run->m_maxKmh - kSprintDropKmh)
    m_run.reset();
  return results;
}
}  // namespace nogps
