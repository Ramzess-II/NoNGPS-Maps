#pragma once

#include "geometry/latlon.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace nogps
{
/// Finds the hits of the wheels in holes of the road by the jolt of the box along `up`, see esp32::Data::m_jolt.
class PotholeDetector
{
public:
  // The road noise is under 4.1 m/s² 99.9% of the time, under 6.4 99.99%: 49 hits in 21 h of the trips of October.
  static double constexpr kJoltMs2 = 6;
  // A standing car feels a door slam, not a hole.
  static int constexpr kMinKmh = 10;
  // The front and the rear axle hit the same hole 0.1-0.3 s apart: the packets this long after the first one of a hit
  // are that hit.
  static int64_t constexpr kHitGapMs = 1000;

  struct Hit
  {
    double m_joltMs2 = 0;
    ms::LatLon m_place;
    int m_speedKmh = 0;
  };

  /// A packet of the box.
  /// \param place where the car is at the packet, nothing if it is not known to be on a road.
  /// \returns the packet of the largest jolt of a hit once kHitGapMs have passed since its first packet.
  std::optional<Hit> OnSample(int64_t timeMs, double joltMs2, int speedKmh, std::optional<ms::LatLon> const & place);

private:
  std::optional<Hit> m_hit;
  int64_t m_hitStartMs = 0;
};

struct Pothole
{
  ms::LatLon m_place;
  // The largest hit, percent of the range of the accelerometer, see PotholeStore::ToPct().
  int m_pct = 0;
  int m_hits = 0;
  int64_t m_lastUnixMs = 0;
};

/// The potholes the car has hit, kept on the phone.
class PotholeStore
{
public:
  // A hit this near to a pothole is that one: the error of the mark along the road and the two axles. The two ways of
  // a road may make one pothole.
  static double constexpr kMergeM = 15;
  // Then the pothole hit the longest ago is dropped.
  static size_t constexpr kMax = 5000;
  // ±4 g, the range the box sets by default (CONFIG_NOGPS_IMU_ACCEL_RANGE).
  static double constexpr kAccelFullScaleMs2 = 39.2;

  /// The strength of a hit, 0-100.
  static int ToPct(double joltMs2);

  struct Added
  {
    Pothole m_pothole;
    // The hit is in a known pothole.
    bool m_merged = false;
  };

  /// A hit: it updates the nearest pothole within kMergeM or makes a new one.
  Added Add(ms::LatLon const & place, int pct, int64_t unixMs);
  std::vector<Pothole> const & Get() const { return m_potholes; }

  /// The file has a pothole a line: "lat,lon,pct,hits,lastUnixMs". A missing file has none.
  void Load(std::string const & path);
  /// \returns false if the file can't be written.
  bool Save(std::string const & path) const;

private:
  std::vector<Pothole> m_potholes;
};
}  // namespace nogps
