#include "map/nogps/bend_matcher.hpp"

#include "map/nogps/geo.hpp"

#include "base/assert.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace nogps
{
namespace
{
double constexpr kBendShiftStepM = 1;
double constexpr kBendHistoryStepM = 2;
double constexpr kMaxRoadBendDeg = 45;
double constexpr kBendRoadSnapRadiusM = 8;

std::string Meters(double m)
{
  return std::to_string(static_cast<int>(std::lround(m))) + " m";
}

std::string Degrees(double deg)
{
  return strings::to_string_dac(deg, 1) + " degrees";
}

// Returns the directions of the road the car drives along at every step from the position, forward or back,
// continuous: without jumps at 360 degrees. Nothing if the road ends or turns sharply earlier, |whyNot| tells where.
std::optional<std::vector<double>> WalkRoadBearings(Roads & roads, ms::LatLon const & position, double bearingDeg,
                                                    int steps, double stepM, bool forward, std::string & whyNot)
{
  auto const start = roads.Snap(position, bearingDeg, kBendRoadSnapRadiusM);
  if (!start)
  {
    whyNot = "no road at the mark";
    return {};
  }
  char const * side = forward ? " ahead" : " behind";
  std::vector<double> result(steps + 1);
  ms::LatLon pos = start->m_point;
  // Where the car looks at, also when walking back.
  double carBearing = Orient(start->m_bearingDeg, bearingDeg);
  result[0] = carBearing;
  for (int i = 1; i <= steps; ++i)
  {
    double const moveBearing = forward ? carBearing : carBearing + 180;
    auto const road = roads.Snap(Move(pos, moveBearing, stepM), moveBearing, kBendRoadSnapRadiusM);
    if (!road)
    {
      whyNot = "the road ends " + Meters(i * stepM) + side;
      return {};
    }
    double const roadBearing = Orient(road->m_bearingDeg, carBearing);
    double const bend = AngleDiff(roadBearing, carBearing);
    if (std::fabs(bend) > kMaxRoadBendDeg)
    {
      whyNot = "the road turns by " + Degrees(std::fabs(bend)) + " " + Meters(i * stepM) + side;
      return {};
    }
    pos = road->m_point;
    carBearing = roadBearing;
    result[i] = result[i - 1] + bend;
  }
  return result;
}

// Moving average over |halfWidth| values to both sides, shorter at the ends.
std::vector<double> Smooth(std::vector<double> const & values, int halfWidth)
{
  if (halfWidth <= 0)
    return values;
  std::vector<double> result(values.size());
  for (int i = 0; i < static_cast<int>(values.size()); ++i)
  {
    int const from = std::max(0, i - halfWidth);
    int const to = std::min(static_cast<int>(values.size()) - 1, i + halfWidth);
    double sum = 0;
    for (int j = from; j <= to; ++j)
      sum += values[j];
    result[i] = sum / (to - from + 1);
  }
  return result;
}

// |roadStart| is the index in |road| of the place the car is at, may be fractional. Returns how different the
// rotation of the car and the shape of the road are, degrees, at the indexes of |car| from |from| to |to|. A
// constant difference doesn't count: the heading of the car may be wrong by some degrees.
double BendDifference(std::vector<double> const & car, std::vector<double> const & road, double roadStart, size_t from,
                      size_t to)
{
  double sum = 0;
  double sumSquares = 0;
  for (size_t i = from; i < to; ++i)
  {
    double const position = roadStart + i;
    auto const index = static_cast<size_t>(std::floor(position));
    double const fraction = position - index;
    double const roadBearing =
        index + 1 < road.size() ? road[index] + (road[index + 1] - road[index]) * fraction : road.back();
    double const diff = car[i] - roadBearing;
    sum += diff;
    sumSquares += diff * diff;
  }
  double const count = static_cast<double>(to - from);
  double const mean = sum / count;
  return std::sqrt(std::max(0.0, sumSquares / count - mean * mean));
}
}  // namespace

void BendMatcher::OnMotion(double yawDeltaDeg, double distanceM)
{
  m_yawDeg += yawDeltaDeg;
  m_odometerM += distanceM;
  if (!m_history.empty() && m_odometerM - m_history.back().m_odometerM < kBendHistoryStepM)
    return;
  m_history.push_back({m_odometerM, m_yawDeg});
  // One point at the start of the window or before it is kept.
  while (m_history.size() > 2 && m_odometerM - m_history[1].m_odometerM >= m_params.m_windowM)
    m_history.pop_front();
}

std::optional<double> BendMatcher::Match(Roads & roads, ms::LatLon const & position, double bearingDeg,
                                         double maxShiftM, std::string * whyNot) const
{
  if (whyNot)
    whyNot->clear();
  std::string why;
  auto const no = [&why, whyNot]()
  {
    if (whyNot)
      *whyNot = why;
    return std::optional<double>();
  };
  double const stepM = m_params.m_stepM;
  auto const count = static_cast<int>(m_params.m_windowM / stepM) + 1;
  if (m_history.empty() || m_odometerM - m_history.front().m_odometerM < m_params.m_windowM)
    return {};

  // The rotation of the car at every step back from now.
  std::vector<double> car(count);
  for (int i = 0; i < count; ++i)
    car[i] = YawAt(m_odometerM - i * stepM);
  auto const [rawMin, rawMax] = std::minmax_element(car.cbegin(), car.cend());
  if (*rawMax - *rawMin > m_params.m_maxBendDeg)
    return {};
  // The averages at the ends of the window are over less than the width: they are not compared.
  auto const smoothSteps = static_cast<int>(std::round(m_params.m_smoothM / stepM / 2));
  car = Smooth(car, smoothSteps);
  auto const [min, max] = std::minmax_element(car.cbegin() + smoothSteps, car.cend() - smoothSteps);
  if (*max - *min < m_params.m_minBendDeg)
    return {};

  // The direction of the road at every step from maxShiftM ahead of the position to the end of the window
  // behind the car, were the position ahead of the car by maxShiftM.
  auto const shiftSteps = static_cast<int>(std::ceil(maxShiftM / stepM));
  auto const ahead = WalkRoadBearings(roads, position, bearingDeg, shiftSteps, stepM, true /* forward */, why);
  if (!ahead)
    return no();
  auto const behind =
      WalkRoadBearings(roads, position, bearingDeg, count - 1 + shiftSteps, stepM, false /* forward */, why);
  if (!behind)
    return no();
  // road[shiftSteps] is the position, larger indexes are behind it.
  std::vector<double> road(ahead->size() + behind->size() - 1);
  for (size_t i = 0; i < ahead->size(); ++i)
    road[shiftSteps - i] = (*ahead)[i];
  for (size_t i = 1; i < behind->size(); ++i)
    road[shiftSteps + i] = (*behind)[i];

  road = Smooth(road, smoothSteps);

  auto const shifts = static_cast<int>(std::round(maxShiftM / kBendShiftStepM));
  std::vector<double> diffs(2 * shifts + 1);
  int bestIndex = 0;
  for (int i = 0; i < static_cast<int>(diffs.size()); ++i)
  {
    diffs[i] = BendDifference(car, road, shiftSteps + (i - shifts) * kBendShiftStepM / stepM, smoothSteps,
                              car.size() - smoothSteps);
    if (diffs[i] < diffs[bestIndex])
      bestIndex = i;
  }
  double const best = diffs[bestIndex];
  double const bestShift = (bestIndex - shifts) * kBendShiftStepM;
  if (best > m_params.m_maxDiffDeg)
  {
    why = "the bends differ by " + Degrees(best) + " at best, ahead by " + Meters(bestShift);
    return no();
  }
  // The real place may be farther.
  if (bestIndex == 0 || bestIndex + 1 == static_cast<int>(diffs.size()))
  {
    why = "the best fit is at the edge of the search, ahead by " + Meters(bestShift);
    return no();
  }
  auto const aside = static_cast<int>(std::round(m_params.m_clearAsideM / kBendShiftStepM));
  for (int i = 0; i < static_cast<int>(diffs.size()); ++i)
  {
    if (std::abs(i - bestIndex) >= aside && diffs[i] < kClearRatio * std::max(best, m_params.m_minAsideDiffDeg))
    {
      why = "not clear: ahead by " + Meters(bestShift) + " differs by " + Degrees(best) + ", ahead by " +
            Meters((i - shifts) * kBendShiftStepM) + " by " + Degrees(diffs[i]);
      return no();
    }
  }
  return bestShift;
}

std::optional<double> BendMatcher::GetRotationDeg(double distanceM) const
{
  ASSERT_LESS_OR_EQUAL(distanceM, m_params.m_windowM, ());
  if (m_history.empty() || m_history.front().m_odometerM > m_odometerM - distanceM)
    return {};
  return m_yawDeg - YawAt(m_odometerM - distanceM);
}

double BendMatcher::YawAt(double odometerM) const
{
  Sample const * previous = nullptr;
  for (auto const & point : m_history)
  {
    if (point.m_odometerM >= odometerM)
    {
      if (previous == nullptr || point.m_odometerM == previous->m_odometerM)
        return point.m_yawDeg;
      return previous->m_yawDeg + (point.m_yawDeg - previous->m_yawDeg) * (odometerM - previous->m_odometerM) /
                                      (point.m_odometerM - previous->m_odometerM);
    }
    previous = &point;
  }
  return previous != nullptr ? previous->m_yawDeg : 0;
}
}  // namespace nogps
