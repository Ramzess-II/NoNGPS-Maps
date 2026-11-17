#pragma once

#include "map/nogps/esp32_protocol.hpp"

#include "geometry/latlon.hpp"

#include <cstdint>
#include <deque>
#include <optional>
#include <string>

namespace nogps
{
// The leader sends its place to the other phone on the box not more often than this, unless the user changes it.
int64_t constexpr kPeerSnapshotIntervalMs = 5000;
// A place is carried to now by what the box has counted since: this much of it is kept.
int64_t constexpr kPeerHistoryMs = 10'000;

/// The phone that changes the box leads the place, the other one follows. Both need the box to pass the places on.
enum class PeerRole
{
  None,
  Leading,
  Following,
};

std::string DebugPrint(PeerRole role);

/// What makes the phone send its place, see PeerSync::MakeMessage().
enum class PeerTrigger
{
  // The user has set the place: a tap, a reversal, a switch to another road.
  PlaceSet,
  // Good GPS has set the place.
  GpsPlace,
  // The leader tells its place now.
  Timer,
  // A good GPS position of the follower.
  GpsFix,
  // The leader has taken a correction of the follower.
  CorrectionTaken,
};

/// A place of the other phone carried to now.
struct PeerPlace
{
  // See esp32::Peer.
  char m_kind = 'A';
  char m_source = 'G';
  ms::LatLon m_position;
  std::optional<double> m_bearingDeg;
  double m_accuracyM = 0;
};

/// The place of the car as the phone shows it.
struct PeerOutPlace
{
  ms::LatLon m_position;
  std::optional<double> m_bearingDeg;
  double m_accuracyM = 0;
  // See esp32::Peer::m_source.
  char m_source = 'G';
};

/// Two phones on one box: what each sends to the other, and how a place of the other one is carried to now by the
/// rotation and the distance the box has counted since. Both phones get the same lines of the box, so the same
/// distance of the box is the same moment for both.
class PeerSync
{
public:
  /// A data line of the box: the totals since its start.
  void OnBoxData(int64_t nowMs, int64_t distMm, int64_t yawMdeg);
  /// The link to the box is lost or the box has restarted: the totals start anew.
  void Reset();

  /// \returns the message the phone in this role sends on this trigger, nothing if it sends none: only the leader sends
  /// anchors and snapshots, only the follower corrections and its GPS positions, and the follower sends its GPS only
  /// while the leader is in the manual mode. The places set by the user are sent at once, GPS once in
  /// kPeerSnapshotIntervalMs, a snapshot unless a place was sent half of it ago.
  std::optional<esp32::Peer> MakeMessage(PeerRole role, PeerTrigger trigger, int64_t nowMs, PeerOutPlace const & place);

  /// \returns the place of a message carried to now, nothing if this role doesn't take the message or the place is
  /// older than kPeerHistoryMs.
  std::optional<PeerPlace> OnReceived(PeerRole role, esp32::Peer const & peer);

  /// The leader is in the manual mode: its place is not from GPS.
  bool IsLeaderManual() const { return m_leaderManual; }
  /// The distance the box has counted by the last data line, nothing before it.
  std::optional<int64_t> GetDistMm() const;

private:
  struct Sample
  {
    int64_t m_timeMs;
    int64_t m_distMm;
    int64_t m_yawMdeg;
  };

  std::deque<Sample> m_samples;
  std::optional<int64_t> m_sentMs;
  bool m_leaderManual = false;
};
}  // namespace nogps
