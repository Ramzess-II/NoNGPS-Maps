#include "map/nogps/gps_spoofing_detector.hpp"

#include "map/nogps/geo.hpp"

#include "base/logging.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

namespace nogps
{
namespace
{
double NetworkTolerance(double networkAccuracyM, int64_t dtMs)
{
  return std::max(GpsSpoofingDetector::kNetworkMinToleranceM,
                  GpsSpoofingDetector::kNetworkAccuracyFactor * networkAccuracyM) +
         GpsSpoofingDetector::kMaxSpeedMps * std::abs(dtMs) / 1000.0;
}
}  // namespace

std::string GpsSpoofingDetector::SerializePhantoms() const
{
  std::string result;
  for (auto const & phantom : m_phantoms)
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s%.7f,%.7f", result.empty() ? "" : ";", phantom.m_lat, phantom.m_lon);
    result += buf;
  }
  return result;
}

void GpsSpoofingDetector::DeserializePhantoms(std::string_view phantoms)
{
  m_phantoms.clear();
  for (auto const point : strings::Tokenize(phantoms, ";"))
  {
    auto const latLon = strings::Tokenize(point, ",");
    double lat, lon;
    if (latLon.size() == 2 && strings::to_double(latLon[0], lat) && strings::to_double(latLon[1], lon))
      AddPhantom({lat, lon});
  }
}

std::optional<GpsSpoofingDetector::Trusted> GpsSpoofingDetector::GetLastTrusted() const
{
  if (m_network && (!m_trusted || m_network->m_timeMs > m_trusted->m_timeMs))
    return Trusted{m_network->m_position, m_network->m_timeMs};
  return m_trusted;
}

void GpsSpoofingDetector::RestoreTrusted(ms::LatLon const & position, int64_t timeMs)
{
  if (!m_trusted && !m_network)
    SetTrusted(position, timeMs);
}

void GpsSpoofingDetector::AddPhantom(ms::LatLon const & position)
{
  if (m_phantoms.size() >= kMaxPhantoms)
    m_phantoms.erase(m_phantoms.begin());
  m_phantoms.push_back(position);
}

bool GpsSpoofingDetector::OnNetworkPosition(ms::LatLon const & position, double accuracyM, int64_t timeMs)
{
  if (m_lastNetworkTimeMs == timeMs)
    return m_lastNetworkAccepted;
  m_lastNetworkTimeMs = timeMs;
  bool const hadNetwork = m_network.has_value();
  bool const farFromNetwork = hadNetwork && Distance(position, m_network->m_position) > kSamePointM;
  m_lastNetworkAccepted = AcceptNetworkPosition(position, accuracyM, timeMs);
  if (m_lastNetworkAccepted)
  {
    // Another point near the first one confirms it, while the same point again proves nothing.
    if (!hadNetwork)
      m_networkUnconfirmed = !(m_trusted && std::abs(timeMs - m_trusted->m_timeMs) <= kNetworkMaxAgeMs);
    else if (farFromNetwork)
      m_networkUnconfirmed = false;
    m_network = Network{position, accuracyM, timeMs};
  }
  return m_lastNetworkAccepted;
}

bool GpsSpoofingDetector::AgreesWithSatellite(ms::LatLon const & position, double accuracyM, int64_t timeMs) const
{
  return m_trusted && std::abs(timeMs - m_trusted->m_timeMs) <= kNetworkMaxAgeMs &&
         Distance(position, m_trusted->m_position) <= std::max(accuracyM, kSamePointM);
}

bool GpsSpoofingDetector::ContradictsSatellite(ms::LatLon const & position, double accuracyM, int64_t timeMs) const
{
  if (!m_jump || !m_trusted || m_trusted->m_timeMs <= m_jump->m_timeMs ||
      timeMs - m_trusted->m_timeMs > kNetworkMaxAgeMs)
  {
    return false;
  }
  return Distance(position, m_trusted->m_position) > NetworkTolerance(accuracyM, timeMs - m_trusted->m_timeMs);
}

