#include "map/nogps/speed_table.hpp"

#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace nogps
{
int SpeedTable::Range(double carSpeedKmh)
{
  return std::min(kRanges - 1, static_cast<int>(carSpeedKmh / kRangeKmh));
}

bool SpeedTable::IsGoodSample(double carSpeedKmh, double gpsSpeedMps, double dtSec, double accelerationMps2)
{
  double const diffKmh = std::fabs(gpsSpeedMps * 3.6 - carSpeedKmh);
  return carSpeedKmh >= kMinSpeedKmh && dtSec > 0 && dtSec <= kMaxSampleDtSec &&
         std::fabs(accelerationMps2) <= kMaxAccelerationMps2 &&
         diffKmh <= std::max(kMaxSpeedDiffKmh, kMaxSpeedDiffRatio * carSpeedKmh);
}

void SpeedTable::OnSample(double carSpeedKmh, double gpsSpeedMps, double dtSec, double accelerationMps2)
{
  if (!IsGoodSample(carSpeedKmh, gpsSpeedMps, dtSec, accelerationMps2))
    return;
  OnDistance(carSpeedKmh, carSpeedKmh / 3.6 * dtSec, gpsSpeedMps * dtSec);
}

void SpeedTable::OnDistance(double carSpeedKmh, double carM, double realM)
{
  if (carSpeedKmh < kMinSpeedKmh || carM <= 0 || realM < 0)
    return;
  int const i = Range(carSpeedKmh);
  m_carM[i] += carM;
  m_gpsM[i] += realM;
  m_sec[i] += carM / (carSpeedKmh / 3.6);
  if (m_carM[i] > kMaxDistanceM)
  {
    m_carM[i] /= 2;
    m_gpsM[i] /= 2;
    m_sec[i] /= 2;
  }
}

double SpeedTable::ScaleOf(int i, double offsetKmh) const
{
  return std::clamp(m_gpsM[i] / (m_carM[i] + offsetKmh / 3.6 * m_sec[i]), kMinScale, kMaxScale);
}

double SpeedTable::GetOffsetKmh() const
{
  if (!m_learnsOffset || !IsKnown(0))
    return 0;
  int n = 0;
  double sumCar = 0, sumGps = 0, sumCar2 = 0, sumCarGps = 0;
  for (int i = 0; i < kOffsetRanges; ++i)
  {
    if (!IsKnown(i))
      continue;
    double const carKmh = m_carM[i] / m_sec[i] * 3.6;
    double const gpsKmh = m_gpsM[i] / m_sec[i] * 3.6;
    ++n;
    sumCar += carKmh;
    sumGps += gpsKmh;
    sumCar2 += carKmh * carKmh;
    sumCarGps += carKmh * gpsKmh;
  }
  if (n < 2)
    return 0;
  // Least squares: GPS speed = ratio * car speed + offset.
  double const ratio = (n * sumCarGps - sumCar * sumGps) / (n * sumCar2 - sumCar * sumCar);
  return std::clamp((sumGps - ratio * sumCar) / n, 0.0, kMaxOffsetKmh);
}

std::optional<double> SpeedTable::InterpolateScale(int i, double offsetKmh) const
{
  if (IsKnown(i))
    return ScaleOf(i, offsetKmh);
  int lower = i - 1;
  while (lower >= 0 && !IsKnown(lower))
    --lower;
  int upper = i + 1;
  while (upper < kRanges && !IsKnown(upper))
    ++upper;
  if (lower < 0 && upper >= kRanges)
    return {};
  if (lower < 0)
    return ScaleOf(upper, offsetKmh);
  if (upper >= kRanges)
    return ScaleOf(lower, offsetKmh);
  double const t = static_cast<double>(i - lower) / (upper - lower);
  return ScaleOf(lower, offsetKmh) + (ScaleOf(upper, offsetKmh) - ScaleOf(lower, offsetKmh)) * t;
}

std::optional<double> SpeedTable::GetScale(double carSpeedKmh) const
{
  double const offsetKmh = GetOffsetKmh();
  auto const scale = InterpolateScale(Range(carSpeedKmh), offsetKmh);
  // A car at 0 stands.
  if (!scale || carSpeedKmh <= 0)
    return scale;
  return *scale * (carSpeedKmh + offsetKmh) / carSpeedKmh;
}

int SpeedTable::GetKnownRanges() const
{
  int count = 0;
  for (int i = 0; i < kRanges; ++i)
    if (IsKnown(i))
      ++count;
  return count;
}

SpeedTable::Ranges SpeedTable::GetRanges() const
{
  Ranges ranges;
  for (int i = 0; i < kRanges; ++i)
    ranges[i] = {m_carM[i], IsKnown(i) ? ScaleOf(i, 0) : 0};
  return ranges;
}

void SpeedTable::Clear()
{
  m_carM.fill(0);
  m_gpsM.fill(0);
  m_sec.fill(0);
}

std::string SpeedTable::Serialize() const
{
  std::string result;
  for (int i = 0; i < kRanges; ++i)
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s%.0f:%.0f:%.0f", i > 0 ? ";" : "", m_carM[i], m_gpsM[i], m_sec[i]);
    result += buf;
  }
  return result;
}

