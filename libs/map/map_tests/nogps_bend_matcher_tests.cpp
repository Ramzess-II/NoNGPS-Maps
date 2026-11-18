#include "testing/testing.hpp"

#include "map/map_tests/nogps_test_roads.hpp"

#include "map/nogps/bend_matcher.hpp"
#include "map/nogps/geo.hpp"

#include "geometry/point2d.hpp"

#include "base/math.hpp"

#include <cmath>
#include <optional>
#include <string>
#include <vector>

namespace nogps_bend_matcher_tests
{
using namespace nogps;
using nogps_test::At;

/// One road given by its points, meters east and north.
class Road : public Roads
{
public:
  explicit Road(double startBearingDeg) : m_bearingDeg(startBearingDeg) { m_points.emplace_back(0, 0); }

  /// Continues the road turning it evenly by |turnDeg|, clockwise is positive.
  Road & Add(double lengthM, double turnDeg)
  {
    auto const steps = static_cast<int>(std::round(lengthM));
    for (int i = 0; i < steps; ++i)
    {
      m_bearingDeg += turnDeg / steps;
      auto const & last = m_points.back();
      m_points.emplace_back(last.x + std::sin(math::DegToRad(m_bearingDeg)),
                            last.y + std::cos(math::DegToRad(m_bearingDeg)));
    }
    return *this;
  }

  /// The road at the distance from its start.
  RoadPoint AtDistance(double distanceM) const
  {
    auto const index = static_cast<size_t>(std::round(distanceM));
    auto const & point = m_points[index];
    auto const & next = m_points[index + 1];
    return {At(point.x, point.y), math::RadToDeg(std::atan2(next.x - point.x, next.y - point.y))};
  }

  std::optional<RoadPoint> Snap(ms::LatLon const & point, std::optional<double>, double radiusM) override
  {
    double const x = nogps_test::East(point);
    double const y = nogps_test::North(point);
    std::optional<size_t> best;
    double bestDistance = radiusM;
    for (size_t i = 0; i + 1 < m_points.size(); ++i)
    {
      double const distance = std::hypot(m_points[i].x - x, m_points[i].y - y);
      if (distance <= bestDistance)
      {
        bestDistance = distance;
        best = i;
      }
    }
    if (!best)
      return {};
    return AtDistance(*best);
  }

