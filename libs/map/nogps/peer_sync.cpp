#include "map/nogps/peer_sync.hpp"

#include "map/nogps/geo.hpp"

#include "base/assert.hpp"

#include <algorithm>
#include <cmath>

namespace nogps
{
namespace
{
bool IsTakenBy(PeerRole role, char kind)
{
  if (role == PeerRole::Leading)
    return kind == 'C' || kind == 'G';
  return role == PeerRole::Following && (kind == 'A' || kind == 'S');
}
}  // namespace

std::string DebugPrint(PeerRole role)
{
  switch (role)
  {
  case PeerRole::None: return "None";
  case PeerRole::Leading: return "Leading";
  case PeerRole::Following: return "Following";
  }
  UNREACHABLE();
}

void PeerSync::OnBoxData(int64_t nowMs, int64_t distMm, int64_t yawMdeg)
{
  m_samples.push_back({nowMs, distMm, yawMdeg});
  while (nowMs - m_samples.front().m_timeMs > kPeerHistoryMs)
    m_samples.pop_front();
}

void PeerSync::Reset()
{
  m_samples.clear();
  m_sentMs.reset();
  m_leaderManual = false;
}

void PeerSync::TrackRole(PeerRole role)
{
  // What the other phone said is not true for another role: no new line may come from a leader that has gone.
  if (role != m_role)
    m_leaderManual = false;
  m_role = role;
}

std::optional<int64_t> PeerSync::GetDistMm() const
{
  if (m_samples.empty())
    return {};
  return m_samples.back().m_distMm;
}

std::optional<esp32::Peer> PeerSync::MakeMessage(PeerRole role, PeerTrigger trigger, int64_t nowMs,
                                                 PeerOutPlace const & place)
{
  TrackRole(role);
  char kind = 0;
  switch (trigger)
  {
  case PeerTrigger::PlaceSet: kind = role == PeerRole::Leading ? 'A' : role == PeerRole::Following ? 'C' : 0; break;
  case PeerTrigger::GpsPlace:
    // GPS gives a place every second: it is told once in the interval.
    if (role == PeerRole::Leading && (!m_sentMs || nowMs - *m_sentMs >= kPeerSnapshotIntervalMs))
      kind = 'A';
    break;
  case PeerTrigger::Timer:
    // An anchor just sent tells the place as well.
    if (role == PeerRole::Leading && (!m_sentMs || nowMs - *m_sentMs >= kPeerSnapshotIntervalMs / 2))
      kind = 'S';
    break;
  case PeerTrigger::GpsFix:
    if (role == PeerRole::Following && m_leaderManual)
      kind = 'G';
    break;
  case PeerTrigger::CorrectionTaken:
    if (role == PeerRole::Leading)
      kind = 'A';
    break;
  }
  if (kind == 0 || m_samples.empty())
    return {};
  // The last line of the box that is not after the moment of the place; a place older than the history is not sent.
  std::optional<int64_t> dist;
  for (auto it = m_samples.rbegin(); it != m_samples.rend(); ++it)
    if (it->m_timeMs <= nowMs - place.m_ageMs)
    {
      dist = it->m_distMm;
      break;
    }
  if (!dist)
    return {};
  if (kind == 'A' || kind == 'S')
    m_sentMs = nowMs;

  esp32::Peer peer;
  peer.m_kind = kind;
  peer.m_distMm = *dist;
  peer.m_latE7 = static_cast<int32_t>(std::lround(place.m_position.m_lat * 1e7));
  peer.m_lonE7 = static_cast<int32_t>(std::lround(place.m_position.m_lon * 1e7));
  peer.m_headingCdeg =
      place.m_bearingDeg ? static_cast<int>(std::lround(Normalize(*place.m_bearingDeg) * 100)) % 36000 : -1;
  peer.m_accuracyDm = static_cast<int>(std::lround(std::clamp(place.m_accuracyM, 0.0, 100'000.0) * 10));
  peer.m_source = place.m_source;
  return peer;
}

std::optional<PeerPlace> PeerSync::OnReceived(PeerRole role, esp32::Peer const & peer)
{
  TrackRole(role);
  if (!IsTakenBy(role, peer.m_kind))
    return {};
  if (role == PeerRole::Following)
    m_leaderManual = peer.m_source != 'G';

  // The last line of the box that is not after the moment of the place.
  size_t next = m_samples.size();
  while (next > 0 && m_samples[next - 1].m_distMm > peer.m_distMm)
    --next;
  if (next == 0)
    return {};

  PeerPlace place;
  place.m_kind = peer.m_kind;
  place.m_source = peer.m_source;
  place.m_position = {peer.m_latE7 / 1e7, peer.m_lonE7 / 1e7};
  place.m_accuracyM = peer.m_accuracyDm / 10.0;
  std::optional<double> heading;
  if (peer.m_headingCdeg >= 0)
    heading = peer.m_headingCdeg / 100.0;
  for (size_t i = next; i < m_samples.size(); ++i)
  {
    double const distM = (m_samples[i].m_distMm - m_samples[i - 1].m_distMm) / 1000.0;
    double const yawDeg = (m_samples[i].m_yawMdeg - m_samples[i - 1].m_yawMdeg) / 1000.0;
    if (heading)
    {
      place.m_position = Move(place.m_position, *heading + yawDeg / 2, distM);
      heading = Normalize(*heading + yawDeg);
    }
    else
    {
      // The way is not known, only how far the place may be.
      place.m_accuracyM += distM;
    }
  }
  place.m_bearingDeg = heading;
  return place;
}
}  // namespace nogps
