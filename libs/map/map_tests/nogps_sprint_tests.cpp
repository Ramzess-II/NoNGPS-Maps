#include "testing/testing.hpp"

#include "map/nogps/sprint_timer.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <optional>
#include <utility>
#include <vector>

namespace nogps_sprint_tests
{
using namespace nogps;

using Results = std::vector<SprintTimer::Result>;
using Profile = std::function<double(double /* sec */)>;

int64_t constexpr kStartMs = 100'000;

/// The real speed of |kmh| 10 times a second from |fromSec| to |toSec|, the run may start at 0 s.
Results Feed(SprintTimer & timer, Profile const & kmh, double fromSec, double toSec)
{
  Results results;
  for (int i = static_cast<int>(std::lround(fromSec * 10)); i <= std::lround(toSec * 10); ++i)
  {
    auto const sampleResults = timer.OnSample(kmh(i / 10.0), kStartMs + i * 100);
    results.insert(results.end(), sampleResults.begin(), sampleResults.end());
  }
  return results;
}

Results Run(Profile const & kmh, double toSec = 40)
{
  SprintTimer timer;
  return Feed(timer, kmh, -2, toSec);
}

std::optional<SprintTimer::Result> Find(Results const & results, SprintKind kind)
{
  auto const it =
      std::find_if(results.begin(), results.end(), [kind](SprintTimer::Result const & r) { return r.m_kind == kind; });
  if (it == results.end())
    return {};
  return *it;
}

/// Stands until 0 s, reaches 100 km/h in |to100Sec| evenly, then gains |thenKmhPerSec|.
Profile Accelerate(double to100Sec, double thenKmhPerSec)
{
  return [=](double t)
  {
    if (t <= 0)
      return 0.0;
    if (t <= to100Sec)
      return 100 * t / to100Sec;
    return 100 + thenKmhPerSec * (t - to100Sec);
  };
}

/// Stands until 0 s, reaches |kmh| in |sec| evenly and keeps it.
Profile AccelerateTo(double kmh, double sec)
{
  return [=](double t) { return std::clamp(kmh * t / sec, 0.0, kmh); };
}

/// The time and the speed at the end of the quarter mile of |kmh|, integrated finely.
std::pair<double, double> QuarterMileOf(Profile const & kmh)
{
  double distanceM = 0;
  double constexpr kDt = 0.0001;
  double t = 0;
  while (distanceM < SprintTimer::kQuarterMileM)
  {
    distanceM += (kmh(t) + kmh(t + kDt)) / 2 / 3.6 * kDt;
    t += kDt;
  }
  return {t, kmh(t)};
}

UNIT_TEST(NoGps_Sprint_To100Measured)
{
  // 100 km/h comes between the samples of 8.4 and 8.5 s.
  auto const results = Run(Accelerate(8.43, 100 / 8.43));
  auto const to100 = Find(results, SprintKind::To100);
  TEST(to100, ());
  TEST_ALMOST_EQUAL_ABS(to100->m_sec, 8.43, 1e-6, ());
  TEST_EQUAL(to100->m_trapKmh, 0, ());

  // The speed starts rising between the samples: the run is timed from the last 0 km/h.
  auto const late = Find(Run([](double t) { return std::max(0.0, 100 * (t - 0.05) / 8.4); }), SprintKind::To100);
  TEST(late, ());
  TEST_ALMOST_EQUAL_ABS(late->m_sec, 8.45, 1e-6, ());
}

UNIT_TEST(NoGps_Sprint_To100TooSlow)
{
  TEST(Find(Run(Accelerate(14.95, 100 / 14.95)), SprintKind::To100), ());
  TEST(!Find(Run(Accelerate(15.05, 100 / 15.05)), SprintKind::To100), ());
}

UNIT_TEST(NoGps_Sprint_OneRunGivesBoth)
{
  auto const profile = Accelerate(8.4, 4);
  auto const [sec, trapKmh] = QuarterMileOf(profile);
  SprintTimer timer;
  Feed(timer, profile, -2, 0);
  // Told at the sample after the one they are finished at: the speed is a median of three.
  std::vector<std::pair<int, SprintKind>> told;
  for (int i = 1; i <= 300; ++i)
    for (auto const & result : timer.OnSample(profile(i / 10.0), kStartMs + i * 100))
      told.emplace_back(i, result.m_kind);
  int const quarterSample = static_cast<int>(std::ceil(sec * 10)) + 1;
  TEST_EQUAL(
      told,
      (std::vector<std::pair<int, SprintKind>>{{85, SprintKind::To100}, {quarterSample, SprintKind::QuarterMile}}), ());

  auto const results = Run(profile);
  TEST_EQUAL(results.size(), 2, ());
  auto const quarter = Find(results, SprintKind::QuarterMile);
  TEST(quarter, ());
  // The distance is integrated by the samples, the time and the speed are interpolated between them.
  TEST_ALMOST_EQUAL_ABS(quarter->m_sec, sec, 0.01, ());
  TEST_ALMOST_EQUAL_ABS(quarter->m_trapKmh, trapKmh, 0.05, ());
}

UNIT_TEST(NoGps_Sprint_QuarterMileLimits)
{
  // Evenly, 25 s at most: the trap speed is over 100 km/h.
  auto const evenly = [](double sec)
  {
    double const accelKmhPerSec = 2 * SprintTimer::kQuarterMileM / (sec * sec) * 3.6;
    return [=](double t) { return std::max(0.0, accelKmhPerSec * t); };
  };
  auto const in249 = Find(Run(evenly(24.9)), SprintKind::QuarterMile);
  TEST(in249, ());
  TEST_ALMOST_EQUAL_ABS(in249->m_sec, 24.9, 0.01, ());
  TEST_GREATER(in249->m_trapKmh, 100, ());
  TEST(!Find(Run(evenly(25.1)), SprintKind::QuarterMile), ());

  // At 95 km/h by the end in 18 s: not a sprint.
  auto const slowTrap = Find(Run(AccelerateTo(101, 6)), SprintKind::QuarterMile);
  TEST(slowTrap, ());
  TEST_LESS(slowTrap->m_sec, 25, ());
  TEST(!Find(Run(AccelerateTo(95, 6)), SprintKind::QuarterMile), ());
}

UNIT_TEST(NoGps_Sprint_CruiseGivesNothing)
{
  // A normal start that cruises at 60 km/h covers the quarter mile in about 27 s.
  TEST(Run(AccelerateTo(60, 6)).empty(), ());
  TEST(Run(AccelerateTo(60, 6), 600).empty(), ());
}

UNIT_TEST(NoGps_Sprint_DropEndsRun)
{
  // To 80 km/h, down and on to 200 km/h.
  auto const dip = [](double dropKmh)
  {
    return [=](double t)
    {
      if (t <= 5)
        return std::max(0.0, 16 * t);
      if (t <= 6)
        return 80 - dropKmh * (t - 5);
      return 80 - dropKmh + 16 * (t - 6);
    };
  };
  TEST(Run(dip(7)).empty(), ());
  auto const results = Run(dip(3));
  TEST_EQUAL(results.size(), 2, ());
  auto const to100 = Find(results, SprintKind::To100);
  TEST(to100, ());
  TEST_ALMOST_EQUAL_ABS(to100->m_sec, 6 + 23 / 16.0, 1e-6, ());

  // A new run starts from the next standstill.
  SprintTimer timer;
  TEST(Feed(timer, dip(7), -2, 10).empty(), ());
  auto const again = Feed(timer, [](double t) { return std::max(0.0, 100 * (t - 12) / 9); }, 10.1, 40);
  auto const to100Again = Find(again, SprintKind::To100);
  TEST(to100Again, ());
  TEST_ALMOST_EQUAL_ABS(to100Again->m_sec, 9.0, 1e-6, ());
}

UNIT_TEST(NoGps_Sprint_SingleBadSampleIsIgnored)
{
  // The car speed at 5 Hz with one-sample dips and a spike, from the logs of 2026-11-23: 8 km/h per second.
  auto const feed = [](std::vector<int> const & dips, std::vector<int> const & spikes, double dipKmh = 7)
  {
    SprintTimer timer;
    Results results;
    for (int i = -4; i <= 120; ++i)
    {
      double kmh = std::max(0.0, 8.0 * i / 5.0);
      if (std::find(dips.begin(), dips.end(), i) != dips.end())
        kmh -= dipKmh;
      if (std::find(spikes.begin(), spikes.end(), i) != spikes.end())
        kmh += 20;
      auto const sampleResults = timer.OnSample(std::max(0.0, kmh), kStartMs + i * 200);
      results.insert(results.end(), sampleResults.begin(), sampleResults.end());
    }
    return results;
  };
  // 100 km/h comes at 12.5 s.
  auto const clean = Find(feed({}, {}), SprintKind::To100);
  TEST(clean, ());
  TEST_ALMOST_EQUAL_ABS(clean->m_sec, 12.5, 1e-6, ());
  auto const dipped = Find(feed({10, 22, 40}, {}), SprintKind::To100);
  TEST(dipped, ());
  TEST_ALMOST_EQUAL_ABS(dipped->m_sec, 12.5, 1e-6, ());
  // A spike over 100 km/h a second early is not the crossing.
  auto const spiked = Find(feed({}, {50}), SprintKind::To100);
  TEST(spiked, ());
  TEST_ALMOST_EQUAL_ABS(spiked->m_sec, 12.5, 1e-6, ());
  // Three dips in a row are a lift.
  TEST(!Find(feed({30, 31, 32}, {}, 15), SprintKind::To100), ());
}

UNIT_TEST(NoGps_Sprint_SingleZeroStartsRun)
{
  // One 0 after a roll, then a launch at 5 Hz: 100 km/h comes at 12.5 s after the 0.
  SprintTimer timer;
  Results results;
  for (int i = -10; i <= 120; ++i)
  {
    double const kmh = i < 0 ? 5.0 : std::max(i == 0 ? 0.0 : 4.0, 8.0 * i / 5.0);
    auto const r = timer.OnSample(kmh, kStartMs + i * 200);
    results.insert(results.end(), r.begin(), r.end());
  }
  auto const to100 = Find(results, SprintKind::To100);
  TEST(to100, ());
  TEST_ALMOST_EQUAL_ABS(to100->m_sec, 12.5, 0.2, ());
}

UNIT_TEST(NoGps_Sprint_SingleZeroAfterCreepRestartsRun)
{
  // A standstill, a creep of 3-5 km/h, one 0, then a launch at 5 Hz: 100 km/h comes at 12.5 s after that 0.
  std::vector<double> const creep = {0, 0, 0, 3, 5, 3, 0};
  SprintTimer timer;
  Results results;
  for (int i = -6; i <= 120; ++i)
  {
    double const kmh = i <= 0 ? creep[i + 6] : 8.0 * i / 5.0;
    auto const r = timer.OnSample(kmh, kStartMs + i * 200);
    results.insert(results.end(), r.begin(), r.end());
  }
  auto const to100 = Find(results, SprintKind::To100);
  TEST(to100, ());
  TEST_ALMOST_EQUAL_ABS(to100->m_sec, 12.5, 0.2, ());
}

UNIT_TEST(NoGps_Sprint_GapEndsRun)
{
  auto const profile = Accelerate(8, 4);
  SprintTimer timer;
  TEST(Feed(timer, profile, -2, 3).empty(), ());
  // Nothing is heard for over 2 s.
  TEST(Feed(timer, profile, 5.2, 40).empty(), ());

  // A shorter gap is interpolated over.
  SprintTimer gap;
  TEST(Feed(gap, profile, -2, 3).empty(), ());
  auto const results = Feed(gap, profile, 4.9, 40);
  auto const to100 = Find(results, SprintKind::To100);
  TEST(to100, ());
  TEST_ALMOST_EQUAL_ABS(to100->m_sec, 8.0, 1e-6, ());
}

UNIT_TEST(NoGps_Sprint_RollingStartIsNotRun)
{
  TEST(Run([](double t) { return 3 + std::max(0.0, 12 * t); }).empty(), ());
}

UNIT_TEST(NoGps_Sprint_RepeatedSampleIsIgnored)
{
  // The box repeats the last sample in its lines 50 times a second until the next one comes.
  auto const profile = Accelerate(8.43, 100 / 8.43);
  SprintTimer timer;
  Results results;
  for (int i = -20; i <= 300; ++i)
  {
    for (int repeat = 0; repeat < 5; ++repeat)
    {
      // The time of a repeated sample jitters by Bluetooth.
      auto const sampleResults = timer.OnSample(profile(i / 10.0), kStartMs + i * 100 + (repeat % 2) * 30);
      results.insert(results.end(), sampleResults.begin(), sampleResults.end());
    }
  }
  TEST_EQUAL(results.size(), 2, ());
  TEST_ALMOST_EQUAL_ABS(Find(results, SprintKind::To100)->m_sec, 8.43, 1e-6, ());
  TEST_ALMOST_EQUAL_ABS(Find(results, SprintKind::QuarterMile)->m_sec, QuarterMileOf(profile).first, 0.01, ());
}

UNIT_TEST(NoGps_Sprint_Serialized)
{
  std::vector<Sprint> const sprints = {{SprintKind::To100, 1'763'000'000'000, 8.43, 0},
                                       {SprintKind::QuarterMile, 1'763'000'009'000, 15.21, 142}};
  auto const serialized = SerializeSprint(sprints[0]) + "," + SerializeSprint(sprints[1]);
  TEST_EQUAL(serialized, "to100:1763000000000:843:0,quarter:1763000009000:1521:142", ());
  auto const parsed = ParseSprints(serialized);
  TEST_EQUAL(parsed.size(), 2, ());
  for (size_t i = 0; i < parsed.size(); ++i)
  {
    TEST_EQUAL(parsed[i].m_kind, sprints[i].m_kind, ());
    TEST_EQUAL(parsed[i].m_unixTimeMs, sprints[i].m_unixTimeMs, ());
    TEST_ALMOST_EQUAL_ABS(parsed[i].m_sec, sprints[i].m_sec, 1e-9, ());
    TEST_EQUAL(parsed[i].m_trapKmh, sprints[i].m_trapKmh, ());
  }
  TEST(ParseSprints("").empty(), ());
}
}  // namespace nogps_sprint_tests