  std::vector<ms::LatLon> FindCrossings(ms::LatLon const &, double) override { return {}; }

private:
  std::vector<m2::PointD> m_points;
  // The direction the road is being drawn in.
  double m_bearingDeg;
};

/// Drives the car along the road from its start to the distance.
/// \param laneChangesAtM where the car changes a lane: it turns by 5 degrees and back within 40 m.
BendMatcher Drive(BendMatcher matcher, Road const & road, double distanceM, std::vector<double> const & laneChangesAtM)
{
  double bearing = road.AtDistance(0).m_bearingDeg;
  for (int m = 1; m <= distanceM; ++m)
  {
    double const roadBearing = road.AtDistance(m).m_bearingDeg;
    double yaw = AngleDiff(roadBearing, bearing);
    bearing = roadBearing;
    for (double const laneChangeAtM : laneChangesAtM)
      if (m > laneChangeAtM && m <= laneChangeAtM + 10)
        yaw += 0.5;
      else if (m > laneChangeAtM + 30 && m <= laneChangeAtM + 40)
        yaw -= 0.5;
    matcher.OnMotion(yaw, 1);
  }
  return matcher;
}

BendMatcher Drive(Road const & road, double distanceM, std::optional<double> laneChangeAtM)
{
  std::vector<double> laneChanges;
  if (laneChangeAtM)
    laneChanges.push_back(*laneChangeAtM);
  return Drive(BendMatcher(), road, distanceM, laneChanges);
}

std::optional<double> Match(BendMatcher const & matcher, Road & road, double positionM, std::string * whyNot = nullptr,
                            double maxShiftM = 60)
{
  auto const position = road.AtDistance(positionM);
  return matcher.Match(road, position.m_point, position.m_bearingDeg, maxShiftM, whyNot);
}

// 300 m east, a bend of 40 degrees to the right 80 m long, 300 m straight again.
Road BentRoad()
{
  Road road(90);
  road.Add(300, 0).Add(80, 40).Add(300, 0);
  return road;
}

UNIT_TEST(NoGps_BendMatcher_FindsPositionAheadOfCar)
{
  auto road = BentRoad();
  // The car is 60 m after the bend, the calculated position is 25 m farther.
  auto const matcher = Drive(road, 440, {});
  auto const ahead = Match(matcher, road, 465);
  TEST(ahead, ());
  TEST_ALMOST_EQUAL_ABS(*ahead, 25.0, 3.0, ());
}

UNIT_TEST(NoGps_BendMatcher_FindsFarPositionAfterLongWay)
{
  auto road = BentRoad();
  // The calculated position is 150 m ahead of the car: not found within 60 m, found within the along error.
  auto const matcher = Drive(road, 440, {});
  auto const near = Match(matcher, road, 590);
  TEST(!near || std::fabs(*near - 150) > 20, ());
  auto const ahead = Match(matcher, road, 590, nullptr, 200);
  TEST(ahead, ());
  TEST_ALMOST_EQUAL_ABS(*ahead, 150.0, 3.0, ());
}

UNIT_TEST(NoGps_BendMatcher_FindsPositionBehindCar)
{
  auto road = BentRoad();
  auto const matcher = Drive(road, 440, {});
  auto const ahead = Match(matcher, road, 410);
  TEST(ahead, ());
  TEST_ALMOST_EQUAL_ABS(*ahead, -30.0, 3.0, ());
}

UNIT_TEST(NoGps_BendMatcher_FitsRightPosition)
{
  auto road = BentRoad();
  auto const matcher = Drive(road, 440, {});
  auto const ahead = Match(matcher, road, 440);
  TEST(ahead, ());
  TEST_ALMOST_EQUAL_ABS(*ahead, 0.0, 3.0, ());
}

UNIT_TEST(NoGps_BendMatcher_TellsNothingOnStraightRoad)
{
  Road road(90);
  road.Add(600, 0);
  auto const matcher = Drive(road, 400, {});
  std::string whyNot;
  TEST(!Match(matcher, road, 420, &whyNot), ());
  // Nothing to tell in the log.
  TEST(whyNot.empty(), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_LaneChangeIsNotBend)
{
  // A lane is changed on a straight road: the car turns by 5 degrees and back.
  Road straight(90);
  straight.Add(600, 0);
  TEST(!Match(Drive(straight, 400, 300), straight, 420), ());
  // A lane changed on the way doesn't move the position found by the bend.
  auto road = BentRoad();
  auto const ahead = Match(Drive(road, 440, 395), road, 465);
  TEST(ahead, ());
  TEST_ALMOST_EQUAL_ABS(*ahead, 25.0, 5.0, ());
}

UNIT_TEST(NoGps_BendMatcher_TellsNothingOnEvenBend)
{
  // A roundabout or a long even bend looks the same wherever the car is on it.
  Road road(90);
  road.Add(100, 0).Add(500, 300);
  auto const matcher = Drive(road, 400, {});
  std::string whyNot;
  TEST(!Match(matcher, road, 420, &whyNot), ());
  TEST(whyNot.starts_with("not clear"), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_TellsNothingBeforeEnoughIsDriven)
{
  auto road = BentRoad();
  BendMatcher matcher;
  matcher.OnMotion(0, 50);
  TEST(!Match(matcher, road, 400), ());
}

UNIT_TEST(NoGps_BendMatcher_TellsNothingWhenErrorIsLarger)
{
  auto road = BentRoad();
  // The position is 100 m ahead: the bend is not within the searched 60 m, the road around looks straight.
  auto const matcher = Drive(road, 440, {});
  std::string whyNot;
  TEST(!Match(matcher, road, 540, &whyNot), ());
  TEST(whyNot.starts_with("the bends differ"), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_TellsNothingAtEdgeOfSearch)
{
  auto road = BentRoad();
  auto const matcher = Drive(road, 440, {});
  // The position is 39 m ahead, the search is 37.3 m: the best fit is at 37 m, the edge, the real place is
  // farther.
  std::string whyNot;
  TEST(!Match(matcher, road, 479, &whyNot, 37.3), ());
  TEST(whyNot.starts_with("the best fit is at the edge"), (whyNot));
  TEST(!Match(matcher, road, 479, &whyNot, 37.6), ());
  TEST(!Match(matcher, road, 401, &whyNot, 37.3), ());
  TEST(whyNot.starts_with("the best fit is at the edge"), (whyNot));
  // A longer search finds it.
  auto const ahead = Match(matcher, road, 479, nullptr, 45);
  TEST(ahead, ());
  TEST_ALMOST_EQUAL_ABS(*ahead, 39.0, 3.0, ());
}

UNIT_TEST(NoGps_BendMatcher_TellsNothingWhenRoadIsNotFollowed)
{
  // The road turns by 90 degrees within 4 m, 200 m behind the position: within the 210 m walked back.
  Road road(0);
  road.Add(20, 0).Add(4, 90).Add(50, 0).Add(80, 40).Add(300, 0);
  auto const matcher = Drive(road, 220, {});
  std::string whyNot;
  TEST(!Match(matcher, road, 220, &whyNot), ());
  TEST(whyNot.starts_with("the road turns by"), (whyNot));
  TEST(whyNot.ends_with("behind"), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_RotationOfLastMeters)
{
  BendMatcher matcher;
  for (int i = 0; i < 40; ++i)
    matcher.OnMotion(0, 1);
  // Not known until the car has driven that far.
  TEST(!matcher.GetRotationDeg(50), ());
  for (int i = 0; i < 20; ++i)
    matcher.OnMotion(-1, 1);
  TEST_ALMOST_EQUAL_ABS(*matcher.GetRotationDeg(50), -20.0, 1e-6, ());
  for (int i = 0; i < 40; ++i)
    matcher.OnMotion(0, 1);
  TEST_ALMOST_EQUAL_ABS(*matcher.GetRotationDeg(50), -10.0, 1e-6, ());
  matcher.Reset();
  TEST(!matcher.GetRotationDeg(50), ());
}

// The matcher of the roads that bend gently, as the navigator makes it.
BendMatcher::Params GentleParams()
{
  return {800 /* window */, 10 /* step */,        100 /* smooth */,         6 /* min bend */,
          2 /* max diff */, 40 /* clear aside */, 0.1 /* min aside diff */, 45 /* max bend */};
}

// 1 km straight, 600 m turning by 12 degrees, 1 km straight: a highway.
Road HighwayRoad()
{
  Road road(90);
  road.Add(1000, 0).Add(600, 12).Add(1000, 0);
  return road;
}

UNIT_TEST(NoGps_BendMatcher_GentleFindsPositionAheadAndBehind)
{
  auto road = HighwayRoad();
  // The car has driven the whole bend: 12 degrees in 600 m, the ordinary matcher sees 3 degrees in 150 m.
  auto const matcher = Drive(BendMatcher(GentleParams()), road, 1700, {});
  for (double const error : {40.0, -40.0, 0.0})
  {
    std::string whyNot;
    auto const ahead = Match(matcher, road, 1700 + error, &whyNot);
    TEST(ahead, (error, whyNot));
    TEST_ALMOST_EQUAL_ABS(*ahead, error, 5.0, ());
  }
  // The ordinary matcher tells nothing here.
  TEST(!Match(Drive(road, 1700, {}), road, 1740), ());
}

UNIT_TEST(NoGps_BendMatcher_GentleLaneChangesAreNotBend)
{
  // Two lane changes on a straight road: the smoothing leaves less than the minimal bend.
  Road straight(90);
  straight.Add(2000, 0);
  auto const matcher = Drive(BendMatcher(GentleParams()), straight, 1500, {1000, 1250});
  std::string whyNot;
  TEST(!Match(matcher, straight, 1540, &whyNot), ());
  TEST(whyNot.empty(), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_GentleTellsNothingInsideLongEvenArc)
{
  Road road(90);
  road.Add(500, 0).Add(2400, 48).Add(500, 0);
  // The car is far from both ends of the arc: 12 degrees in 600 m everywhere around.
  auto const matcher = Drive(BendMatcher(GentleParams()), road, 1800, {});
  std::string whyNot;
  TEST(!Match(matcher, road, 1840, &whyNot), ());
  TEST(whyNot.starts_with("not clear"), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_GentleTellsNothingAfterTurn)
{
  auto road = HighwayRoad();
  BendMatcher matcher(GentleParams());
  // The car has turned by 90 degrees within the window: a turn, not a bend of the road.
  for (int m = 0; m < 1000; ++m)
    matcher.OnMotion(m == 1000 - 300 ? 90 : 0, 1);
  std::string whyNot;
  TEST(!Match(matcher, road, 1740, &whyNot), ());
  TEST(whyNot.empty(), (whyNot));
}

UNIT_TEST(NoGps_BendMatcher_GentleTellsNothingBeforeWindowIsDriven)
{
  auto road = HighwayRoad();
  TEST(!Match(Drive(BendMatcher(GentleParams()), road, 700, {}), road, 740), ());
}
}  // namespace nogps_bend_matcher_tests
