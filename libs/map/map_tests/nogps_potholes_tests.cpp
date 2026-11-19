#include "testing/testing.hpp"

#include "map/map_tests/nogps_test_env.hpp"

#include "map/nogps/geo.hpp"
#include "map/nogps/potholes.hpp"

#include "platform/platform.hpp"

#include "coding/internal/file_data.hpp"

#include <optional>
#include <string>

namespace nogps_potholes_tests
{
using namespace nogps;
using namespace nogps_test;

std::optional<ms::LatLon> const kOnRoad = At(100, 0);

UNIT_TEST(NoGps_Potholes_HitNeedsJoltSpeedAndRoad)
{
  auto const hits = [](double joltMs2, int speedKmh, std::optional<ms::LatLon> const & place)
  {
    PotholeDetector detector;
    TEST(!detector.OnSample(0, joltMs2, speedKmh, place), ());
    return detector.OnSample(1000, 0, speedKmh, place).has_value();
  };
  TEST(!hits(5.9, 50, kOnRoad), ());
  TEST(hits(6.0, 50, kOnRoad), ());
  // A door slam of a standing car, a car that reports no speed.
  TEST(!hits(9, 9, kOnRoad), ());
  TEST(!hits(9, -1, kOnRoad), ());
  // The road is lost.
  TEST(!hits(9, 50, std::nullopt), ());
}

UNIT_TEST(NoGps_Potholes_AxlesAreOneHit)
{
  PotholeDetector detector;
  TEST(!detector.OnSample(0, 7, 50, At(100, 0)), ());
  // The rear axle hits harder: the hit is where it does.
  TEST(!detector.OnSample(200, 9, 52, At(103, 0)), ());
  TEST(!detector.OnSample(400, 8, 50, At(106, 0)), ());
  TEST(!detector.OnSample(980, 0, 50, At(113, 0)), ());
  auto const hit = detector.OnSample(1000, 0, 50, At(114, 0));
  TEST(hit, ());
  TEST_EQUAL(hit->m_joltMs2, 9, ());
  TEST_EQUAL(hit->m_speedKmh, 52, ());
  TEST_ALMOST_EQUAL_ABS(East(hit->m_place), 103.0, 1e-6, ());
  TEST(!detector.OnSample(2000, 0, 50, At(128, 0)), ());

  // 1.5 s apart: two holes. The second one starts at the packet that ends the first.
  TEST(!detector.OnSample(10'000, 7, 50, At(200, 0)), ());
  auto const first = detector.OnSample(11'500, 8, 50, At(220, 0));
  TEST(first, ());
  TEST_EQUAL(first->m_joltMs2, 7, ());
  auto const second = detector.OnSample(12'500, 0, 50, At(234, 0));
  TEST(second, ());
  TEST_EQUAL(second->m_joltMs2, 8, ());
}

UNIT_TEST(NoGps_Potholes_Pct)
{
  TEST_EQUAL(PotholeStore::ToPct(6), 15, ());
  TEST_EQUAL(PotholeStore::ToPct(12), 31, ());
  TEST_EQUAL(PotholeStore::ToPct(39.2), 100, ());
  TEST_EQUAL(PotholeStore::ToPct(60), 100, ());
}

UNIT_TEST(NoGps_Potholes_MergeNearHits)
{
  PotholeStore store;
  auto added = store.Add(At(100, 0), 20, 1000);
  TEST(!added.m_merged, ());
  TEST_EQUAL(added.m_pothole.m_hits, 1, ());

  // A weaker hit 14 m away is the same pothole: it keeps the strongest hit.
  added = store.Add(At(114, 0), 15, 2000);
  TEST(added.m_merged, ());
  TEST_EQUAL(store.Get().size(), 1, ());
  TEST_EQUAL(store.Get()[0].m_hits, 2, ());
  TEST_EQUAL(store.Get()[0].m_pct, 20, ());
  TEST_EQUAL(store.Get()[0].m_lastUnixMs, 2000, ());
  TEST_ALMOST_EQUAL_ABS(East(store.Get()[0].m_place), 100.0, 1e-6, ());

  added = store.Add(At(116, 0), 40, 3000);
  TEST(!added.m_merged, ());
  TEST_EQUAL(store.Get().size(), 2, ());

  // The nearest one takes the hit.
  added = store.Add(At(110, 0), 50, 4000);
  TEST(added.m_merged, ());
  TEST_EQUAL(store.Get()[1].m_hits, 2, ());
  TEST_EQUAL(store.Get()[1].m_pct, 50, ());
}

UNIT_TEST(NoGps_Potholes_OldestDroppedBeyondMax)
{
  PotholeStore store;
  for (size_t i = 0; i < PotholeStore::kMax; ++i)
    store.Add(At(100.0 * i, 0), 20, 10'000 + i);
  // The first one is hit again: the second one is the oldest now.
  store.Add(At(0, 0), 20, 100'000);
  TEST_EQUAL(store.Get().size(), PotholeStore::kMax, ());
  store.Add(At(-1000, 0), 30, 200'000);
  TEST_EQUAL(store.Get().size(), PotholeStore::kMax, ());
  TEST_ALMOST_EQUAL_ABS(East(store.Get()[0].m_place), 0.0, 1e-6, ());
  TEST_ALMOST_EQUAL_ABS(East(store.Get()[1].m_place), 200.0, 1e-3, ());
  TEST_EQUAL(store.Get().back().m_pct, 30, ());
}

UNIT_TEST(NoGps_Potholes_SaveAndLoad)
{
  std::string const path = GetPlatform().WritablePathForFile("nogps_potholes_test.csv");
  PotholeStore store;
  store.Add({50.4501234, 30.5234567}, 15, 1'763'000'000'123);
  store.Add({50.4601234, 30.5334567}, 55, 1'763'000'100'456);
  store.Add({50.4601234, 30.5334567}, 31, 1'763'000'200'789);
  TEST(store.Save(path), ());

  PotholeStore loaded;
  loaded.Load(path);
  base::DeleteFileX(path);
  TEST_EQUAL(loaded.Get().size(), 2, ());
  for (size_t i = 0; i < loaded.Get().size(); ++i)
  {
    auto const & a = store.Get()[i];
    auto const & b = loaded.Get()[i];
    TEST_LESS(Distance(a.m_place, b.m_place), 0.1, ());
    TEST_EQUAL(a.m_pct, b.m_pct, ());
    TEST_EQUAL(a.m_hits, b.m_hits, ());
    TEST_EQUAL(a.m_lastUnixMs, b.m_lastUnixMs, ());
  }

  // No file: no potholes.
  loaded.Load(path);
  TEST(loaded.Get().empty(), ());
}
}  // namespace nogps_potholes_tests