void GpsSpoofingDetector::CheckUnconfirmedNetwork(ms::LatLon const & position, int64_t timeMs)
{
  if (!m_networkUnconfirmed || !HasFreshNetwork(timeMs))
    return;
  double const distanceM = Distance(position, m_network->m_position);
  if (distanceM <= NetworkTolerance(m_network->m_accuracyM, timeMs - m_network->m_timeMs))
  {
    m_networkUnconfirmed = false;
  }
  else if (distanceM <= kUnconfirmedNetworkToleranceM)
  {
    // Satellites against one network point: the point is the wrong one, as such points are kilometers off.
    LOG(LWARNING, ("The first network position is", distanceM, "m from GPS: ignored"));
    m_network.reset();
    m_networkUnconfirmed = false;
  }
}

bool GpsSpoofingDetector::AcceptNetworkPosition(ms::LatLon const & position, double accuracyM, int64_t timeMs)
{
  // The right place of the phone is not a wrong point, even if it was taken for one.
  if (AgreesWithSatellite(position, accuracyM, timeMs))
  {
    std::erase_if(m_phantoms, [&](ms::LatLon const & phantom) { return Distance(position, phantom) <= kSamePointM; });
    // Back from a jump soon: the jump point is wrong.
    if (m_jump && timeMs - m_jump->m_timeMs < kJumpConfirmMs &&
        !AgreesWithSatellite(m_jump->m_position, m_jump->m_accuracyM, timeMs))
    {
      AddPhantom(m_jump->m_position);
    }
    m_jump.reset();
    return true;
  }

  if (std::any_of(m_phantoms.cbegin(), m_phantoms.cend(),
                  [&](ms::LatLon const & phantom) { return Distance(position, phantom) <= kSamePointM; }))
  {
    return false;
  }

  // The same point again proves nothing, while the time since the last trusted position makes any jump look
  // possible.
  if (m_jump && Distance(position, m_jump->m_position) <= kSamePointM)
  {
    if (timeMs - m_jump->m_timeMs < kJumpConfirmMs)
      return false;
    bool const wrong = ContradictsSatellite(position, accuracyM, timeMs);
    if (wrong)
      AddPhantom(m_jump->m_position);
    m_jump.reset();
    return !wrong;
  }

  // The most recent trusted position: satellite or network.
  bool const trustedIsLatest = m_trusted && (!m_network || m_trusted->m_timeMs >= m_network->m_timeMs);
  if (!trustedIsLatest && !m_network)
    return true;
  ms::LatLon const & ref = trustedIsLatest ? m_trusted->m_position : m_network->m_position;
  int64_t const refTimeMs = trustedIsLatest ? m_trusted->m_timeMs : m_network->m_timeMs;
  double const refAccuracyM = trustedIsLatest ? 0 : m_network->m_accuracyM;

  if (Distance(position, ref) <= NetworkTolerance(std::max(accuracyM, refAccuracyM), timeMs - refTimeMs))
  {
    // Back from a jump soon: the jump point is wrong.
    if (m_jump && timeMs - m_jump->m_timeMs < kJumpConfirmMs &&
        !AgreesWithSatellite(m_jump->m_position, m_jump->m_accuracyM, timeMs))
      AddPhantom(m_jump->m_position);
    m_jump.reset();
    return true;
  }

  if (accuracyM * kMoreAccurateFactor < refAccuracyM)
  {
    m_jump.reset();
    return true;
  }

  if (!m_jump)
  {
    m_jump = Jump{position, accuracyM, timeMs};
    return false;
  }

  bool const confirmed =
      Distance(position, m_jump->m_position) <= NetworkTolerance(accuracyM, timeMs - m_jump->m_timeMs);
  // Trusted satellite positions that are farther from the point than its tolerance win over the time.
  if (confirmed || (timeMs - m_jump->m_timeMs >= kJumpConfirmMs && !ContradictsSatellite(position, accuracyM, timeMs)))
  {
    m_jump.reset();
    return true;
  }
  // Another jump, but the time since the first one counts.
  m_jump->m_position = position;
  m_jump->m_accuracyM = accuracyM;
  return false;
}

