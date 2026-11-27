#include "testing/testing.hpp"

#include "map/nogps/speeding_meter.hpp"

#include <cstdint>
#include <optional>
#include <vector>

namespace nogps_speeding_tests
{
using namespace nogps;

int64_t constexpr kStartMs = 100'000;

/// Feeds the meter one sample at a time and keeps what it finishes.
struct Driver
{
  SpeedingMeter m_meter;
  std::vector<SpeedingEpisode> m_episodes;
  int64_t m_nowMs = kStartMs;

  void Sample(std::optional<double> kmh, int limit, bool trusted = true, int64_t dtMs = 1000)
  {
    m_nowMs += dtMs;
    SpeedingMeter::Sample sample;
    sample.m_timeMs = m_nowMs;
    sample.m_unixTimeMs = 1'700'000'000'000 + m_nowMs;
    sample.m_kmh = kmh;
    sample.m_limitKmh = limit;
    sample.m_trusted = trusted;
    auto const done = m_meter.OnSample(sample);
    m_episodes.insert(m_episodes.end(), done.begin(), done.end());
  }

  void Drive(int seconds, double kmh, int limit, bool trusted = true)
  {
    for (int i = 0; i < seconds; ++i)
      Sample(kmh, limit, trusted);
  }

  void Flush()
  {
    auto const done = m_meter.Flush();
    m_episodes.insert(m_episodes.end(), done.begin(), done.end());
  }
};

UNIT_TEST(NoGps_SpeedingMeter_StandingIsNotRated)
{
  Driver d;
  d.Drive(10, 60, 60);
  d.Drive(100, 0, 60);
  d.Drive(10, 60, 60);
  TEST_ALMOST_EQUAL_ABS(d.m_meter.GetTrip().m_ratedS, 19.0, 1.01, ());
}

UNIT_TEST(NoGps_SpeedingMeter_StartsAfterThreeSeconds)
{
  Driver d;
  d.Drive(5, 60, 60);
  // 2.9 s over the tolerance, then back.
  d.Sample(85, 60);
  d.Sample(85, 60, true, 1000);
  d.Sample(85, 60, true, 900);
  d.Drive(10, 60, 60);
  d.Flush();
  TEST(d.m_episodes.empty(), ());

  Driver e;
  e.Drive(5, 60, 60);
  e.Drive(4, 85, 60);
  e.Drive(10, 60, 60);
  e.Flush();
  TEST_EQUAL(e.m_episodes.size(), 1, ());
  TEST_EQUAL(e.m_episodes[0].m_limitKmh, 60, ());
  TEST_EQUAL(e.m_episodes[0].m_peakKmh, 85, ());
  TEST_ALMOST_EQUAL_ABS(e.m_episodes[0].m_durationS, 3.0, 1.01, ());

  // 80 on 60 is the tolerance, not over it.
  Driver f;
  f.Drive(20, 80, 60);
  f.Flush();
  TEST(f.m_episodes.empty(), ());
}

UNIT_TEST(NoGps_SpeedingMeter_HysteresisKeepsEpisode)
{
  Driver d;
  d.Drive(4, 90, 60);
  // 78 is above limit + 17: the episode goes on, 2 s are not enough to end it.
  d.Drive(5, 78, 60);
  d.Drive(1, 60, 60);
  d.Drive(4, 90, 60);
  d.Drive(10, 60, 60);
  d.Flush();
  TEST_EQUAL(d.m_episodes.size(), 1, ());
  TEST_GREATER(d.m_episodes[0].m_durationS, 12, ());
}

UNIT_TEST(NoGps_SpeedingMeter_MergesEpisodesCloserThanFiveSeconds)
{
  for (int gap : {4, 6})
  {
    Driver d;
    d.Drive(5, 90, 60);
    d.Drive(gap - 1, 60, 60);
    d.Drive(5, 90, 60);
    d.Drive(10, 60, 60);
    d.Flush();
    TEST_EQUAL(d.m_episodes.size(), gap == 4 ? 1 : 2, (gap));
  }
}

UNIT_TEST(NoGps_SpeedingMeter_LowerLimitCountsAfter150M)
{
  // 100 km/h under a limit that drops to 50: 27.8 m/s, the new limit is in force after 6 s.
  Driver d;
  d.Drive(5, 100, 100);
  d.Drive(5, 100, 50);
  d.Drive(10, 100, 100);
  d.Flush();
  TEST(d.m_episodes.empty(), ());

  Driver slow;
  slow.Drive(5, 100, 100);
  slow.Drive(20, 100, 50);
  slow.Flush();
  TEST_EQUAL(slow.m_episodes.size(), 1, ());
  TEST_EQUAL(slow.m_episodes[0].m_limitKmh, 50, ());

  // A higher limit is in force at once: 80 under a limit raised from 50 to 100 is not speeding, and the other way.
  Driver high;
  high.Drive(5, 50, 50);
  high.Drive(10, 90, 100);
  high.Flush();
  TEST(high.m_episodes.empty(), ());
}

UNIT_TEST(NoGps_SpeedingMeter_CrossingRoadWithLowerLimitIsIgnored)
{
  Driver d;
  d.Drive(10, 80, 80);
  // 30 m at 60 km/h is 2 s on a crossing road with a limit of 30.
  d.Drive(2, 60, 30);
  d.Drive(10, 80, 80);
  d.Flush();
  TEST(d.m_episodes.empty(), ());
}

UNIT_TEST(NoGps_SpeedingMeter_UnratedDrivingEndsEpisode)
{
  // No limit, an unknown one, no speed and an untrusted mark are not rated.
  struct Case
  {
    std::optional<double> m_kmh;
    int m_limit;
    bool m_trusted;
  };
  for (Case const & c : {Case{90, 0, true}, Case{90, -1, true}, Case{std::nullopt, 60, true}, Case{90, 60, false}})
  {
    Driver d;
    d.Drive(5, 90, 60);
    for (int i = 0; i < 3; ++i)
      d.Sample(c.m_kmh, c.m_limit, c.m_trusted);
    // The episode is over at the first unrated second, and written after the wait for its continuation.
    TEST_EQUAL(d.m_episodes.size(), 0, ());
    d.Drive(10, 60, 60);
    TEST_EQUAL(d.m_episodes.size(), 1, ());
    TEST_ALMOST_EQUAL_ABS(d.m_episodes[0].m_durationS, 4.0, 1.01, ());

    auto const & trip = d.m_meter.GetTrip();
    // 5 s of the first rating and 10 of the last, the unrated 3 s are not counted.
    TEST_ALMOST_EQUAL_ABS(trip.m_ratedS, 14.0, 1.01, ());
  }
}

UNIT_TEST(NoGps_SpeedingMeter_Bands)
{
  TEST_EQUAL(SpeedingMeter::GetBand(25), 1, ());
  TEST_EQUAL(SpeedingMeter::GetBand(39.9), 1, ());
  TEST_EQUAL(SpeedingMeter::GetBand(40), 2, ());
  TEST_EQUAL(SpeedingMeter::GetBand(59), 2, ());
  TEST_EQUAL(SpeedingMeter::GetBand(60), 3, ());

  Driver d;
  d.Drive(5, 100, 50);
  d.Drive(5, 60, 50);
  d.Drive(5, 130, 50);
  d.Drive(10, 50, 50);
  d.Flush();
  TEST_EQUAL(d.m_episodes.size(), 2, ());
  TEST_EQUAL(d.m_episodes[0].m_band, 2, ());
  TEST_EQUAL(d.m_episodes[1].m_band, 3, ());
  auto const & trip = d.m_meter.GetTrip();
  TEST_EQUAL(trip.GetBandCounts(), (std::array<int, 3>{0, 1, 1}), ());
  double const expected = 3 * d.m_episodes[0].m_durationS + 8 * d.m_episodes[1].m_durationS;
  TEST_ALMOST_EQUAL_ABS(trip.m_weightedS, expected, 1e-6, ());
}

UNIT_TEST(NoGps_SpeedingMeter_ScoreAndWindow)
{
  // One minute of +20...40 in an hour of rated driving: 85. Five minutes: 43. Ten: 19.
  auto const score = [](double minutes)
  {
    SpeedingTrip trip;
    trip.m_ratedS = 3600;
    trip.m_ratedM = 80'000;
    trip.m_weightedS = minutes * 60;
    return trip.GetScore();
  };
  TEST_EQUAL(score(0), 100, ());
  TEST_EQUAL(score(1), 85, ());
  TEST_EQUAL(score(5), 43, ());
  TEST_EQUAL(score(10), 19, ());

  // The newest trips that add up to 500 km count: the old bad one is outside of them.
  std::vector<SpeedingTrip> trips;
  SpeedingTrip bad;
  bad.m_ratedM = 100'000;
  bad.m_ratedS = 3600;
  bad.m_weightedS = 1800;
  trips.push_back(bad);
  for (int i = 0; i < 5; ++i)
  {
    SpeedingTrip good;
    good.m_ratedM = 100'000;
    good.m_ratedS = 3600;
    trips.push_back(good);
  }
  auto const rating = RateDriving(trips);
  TEST(rating.m_enough, ());
  TEST_EQUAL(rating.m_score, 100, ());
  TEST_ALMOST_EQUAL_ABS(rating.m_ratedKm, 500.0, 1e-6, ());
  TEST_EQUAL(rating.m_trips.size(), 6, ());

  // Under 20 km there is not enough driving.
  SpeedingTrip shortTrip;
  shortTrip.m_ratedM = 19'000;
  shortTrip.m_ratedS = 900;
  TEST(!RateDriving({shortTrip}).m_enough, ());
  shortTrip.m_ratedM = 20'000;
  TEST(RateDriving({shortTrip}).m_enough, ());
}

UNIT_TEST(NoGps_SpeedingMeter_TripClosesAndRestarts)
{
  Driver d;
  TEST(!d.m_meter.CloseTrip(), ());

  d.Drive(10, 60, 60);
  d.Drive(5, 100, 60);
  d.Flush();
  auto const trip = d.m_meter.CloseTrip();
  TEST(trip.has_value(), ());
  TEST_EQUAL(trip->m_episodes.size(), 1, ());
  TEST_ALMOST_EQUAL_ABS(trip->m_ratedS, 14.0, 1.01, ());
  TEST_GREATER(trip->m_ratedM, 200, ());
  TEST(trip->m_unixTimeMs > 0, ());
  TEST(!d.m_meter.GetLimitKmh(), ());
  TEST_EQUAL(d.m_meter.GetTrip().m_episodes.size(), 0, ());
  TEST(!d.m_meter.CloseTrip(), ());
}

UNIT_TEST(NoGps_SpeedingMeter_StorageRoundTripAndCap)
{
  std::vector<SpeedingTrip> trips;
  for (int i = 0; i < 3; ++i)
  {
    SpeedingTrip trip;
    trip.m_unixTimeMs = 1'700'000'000'000 + i;
    trip.m_ratedM = 12'345 + i;
    trip.m_ratedS = 900 + i;
    trip.m_weightedS = 12.5;
    if (i != 1)
    {
      trip.m_episodes.push_back({trip.m_unixTimeMs + 5, 12.4, 310, 60, 94, 86, 1});
      trip.m_episodes.push_back({trip.m_unixTimeMs + 50, 3.0, 80, 50, 120, 110, 3});
    }
    trips.push_back(trip);
  }
  auto const saved = SerializeSpeedingTrips(trips);
  auto const loaded = ParseSpeedingTrips(saved);
  TEST_EQUAL(loaded.size(), 3, (saved));
  TEST_EQUAL(loaded[0].m_unixTimeMs, trips[0].m_unixTimeMs, ());
  TEST_EQUAL(loaded[2].m_ratedM, 12'347, ());
  TEST_ALMOST_EQUAL_ABS(loaded[2].m_weightedS, 12.5, 1e-9, ());
  TEST_EQUAL(loaded[1].m_episodes.size(), 0, ());
  TEST_EQUAL(loaded[0].m_episodes.size(), 2, ());
  auto const & e = loaded[0].m_episodes[0];
  TEST_ALMOST_EQUAL_ABS(e.m_durationS, 12.4, 1e-9, ());
  TEST_EQUAL(e.m_distanceM, 310, ());
  TEST_EQUAL(e.m_limitKmh, 60, ());
  TEST_EQUAL(e.m_peakKmh, 94, ());
  TEST_EQUAL(e.m_meanKmh, 86, ());
  TEST_EQUAL(e.m_band, 1, ());
  TEST_EQUAL(loaded[0].m_episodes[1].m_band, 3, ());

  // Broken items are dropped, the good ones stay.
  TEST_EQUAL(ParseSpeedingTrips("junk|" + SerializeSpeedingTrip(trips[0]) + "|1:2:3").size(), 1, ());
  TEST(ParseSpeedingTrips("").empty(), ());
}
}  // namespace nogps_speeding_tests
