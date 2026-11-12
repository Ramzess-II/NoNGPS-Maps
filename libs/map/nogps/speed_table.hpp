#pragma once

#include <array>
#include <optional>
#include <string>
#include <string_view>

namespace nogps
{
/// How much the speed from the car differs from the real one at different speeds: the speedometer error grows
/// with the speed, and the speed is rounded to 1 km/h, which matters at low speeds. The real speed is taken from
/// trusted GPS while it works, the table is kept between trips and used without GPS.
/// The speeds are split into ranges, every range keeps the distance driven by the car speed and by GPS, and the time.
/// A car that cuts its speed down to whole km/h is slower by a constant, which a ratio can't follow at low speeds: the
/// real speed is the ratio of the range times the car speed plus an offset, learned from GPS.
class SpeedTable
{
public:
  static int constexpr kRangeKmh = 10;
  static int constexpr kRanges = 14;
  // Slower speeds are rounded too roughly, the car maneuvers, and GPS speed is noisy.
  static int constexpr kMinSpeedKmh = 5;
  // A range is used after this distance only: a short one is dominated by the noise.
  static double constexpr kMinDistanceM = 300;
  // Older samples are forgotten gradually, e.g. after new tyres.
  static double constexpr kMaxDistanceM = 10'000;
  // GPS is compared with the car at a steady speed: the car reports its speed later than GPS.
  static double constexpr kMaxAccelerationMps2 = 1;
  // A longer pause between samples is a break.
  static double constexpr kMaxSampleDtSec = 2;
  // A GPS speed this far from the car speed is wrong: 200 km/h of spoofed GPS at 7 km/h raised the 0-10 km/h range
  // from 1.02 to 1.08 in a few samples. Of 17 thousand real samples of 10-26..11-04, under 1% are farther.
  static double constexpr kMaxSpeedDiffKmh = 3;
  static double constexpr kMaxSpeedDiffRatio = 0.15;
  static double constexpr kMinScale = 0.8;
  static double constexpr kMaxScale = 1.25;
  // Cut down to whole km/h, the speed is 0.5 km/h slower on average. On 2026-11-11..12 such a car was 0.5 km/h and 1%
  // slower: the table had 1.08 at 5-10 km/h, 1.02 at 50-60, and 1.2-1.5 was right at 1-4 km/h.
  static double constexpr kMaxOffsetKmh = 0.5;
  // The offset is a straight line through the mean speeds of the ranges below 50 km/h, the 5-10 km/h one among them:
  // a line through faster ranges only is too far from 0, and the table follows the error of faster speeds.
  static int constexpr kOffsetRanges = 5;

  /// \param learnsOffset the roads tell a distance too roughly for the offset, only GPS learns it.
  explicit SpeedTable(bool learnsOffset = true) : m_learnsOffset(learnsOffset) {}

  /// One range as the user sees it.
  struct RangeState
  {
    // The distance driven by the car speed.
    double m_carM = 0;
    // The ratio, 0 until the range is measured.
    double m_scale = 0;
  };
  using Ranges = std::array<RangeState, kRanges>;

  /// \returns true if the car speed and the real one measured at the same time tell the error of the car speed.
  static bool IsGoodSample(double carSpeedKmh, double gpsSpeedMps, double dtSec, double accelerationMps2);

  /// Takes into account the car speed and the real one measured at the same time.
  /// \param dtSec how long the speeds lasted.
  /// \param accelerationMps2 how fast the real speed changes.
  void OnSample(double carSpeedKmh, double gpsSpeedMps, double dtSec, double accelerationMps2);

  /// Takes into account a distance driven in the range of the speed, measured otherwise than by GPS.
  /// \param carM the distance by the car speed, \param realM the real one.
  void OnDistance(double carSpeedKmh, double carM, double realM);

  /// \returns the range of the speed.
  static int Range(double carSpeedKmh);

  /// \returns the ratio the car speed is multiplied by, the offset included, nothing if nothing is known yet. A speed
  /// not measured yet is interpolated from the closest measured ones.
  std::optional<double> GetScale(double carSpeedKmh) const;

  /// \returns the km/h added to the car speed before the ratio of its range, 0 to kMaxOffsetKmh.
  double GetOffsetKmh() const;

  /// \returns how many speed ranges are measured.
  int GetKnownRanges() const;
  /// \returns every range with its distance and its ratio, the offset included at its mean speed, not interpolated.
  Ranges GetRanges() const;

  void Clear();

  /// \returns the table to keep between trips: the car and GPS distances and the time of every range.
  std::string Serialize() const;
  /// Restores the table kept before, a broken one is ignored.
  void Deserialize(std::string_view table);

  /// \returns the measured ranges for the log: speed and ratio without the offset, then the offset if any.
  std::string ToString() const;

private:
  bool IsKnown(int i) const { return m_carM[i] >= kMinDistanceM; }
  // The ratio of the range to the car speed plus |offsetKmh|.
  double ScaleOf(int i, double offsetKmh) const;
  std::optional<double> InterpolateScale(int i, double offsetKmh) const;

  bool m_learnsOffset;
  std::array<double, kRanges> m_carM{};
  // The real distance: by GPS, or by the roads for a rough table.
  std::array<double, kRanges> m_gpsM{};
  std::array<double, kRanges> m_sec{};
};

/// A change of the speed error common to all speeds, e.g. other tyres or the cold: the table keeps the error of every
/// speed over 5-10 km of it, which a rarely driven speed takes weeks to drive, and this follows the last kilometers
/// at any speed. On November 6, 2026 the error changed by 1.2% overnight, and the table still ran 1% ahead a day later.
class SpeedFactor
{
public:
  // Used after this distance only, older distances are forgotten gradually: the factor follows the last 2.5-5 km.
  // The trips of October 11 - November 7 driven again with 2 km: the factor went 0.99-1.013 on the October days,
  // where the table was right, and put the mark 15 m ahead before a fork on October 22.
  static double constexpr kMinDistanceM = 1500;
  static double constexpr kMaxDistanceM = 5000;
  // The error of the table changes by 1-2%, a larger factor is a wrong measurement.
  static double constexpr kMinFactor = 0.95;
  static double constexpr kMaxFactor = 1.05;
  // A GPS speed farther than this from the speed by the table is a wrong one: the error changes by 1-2%. The car
  // speed is whole km/h. On November 8 GPS was 10% faster for 40 s, it moved the factor by 1.1% and the mark ran
  // 53 m ahead.
  static double constexpr kMaxSampleDiffRatio = 0.04;
  static double constexpr kMaxSampleDiffKmh = 1.5;

  /// \returns true if a GPS speed may tell the factor, |expectedKmh| is the car speed by the table.
  static bool IsGoodSample(double expectedKmh, double gpsKmh);

  /// Takes into account a distance driven: |expectedM| by the car speed and the table, |realM| the real one.
  void OnDistance(double expectedM, double realM);

  /// \returns the ratio the speed by the table is multiplied by.
  double Get() const;

  void Clear();
  std::string Serialize() const;
  /// Restores the factor kept before, a broken one is ignored.
  void Deserialize(std::string_view factor);

private:
  double m_expectedM = 0;
  double m_realM = 0;
};
}  // namespace nogps
