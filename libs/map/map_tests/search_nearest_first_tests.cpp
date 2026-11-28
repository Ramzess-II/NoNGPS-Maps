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
Result MakeResult(std::string const & name, double eastKm)
{
  Result result(mercator::FromLatLon(0, eastKm / 111.2), name);
  result.SetType(Result::Type::Feature);
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

  OrderNearestFirst(kPivot, results);
  // The suggestion and the typed coordinates stay first in their order. The others, towns too, are nearest first,
  // the equally near ones in their order.
  TEST_EQUAL(Names(results),
             (std::vector<std::string>{"street", "coordinates", "street near", "shop near", "street middle", "village",
                                       "street far", "town"}),
             ());
  for (size_t i = 0; i < results.GetCount(); ++i)
    TEST_EQUAL(results[i].GetPositionInResults(), static_cast<int32_t>(i), ());
}

UNIT_TEST(SearchLog_TapIsThePlaceAfterTheOrder)
{
  Results results;
  results.AddResultNoChecks(MakeResult("far", 30));
  results.AddResultNoChecks(MakeResult("near", 1));
  OrderNearestFirst(kPivot, results);

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
