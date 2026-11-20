#pragma once

#include "geometry/latlon.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace nogps
{
/// Detects jammed/spoofed GNSS positions (e.g. electronic warfare moves the phone to another continent).
/// A satellite position is not trusted when it contradicts the network (cell towers and Wi-Fi) position,
/// or when it jumps farther than any car could drive since the last trusted satellite position, or when its speed
/// disagrees with the car speed for several points in a row.
/// After a detection, satellite positions are trusted again only after several consecutive consistent ones.
/// All the times are monotonic, e.g. elapsed realtime.
class GpsSpoofingDetector
{
public:
  // Network positions older than this are not used to verify satellite positions.
  static int64_t constexpr kNetworkMaxAgeMs = 3 * 60 * 1000;
  // Network positions are coarse (up to several km in the countryside), so smaller mismatches are ignored.
  static double constexpr kNetworkMinToleranceM = 3000;
  static double constexpr kNetworkAccuracyFactor = 3;
  // Faster than any car on Ukrainian roads, used to estimate how far the user could move between positions.
  static double constexpr kMaxSpeedMps = 300 / 3.6;
  // Jumps shorter than this are GPS noise rather than spoofing.
  static double constexpr kMinJumpM = 1000;
  static int constexpr kConsistentPositionsToRecover = 5;
  // Without the network only the last trusted position is available, so be more careful.
  static int constexpr kConsistentPositionsToRecoverWithoutNetwork = 10;
  // A network position is sometimes kilometers away, e.g. from a Wi-Fi point that has moved or a cell tower with a
  // wrong location in the database. Such a cell tower gives the same point again and again, so a jump is used only
  // when a network position at another point near it confirms it, or when nothing contradicts it for this long.
  static int64_t constexpr kJumpConfirmMs = kNetworkMaxAgeMs;
  // Positions from the same cell tower or Wi-Fi point.
  static double constexpr kSamePointM = 10;
  // Points that jumped away and back are ignored. They are saved, as after a restart such a point may be the only
  // one.
  static size_t constexpr kMaxPhantoms = 16;
  // A Wi-Fi position (tens of meters) is used at once after a coarse cell tower one (hundreds of meters).
  static double constexpr kMoreAccurateFactor = 2;

  // Network positions are wrong by kilometers, up to several tens: so the first one after the start, that nothing
  // has confirmed, is believed over a satellite position only when they are farther apart than this.
  static double constexpr kUnconfirmedNetworkToleranceM = 50'000;

  // A GPS speed is compared with the car speed when it differs by more than both of these: the car speed lags
  // behind GPS by about a second, so a smaller difference is just an acceleration.
  static double constexpr kSpeedMismatchKmh = 15;
  static double constexpr kSpeedMismatchFactor = 0.3;
  static int constexpr kSpeedMismatchFixes = 5;
  // Less accurate points are not compared: their speed is noise.
  static double constexpr kSpeedMaxAccuracyM = 30;
  // The speed from two points is taken when they are this far apart in time.
  static int64_t constexpr kSpeedMinGapMs = 500;
  static int64_t constexpr kSpeedMaxGapMs = 3000;

  // The network is not believed over GPS that has agreed with the car speed and the inertial position for this
  // many points in a row while the car drives: the network point is wrong, a car can't fake both.
  static int constexpr kAgreeingFixesToTrust = 30;
  static double constexpr kAgreeingMinSpeedMps = 5;
  // A longer break between satellite points (a tunnel, no GPS) restarts the count.
  static int64_t constexpr kAgreeingMaxGapMs = 10000;

  struct Trusted
  {
    ms::LatLon m_position;
    int64_t m_timeMs = 0;
  };

  bool IsSpoofed() const { return m_spoofed; }

  /// \returns the wrong network points as "lat,lon;lat,lon".
  std::string SerializePhantoms() const;
  void DeserializePhantoms(std::string_view phantoms);
  size_t GetPhantomsCount() const { return m_phantoms.size(); }

  /// \returns the last trusted satellite or network position.
  std::optional<Trusted> GetLastTrusted() const;
  /// Restores the position trusted before the app restarted, as after a restart a spoofed position may come first.
  /// \param timeMs may be negative if it was before the device restart.
  void RestoreTrusted(ms::LatLon const & position, int64_t timeMs);

  /// \returns false if the position jumped away and is ignored.
  bool OnNetworkPosition(ms::LatLon const & position, double accuracyM, int64_t timeMs);

  /// Checks a satellite (or fused) position.
  /// \param gpsSpeedMps the speed of the point, or nothing: then it is taken from the previous point.
  /// \param carSpeedMps the fresh car speed, or nothing if it is unknown: then the speed is not checked.
  /// \param checkSpeed false for a provider whose points are not one chain with the others (Fused next to Gps): the
  /// speed derived from the previous point would be wrong, and the speed counter stays as it is.
  /// \param nearInertial the position is near the inertial one: with the speed agreeing for kAgreeingFixesToTrust
  /// points it makes GPS right whatever the network tells. A point away from the inertial one drops that count and
  /// is never trusted by it, as a coarse point's speed is not compared at all.
  /// \returns true if the position can be trusted.
  bool CheckSatellitePosition(ms::LatLon const & position, int64_t timeMs, double accuracyM = 0,
                              std::optional<double> gpsSpeedMps = {}, std::optional<double> carSpeedMps = {},
                              bool checkSpeed = true, bool nearInertial = false);

private:
  struct Network
  {
    ms::LatLon m_position;
    double m_accuracyM = 0;
    int64_t m_timeMs = 0;
  };

  struct Jump
  {
    ms::LatLon m_position;
    double m_accuracyM = 0;
    int64_t m_timeMs = 0;
  };

  void AddPhantom(ms::LatLon const & position);
  bool AcceptNetworkPosition(ms::LatLon const & position, double accuracyM, int64_t timeMs);
  /// \returns true if a trusted satellite position, fresh at timeMs, is within the accuracy of the point.
  bool AgreesWithSatellite(ms::LatLon const & position, double accuracyM, int64_t timeMs) const;
  /// \returns true if a trusted satellite position, newer than the jump and fresh at timeMs, is farther from the
  /// point than the network tolerance: the point is wrong, whatever the time says.
  bool ContradictsSatellite(ms::LatLon const & position, double accuracyM, int64_t timeMs) const;
  /// Drops the network position that a satellite position contradicts, or confirms it.
  void CheckUnconfirmedNetwork(ms::LatLon const & position, int64_t timeMs);
  bool IsConsistent(ms::LatLon const & position, int64_t timeMs) const;
  bool HasFreshNetwork(int64_t timeMs) const;
  void SetTrusted(ms::LatLon const & position, int64_t timeMs);
  /// \returns whether the speed agrees with a drive of the car, nothing if there was nothing to compare.
  std::optional<bool> CheckSpeed(ms::LatLon const & position, int64_t timeMs, double accuracyM,
                                 std::optional<double> gpsSpeedMps, std::optional<double> carSpeedMps);

  std::optional<Network> m_network;
  std::optional<Trusted> m_trusted;
  // The previous satellite point, trusted or not.
  std::optional<Trusted> m_previous;
  int m_speedMismatchCount = 0;
  int m_agreeingCount = 0;
  bool m_spoofed = false;
  int m_consistentCount = 0;
  // The first network position of a jump away from the last trusted one, waiting for a confirmation.
  std::optional<Jump> m_jump;
  // m_network is the first one since the start: no other network point or satellite position has confirmed it.
  bool m_networkUnconfirmed = false;
  std::vector<ms::LatLon> m_phantoms;
  // Several providers report the same network position.
  std::optional<int64_t> m_lastNetworkTimeMs;
  bool m_lastNetworkAccepted = false;
};
}  // namespace nogps