void SpeedTable::Deserialize(std::string_view table)
{
  Clear();
  auto const ranges = strings::Tokenize(table, ";");
  if (ranges.size() != kRanges)
    return;
  for (int i = 0; i < kRanges; ++i)
  {
    auto const values = strings::Tokenize(ranges[i], ":");
    if (values.size() < 2 || values.size() > 3 || !strings::to_double(values[0], m_carM[i]) ||
        !strings::to_double(values[1], m_gpsM[i]) || (values.size() == 3 && !strings::to_double(values[2], m_sec[i])))
    {
      Clear();
      return;
    }
    // A table kept without the time: as if driven in the middle of the range.
    if (values.size() == 2)
    {
      double const midKmh = ((i == 0 ? kMinSpeedKmh : i * kRangeKmh) + (i + 1) * kRangeKmh) / 2.0;
      m_sec[i] = m_carM[i] / (midKmh / 3.6);
    }
  }
}

std::string SpeedTable::ToString() const
{
  double const offsetKmh = GetOffsetKmh();
  std::string result;
  char buf[64];
  for (int i = 0; i < kRanges; ++i)
  {
    if (!IsKnown(i))
      continue;
    std::snprintf(buf, sizeof(buf), "%s%d:%.3f", result.empty() ? "" : " ", i * kRangeKmh, ScaleOf(i, offsetKmh));
    result += buf;
  }
  if (offsetKmh > 0)
  {
    std::snprintf(buf, sizeof(buf), " offset=%.2f", offsetKmh);
    result += buf;
  }
  return result;
}

bool SpeedFactor::IsGoodSample(double expectedKmh, double gpsKmh)
{
  return std::fabs(gpsKmh - expectedKmh) <= std::max(kMaxSampleDiffKmh, kMaxSampleDiffRatio * expectedKmh);
}

void SpeedFactor::OnDistance(double expectedM, double realM)
{
  if (expectedM <= 0 || realM < 0)
    return;
  m_expectedM += expectedM;
  m_realM += realM;
  while (m_expectedM > kMaxDistanceM)
  {
    m_expectedM /= 2;
    m_realM /= 2;
  }
}

double SpeedFactor::Get() const
{
  if (m_expectedM < kMinDistanceM)
    return 1;
  return std::clamp(m_realM / m_expectedM, kMinFactor, kMaxFactor);
}

void SpeedFactor::Clear()
{
  m_expectedM = 0;
  m_realM = 0;
}

std::string SpeedFactor::Serialize() const
{
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.1f:%.1f", m_expectedM, m_realM);
  return buf;
}

void SpeedFactor::Deserialize(std::string_view factor)
{
  Clear();
  auto const distances = strings::Tokenize(factor, ":");
  if (distances.size() != 2 || !strings::to_double(distances[0], m_expectedM) ||
      !strings::to_double(distances[1], m_realM))
  {
    Clear();
  }
}
}  // namespace nogps
