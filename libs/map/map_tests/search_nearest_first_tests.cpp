#include "testing/testing.hpp"

#include "map/search_api.hpp"

#include "geometry/mercator.hpp"

#include <cmath>
#include <optional>
#include <string>
#include <vector>

namespace search_nearest_first_tests
{
using namespace search;

m2::PointD const kPivot = mercator::FromLatLon(0, 0);

// A result this far east of the pivot.
Result MakeResult(std::string const & name, double eastKm, NameScore score = NameScore::FULL_MATCH, uint16_t errors = 0)
{
  Result result(mercator::FromLatLon(0, eastKm / 111.2), name);
  result.SetType(Result::Type::Feature);
  result.SetNameScore(score);
  result.SetErrorsMade(ErrorsMade(errors));
  return result;
}

std::vector<std::string> Names(Results const & results)
{
  std::vector<std::string> names;
  for (auto const & result : results)
    names.push_back(result.GetString());
  return names;
}

UNIT_TEST(OrderNearestFirst_KeepsTypedFirst)
{
  Results results;
  results.AddResultNoChecks(Result("street", "street "));
  results.AddResultNoChecks(MakeResult("street far", 30));
  results.AddResultNoChecks(MakeResult("town", 50));
  results.AddResultNoChecks(MakeResult("street near", 1));
  Result coordinates(mercator::FromLatLon(0, 1), "coordinates");
  coordinates.SetType(Result::Type::LatLon);
  results.AddResultNoChecks(std::move(coordinates));
  results.AddResultNoChecks(MakeResult("street middle", 5));
  results.AddResultNoChecks(MakeResult("shop near", 1));
  results.AddResultNoChecks(MakeResult("village", 20));

  OrderNearestFirst(kPivot, false /* isCategory */, results);
  // The suggestion and the typed coordinates stay first in their order. The others, towns too, are nearest first,
  // the equally near ones in their order.
  TEST_EQUAL(Names(results),
             (std::vector<std::string>{"street", "coordinates", "street near", "shop near", "street middle", "village",
                                       "street far", "town"}),
             ());
  for (size_t i = 0; i < results.GetCount(); ++i)
    TEST_EQUAL(results[i].GetPositionInResults(), static_cast<int32_t>(i), ());
}

UNIT_TEST(OrderNearestFirst_MatchTiers)
{
  Results results;
  results.AddResultNoChecks(MakeResult("substring near", 1, NameScore::SUBSTRING));
  results.AddResultNoChecks(MakeResult("misprint near", 2, NameScore::FULL_MATCH, 1));
  results.AddResultNoChecks(MakeResult("prefix far", 20, NameScore::PREFIX));
  results.AddResultNoChecks(MakeResult("exact far", 30, NameScore::FULL_MATCH));
  results.AddResultNoChecks(MakeResult("full prefix middle", 10, NameScore::FULL_PREFIX));
  results.AddResultNoChecks(MakeResult("prefix near", 3, NameScore::PREFIX));
  results.AddResultNoChecks(MakeResult("exact nearer", 5, NameScore::FULL_MATCH));
  OrderNearestFirst(kPivot, false /* isCategory */, results);
  // Exact matches first, then the words matched, then the rest: nearest first inside each.
  TEST_EQUAL(Names(results),
             (std::vector<std::string>{"exact nearer", "full prefix middle", "exact far", "prefix near", "prefix far",
                                       "substring near", "misprint near"}),
             ());
}

UNIT_TEST(OrderNearestFirst_SuggestionsStayFirstWithTiers)
{
  Results results;
  results.AddResultNoChecks(MakeResult("rare far", 30));
  results.AddResultNoChecks(Result("street", "street "));
  results.AddResultNoChecks(MakeResult("near", 1, NameScore::SUBSTRING));
  OrderNearestFirst(kPivot, false /* isCategory */, results);
  TEST_EQUAL(Names(results), (std::vector<std::string>{"street", "rare far", "near"}), ());
}

UNIT_TEST(OrderNearestFirst_CategoryIgnoresTiers)
{
  Results results;
  results.AddResultNoChecks(MakeResult("exact far", 30));
  results.AddResultNoChecks(MakeResult("substring near", 1, NameScore::SUBSTRING));
  results.AddResultNoChecks(MakeResult("misprint middle", 5, NameScore::FULL_MATCH, 1));
  OrderNearestFirst(kPivot, true /* isCategory */, results);
  TEST_EQUAL(Names(results), (std::vector<std::string>{"substring near", "misprint middle", "exact far"}), ());
}

UNIT_TEST(SearchLog_TapIsThePlaceAfterTheOrder)
{
  Results results;
  results.AddResultNoChecks(MakeResult("far", 30));
  results.AddResultNoChecks(MakeResult("near", 1));
  OrderNearestFirst(kPivot, false /* isCategory */, results);

  // "far" was found first, but it is shown second.
  TEST_EQUAL(FormatTapLog(results[1], results.GetCount(), kPivot),
             "place=1 results=2 dist=" +
                 std::to_string(std::lround(mercator::DistanceOnEarth(kPivot, results[1].GetFeatureCenter()))) +
                 " errors=0 type=feature",
             ());
  TEST_EQUAL(FormatTapLog(results[0], results.GetCount(), std::nullopt),
             "place=0 results=2 dist=-1 errors=0 type=feature", ());
  TEST_EQUAL(FormatQueryLog(5, false, 17, "center"), "chars=5 category=0 results=17 pivot=center", ());
}
}  // namespace search_nearest_first_tests
