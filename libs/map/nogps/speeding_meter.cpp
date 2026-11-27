#include "map/nogps/speeding_meter.hpp"

#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>

namespace nogps
{
namespace
{
double ScoreOf(double weightedS, double ratedS)
{
  if (ratedS <= 0)
    return 100;
  double const perHour = weightedS / (ratedS / 3600);
  return std::round(100 * std::exp(-perHour / SpeedingMeter::kScoreScaleS));
}

std::string SerializeEpisode(SpeedingEpisode const & e)
{
  return std::to_string(e.m_unixTimeMs) + "," + std::to_string(std::lround(e.m_durationS * 10)) + "," +
         std::to_string(std::lround(e.m_distanceM)) + "," + std::to_string(e.m_limitKmh) + "," +
         std::to_string(e.m_peakKmh) + "," + std::to_string(e.m_meanKmh) + "," + std::to_string(e.m_band);
}

std::vector<std::string_view> Split(std::string_view s, char separator)
{
  std::vector<std::string_view> parts;
  strings::Tokenize(s, std::string(1, separator).c_str(), [&parts](std::string_view part) { parts.push_back(part); });
  return parts;
}

std::optional<SpeedingEpisode> ParseEpisode(std::string_view s)
{
  auto const fields = Split(s, ',');
  if (fields.size() != 7)
    return {};
  SpeedingEpisode e;
  int64_t durationDs = 0;
  int64_t distanceM = 0;
  if (!strings::to_int(fields[0], e.m_unixTimeMs) || !strings::to_int(fields[1], durationDs) ||
      !strings::to_int(fields[2], distanceM) || !strings::to_int(fields[3], e.m_limitKmh) ||
      !strings::to_int(fields[4], e.m_peakKmh) || !strings::to_int(fields[5], e.m_meanKmh) ||
      !strings::to_int(fields[6], e.m_band) || e.m_band < 1 || e.m_band > 3)
  {
    return {};
  }
  e.m_durationS = durationDs / 10.0;
  e.m_distanceM = static_cast<double>(distanceM);
  return e;
}

std::optional<SpeedingTrip> ParseTrip(std::string_view s)
{
  auto const slash = s.find('/');
  auto const head = Split(s.substr(0, slash), ':');
  if (head.size() != 4)
    return {};
  SpeedingTrip trip;
  int64_t ratedM = 0;
  int64_t ratedS = 0;
  int64_t weightedDs = 0;
  if (!strings::to_int(head[0], trip.m_unixTimeMs) || !strings::to_int(head[1], ratedM) ||
      !strings::to_int(head[2], ratedS) || !strings::to_int(head[3], weightedDs))
  {
    return {};
  }
  trip.m_ratedM = static_cast<double>(ratedM);
  trip.m_ratedS = static_cast<double>(ratedS);
  trip.m_weightedS = weightedDs / 10.0;
  if (slash != std::string_view::npos)
    for (auto const episode : Split(s.substr(slash + 1), ';'))
      if (auto const parsed = ParseEpisode(episode))
        trip.m_episodes.push_back(*parsed);
  return trip;
}
}  // namespace

std::array<int, 3> SpeedingTrip::GetBandCounts() const
{
  std::array<int, 3> counts = {};
  for (auto const & episode : m_episodes)
    ++counts[episode.m_band - 1];
  return counts;
}

int SpeedingTrip::GetScore() const
{
  return static_cast<int>(ScoreOf(m_weightedS, m_ratedS));
}

std::string SerializeSpeedingTrip(SpeedingTrip const & trip)
{
  std::string result = std::to_string(trip.m_unixTimeMs) + ":" + std::to_string(std::lround(trip.m_ratedM)) + ":" +
                       std::to_string(std::lround(trip.m_ratedS)) + ":" +
                       std::to_string(std::lround(trip.m_weightedS * 10)) + "/";
  for (size_t i = 0; i < trip.m_episodes.size(); ++i)
    result += (i == 0 ? "" : ";") + SerializeEpisode(trip.m_episodes[i]);
  return result;
}

std::string SerializeSpeedingTrips(std::vector<SpeedingTrip> const & trips)
{
  std::string result;
  for (size_t i = 0; i < trips.size(); ++i)
    result += (i == 0 ? "" : "|") + SerializeSpeedingTrip(trips[i]);
  return result;
}

std::vector<SpeedingTrip> ParseSpeedingTrips(std::string_view trips)
{
  std::vector<SpeedingTrip> result;
  for (auto const item : Split(trips, '|'))
    if (auto const trip = ParseTrip(item))
      result.push_back(*trip);
  return result;
}

DrivingRating RateDriving(std::vector<SpeedingTrip> const & trips)
{
  DrivingRating rating;
  double weightedS = 0;
  double ratedS = 0;
  double ratedM = 0;
  for (auto it = trips.rbegin(); it != trips.rend(); ++it)
  {
    rating.m_trips.push_back(*it);
    if (ratedM >= SpeedingMeter::kScoreWindowKm * 1000)
      continue;
    weightedS += it->m_weightedS;
    ratedS += it->m_ratedS;
    ratedM += it->m_ratedM;
    auto const counts = it->GetBandCounts();
    for (size_t i = 0; i < counts.size(); ++i)
      rating.m_bandCounts[i] += counts[i];
  }
  rating.m_ratedKm = ratedM / 1000;
  rating.m_enough = rating.m_ratedKm >= SpeedingMeter::kScoreMinKm;
  rating.m_score = static_cast<int>(ScoreOf(weightedS, ratedS));
  return rating;
}

void SpeedingMeter::Stretch::Add(double kmh, int limitKmh, int64_t dtMs, int64_t timeMs)
{
  m_endMs = timeMs;
  m_durationMs += dtMs;
  m_distanceM += kmh / 3.6 * dtMs / 1000.0;
  m_kmhMs += kmh * dtMs;
  if (kmh - limitKmh > m_peakExcessKmh)
  {
    m_peakExcessKmh = kmh - limitKmh;
    m_peakKmh = kmh;
    m_limitKmh = limitKmh;
  }
}

void SpeedingMeter::Stretch::Merge(Stretch const & other)
{
  m_endMs = other.m_endMs;
  m_durationMs += other.m_durationMs;
  m_distanceM += other.m_distanceM;
  m_kmhMs += other.m_kmhMs;
  if (other.m_peakExcessKmh > m_peakExcessKmh)
  {
    m_peakExcessKmh = other.m_peakExcessKmh;
    m_peakKmh = other.m_peakKmh;
    m_limitKmh = other.m_limitKmh;
  }
}

// static
int SpeedingMeter::GetBand(double excessKmh)
{
  if (excessKmh >= kBand3Kmh)
    return 3;
  return excessKmh >= kBand2Kmh ? 2 : 1;
}

std::vector<SpeedingEpisode> SpeedingMeter::OnSample(Sample const & sample)
{
  std::vector<SpeedingEpisode> finished;
  bool const gap = !m_prevMs || sample.m_timeMs <= *m_prevMs || sample.m_timeMs - *m_prevMs > kMaxGapMs;
  int64_t const dtMs = gap ? 0 : sample.m_timeMs - *m_prevMs;
  m_prevMs = sample.m_timeMs;
  bool const rated = sample.m_kmh && *sample.m_kmh >= kMinRatedKmh && sample.m_limitKmh > 0 && sample.m_trusted;
  m_rated = rated;
  if (gap)
  {
    EndRated(finished);
    m_limit.reset();
    m_lowerLimitM = 0;
  }
  else if (!rated)
  {
    EndRated(finished);
  }
  if (rated)
    OnRated(sample, dtMs, finished);
  Release(sample.m_timeMs, finished);
  return finished;
}

void SpeedingMeter::UpdateLimit(int limitKmh, double distanceM)
{
  if (!m_limit || limitKmh > *m_limit)
  {
    m_limit = limitKmh;
    m_lowerLimitM = 0;
  }
  else if (limitKmh == *m_limit)
  {
    m_lowerLimitM = 0;
  }
  else
  {
    m_lowerLimitM += distanceM;
    if (m_lowerLimitM >= kLowerLimitGraceM)
    {
      m_limit = limitKmh;
      m_lowerLimitM = 0;
    }
  }
}

void SpeedingMeter::OnRated(Sample const & sample, int64_t dtMs, std::vector<SpeedingEpisode> & finished)
{
  double const kmh = *sample.m_kmh;
  if (!m_trip.m_unixTimeMs)
    m_trip.m_unixTimeMs = sample.m_unixTimeMs;
  double const distanceM = kmh / 3.6 * dtMs / 1000.0;
  m_trip.m_ratedM += distanceM;
  m_trip.m_ratedS += dtMs / 1000.0;
  UpdateLimit(sample.m_limitKmh, distanceM);
  int const limit = *m_limit;
  double const excess = kmh - limit;
  int64_t const now = sample.m_timeMs;

  if (!m_confirmed)
  {
    if (excess <= kSpeedingToleranceKmh)
    {
      m_over.reset();
      return;
    }
    if (!m_over)
    {
      m_over = Stretch{};
      m_over->m_startMs = now;
      m_over->m_unixTimeMs = sample.m_unixTimeMs;
    }
    m_over->Add(kmh, limit, dtMs, now);
    if (m_over->m_durationMs >= kSpeedingStartS * 1000)
    {
      m_confirmed = true;
      m_under.reset();
    }
    return;
  }

  if (excess >= kSpeedingToleranceKmh - kSpeedingHysteresisKmh)
  {
    if (m_under)
    {
      m_over->Merge(*m_under);
      m_under.reset();
    }
    m_over->Add(kmh, limit, dtMs, now);
    return;
  }
  if (!m_under)
  {
    m_under = Stretch{};
    m_under->m_startMs = now;
  }
  m_under->Add(kmh, limit, dtMs, now);
  if (now - m_under->m_startMs >= kSpeedingEndS * 1000)
    FinishEpisode(finished);
}

void SpeedingMeter::EndRated(std::vector<SpeedingEpisode> & finished)
{
  if (m_confirmed)
    FinishEpisode(finished);
  m_over.reset();
  m_under.reset();
  m_confirmed = false;
}

void SpeedingMeter::FinishEpisode(std::vector<SpeedingEpisode> & finished)
{
  Stretch const done = *m_over;
  m_over.reset();
  m_under.reset();
  m_confirmed = false;
  if (m_held && done.m_startMs - m_held->m_endMs <= kSpeedingMergeS * 1000)
  {
    m_held->Merge(done);
    return;
  }
  if (m_held)
    Emit(*m_held, finished);
  m_held = done;
}

void SpeedingMeter::Emit(Stretch const & stretch, std::vector<SpeedingEpisode> & finished)
{
  SpeedingEpisode episode;
  episode.m_unixTimeMs = stretch.m_unixTimeMs;
  episode.m_durationS = stretch.m_durationMs / 1000.0;
  episode.m_distanceM = stretch.m_distanceM;
  episode.m_limitKmh = stretch.m_limitKmh;
  episode.m_peakKmh = static_cast<int>(std::lround(stretch.m_peakKmh));
  episode.m_meanKmh = static_cast<int>(std::lround(
      stretch.m_durationMs > 0 ? stretch.m_kmhMs / static_cast<double>(stretch.m_durationMs) : stretch.m_peakKmh));
  episode.m_band = GetBand(stretch.m_peakExcessKmh);
  m_trip.m_weightedS += kBandWeights[episode.m_band - 1] * episode.m_durationS;
  m_trip.m_episodes.push_back(episode);
  finished.push_back(episode);
}

void SpeedingMeter::Release(int64_t nowMs, std::vector<SpeedingEpisode> & finished)
{
  if (!m_held || nowMs - m_held->m_endMs <= kSpeedingMergeS * 1000)
    return;
  // An episode that has started within the time may continue it, when it is confirmed.
  if (m_over && m_over->m_startMs - m_held->m_endMs <= kSpeedingMergeS * 1000)
    return;
  Emit(*m_held, finished);
  m_held.reset();
}

std::vector<SpeedingEpisode> SpeedingMeter::Flush()
{
  std::vector<SpeedingEpisode> finished;
  EndRated(finished);
  if (m_held)
  {
    Emit(*m_held, finished);
    m_held.reset();
  }
  return finished;
}

std::optional<SpeedingTrip> SpeedingMeter::CloseTrip()
{
  std::optional<SpeedingTrip> trip;
  if (m_trip.m_ratedS > 0)
    trip = std::move(m_trip);
  m_trip = {};
  m_prevMs.reset();
  m_rated = false;
  m_limit.reset();
  m_lowerLimitM = 0;
  return trip;
}
}  // namespace nogps