std::optional<bool> GpsSpoofingDetector::CheckSpeed(ms::LatLon const & position, int64_t timeMs, double accuracyM,
                                                    std::optional<double> gpsSpeedMps,
                                                    std::optional<double> carSpeedMps)
{
  if (!gpsSpeedMps && m_previous)
  {
    int64_t const dtMs = timeMs - m_previous->m_timeMs;
    if (dtMs >= kSpeedMinGapMs && dtMs <= kSpeedMaxGapMs)
      gpsSpeedMps = Distance(position, m_previous->m_position) * 1000.0 / dtMs;
  }
  m_previous = Trusted{position, timeMs};

  if (!carSpeedMps)
  {
    m_speedMismatchCount = 0;
    return false;
  }
  // Nothing to compare: the count neither grows nor drops.
  if (!gpsSpeedMps || accuracyM > kSpeedMaxAccuracyM)
    return {};

  double const diffMps = std::abs(*gpsSpeedMps - *carSpeedMps);
  bool const mismatch =
      diffMps * 3.6 > kSpeedMismatchKmh && diffMps > kSpeedMismatchFactor * std::max(*gpsSpeedMps, *carSpeedMps);
  bool const wasMismatch = m_speedMismatchCount >= kSpeedMismatchFixes;
  m_speedMismatchCount = mismatch ? m_speedMismatchCount + 1 : 0;
  bool const isMismatch = m_speedMismatchCount >= kSpeedMismatchFixes;
  if (isMismatch != wasMismatch)
  {
    LOG(LWARNING, (isMismatch ? "GPS speed disagrees with the car speed:" : "GPS speed agrees with the car speed:",
                   "gps =", *gpsSpeedMps * 3.6, "km/h, car =", *carSpeedMps * 3.6, "km/h"));
  }
  return !mismatch && *carSpeedMps >= kAgreeingMinSpeedMps;
}

bool GpsSpoofingDetector::CheckSatellitePosition(ms::LatLon const & position, int64_t timeMs, double accuracyM,
                                                 std::optional<double> gpsSpeedMps, std::optional<double> carSpeedMps,
                                                 bool checkSpeed, bool nearInertial)
{
  if (checkSpeed)
  {
    if (m_previous && timeMs - m_previous->m_timeMs > kAgreeingMaxGapMs)
      m_agreeingCount = 0;
    auto const agrees = CheckSpeed(position, timeMs, accuracyM, gpsSpeedMps, carSpeedMps);
    // A point with nothing to compare neither grows the count nor drops it.
    if (agrees)
      m_agreeingCount = *agrees && nearInertial ? m_agreeingCount + 1 : 0;
  }
  CheckUnconfirmedNetwork(position, timeMs);
  bool const followsCar = m_agreeingCount >= kAgreeingFixesToTrust;
  bool const consistent = (followsCar || IsConsistent(position, timeMs)) && m_speedMismatchCount < kSpeedMismatchFixes;
  if (!m_spoofed)
  {
    if (consistent)
    {
      SetTrusted(position, timeMs);
      return true;
    }
    m_spoofed = true;
    m_consistentCount = 0;
    return false;
  }

  m_consistentCount = consistent ? m_consistentCount + 1 : 0;
  int const required =
      HasFreshNetwork(timeMs) ? kConsistentPositionsToRecover : kConsistentPositionsToRecoverWithoutNetwork;
  if (m_consistentCount < required)
    return false;

  m_spoofed = false;
  SetTrusted(position, timeMs);
  return true;
}

bool GpsSpoofingDetector::IsConsistent(ms::LatLon const & position, int64_t timeMs) const
{
  if (HasFreshNetwork(timeMs))
  {
    return Distance(position, m_network->m_position) <=
           NetworkTolerance(m_network->m_accuracyM, timeMs - m_network->m_timeMs);
  }

  if (m_trusted)
  {
    double const tolerance = kMinJumpM + kMaxSpeedMps * std::abs(timeMs - m_trusted->m_timeMs) / 1000.0;
    return Distance(position, m_trusted->m_position) <= tolerance;
  }

  // Nothing to compare with.
  return !m_spoofed;
}

bool GpsSpoofingDetector::HasFreshNetwork(int64_t timeMs) const
{
  return m_network && std::abs(timeMs - m_network->m_timeMs) <= kNetworkMaxAgeMs;
}

void GpsSpoofingDetector::SetTrusted(ms::LatLon const & position, int64_t timeMs)
{
  m_trusted = Trusted{position, timeMs};
}
}  // namespace nogps
