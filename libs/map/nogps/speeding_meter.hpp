#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace nogps
{
/// A stretch of driving over the limit by more than the tolerance.
struct SpeedingEpisode
{
  int64_t m_unixTimeMs = 0;
  double m_durationS = 0;
  double m_distanceM = 0;
  // The limit and the speed at the moment the car was the farthest over it.
  int m_limitKmh = 0;
  int m_peakKmh = 0;
  int m_meanKmh = 0;
  // 1 for +20...40 over the limit, 2 for +40...60, 3 above.
  int m_band = 1;
};

/// The rated driving between two Event::TripStarted.
struct SpeedingTrip
{
  int64_t m_unixTimeMs = 0;
  double m_ratedM = 0;
  double m_ratedS = 0;
  // The seconds of the episodes, each times the weight of its band.
  double m_weightedS = 0;
  std::vector<SpeedingEpisode> m_episodes;

  /// The episodes of each band.
  std::array<int, 3> GetBandCounts() const;
  /// 0..100, 100 for no speeding. Needs some rated driving.
  int GetScore() const;
};

/// What the driver is rated by: the newest trips.
struct DrivingRating
{
  // Not shown before this much rated driving, see SpeedingMeter::kScoreMinKm.
  bool m_enough = false;
  int m_score = 100;
  // The driving the score is taken over.
  double m_ratedKm = 0;
  std::array<int, 3> m_bandCounts = {};
  // Newest first.
  std::vector<SpeedingTrip> m_trips;
};

/// "unixMs:ratedM:ratedS:weightedDs/episode;episode", an episode is "unixMs,durationDs,distanceM,limit,peak,mean,band".
std::string SerializeSpeedingTrip(SpeedingTrip const & trip);
/// Trips divided by "|".
std::string SerializeSpeedingTrips(std::vector<SpeedingTrip> const & trips);
/// \returns the trips of Storage::kSpeeding in their order (the oldest first), without the broken ones.
std::vector<SpeedingTrip> ParseSpeedingTrips(std::string_view trips);

/// \param trips the oldest first.
DrivingRating RateDriving(std::vector<SpeedingTrip> const & trips);

/// Counts the speeding of the driver, once a second. The driving is rated only where the car speed is fresh, the limit
/// of the road is a number and the mark can be trusted. An episode starts after kSpeedingStartS over the limit by
/// kSpeedingToleranceKmh, ends after kSpeedingEndS under it by kSpeedingToleranceKmh - kSpeedingHysteresisKmh.
class SpeedingMeter
{
public:
  static double constexpr kSpeedingToleranceKmh = 20;
  static double constexpr kSpeedingHysteresisKmh = 3;
  static int64_t constexpr kSpeedingStartS = 3;
  static int64_t constexpr kSpeedingEndS = 2;
  // An episode that starts this soon after the previous one is its continuation.
  static int64_t constexpr kSpeedingMergeS = 5;
  // A lower limit is in force after the car has driven this far under it: the driver slows down after the sign, and a
  // crossing road is caught by the snap for a moment.
  static double constexpr kLowerLimitGraceM = 150;
  // The weights of the bands, by the excess over the limit.
  static double constexpr kBand2Kmh = 40;
  static double constexpr kBand3Kmh = 60;
  static std::array<double, 3> constexpr kBandWeights = {1, 3, 8};
  // The score is 100 * exp(-W / kScoreScaleS), W is the weighted seconds of speeding per hour of rated driving.
  static double constexpr kScoreScaleS = 360;
  // The score is taken over the newest trips that add up to this much rated driving.
  static double constexpr kScoreWindowKm = 500;
  // It is shown from this much.
  static double constexpr kScoreMinKm = 20;
  // The trips kept.
  static size_t constexpr kMaxTrips = 100;
  // A longer pause between the samples breaks the driving.
  static int64_t constexpr kMaxGapMs = 2500;

  struct Sample
  {
    // From the clock that runs for the app, and the same moment in Unix time.
    int64_t m_timeMs = 0;
    int64_t m_unixTimeMs = 0;
    // The real speed, nothing if the car speed is not fresh.
    std::optional<double> m_kmh;
    // The limit of the road under the mark: -1 unknown, 0 no limit.
    int m_limitKmh = -1;
    bool m_trusted = false;
  };

  static int GetBand(double excessKmh);

  /// \returns the episodes that are finished.
  std::vector<SpeedingEpisode> OnSample(Sample const & sample);
  /// Finishes the episode that goes on, the next sample starts a new one.
  std::vector<SpeedingEpisode> Flush();
  /// \returns the trip and starts the next one, nothing if no driving was rated in it. Flush() first.
  std::optional<SpeedingTrip> CloseTrip();

  /// The trip so far, without the episode that goes on.
  SpeedingTrip const & GetTrip() const { return m_trip; }
  /// The limit the speed is compared with, nothing before the first rated second.
  std::optional<int> GetLimitKmh() const { return m_limit; }
  /// Whether the last sample was rated.
  bool IsRated() const { return m_rated; }

private:
  // The sums of a stretch over the limit.
  struct Stretch
  {
    int64_t m_startMs = 0;
    int64_t m_endMs = 0;
    int64_t m_unixTimeMs = 0;
    int64_t m_durationMs = 0;
    double m_distanceM = 0;
    double m_kmhMs = 0;
    double m_peakExcessKmh = -1000;
    double m_peakKmh = 0;
    int m_limitKmh = 0;

    void Add(double kmh, int limitKmh, int64_t dtMs, int64_t timeMs);
    void Merge(Stretch const & other);
  };

  void UpdateLimit(int limitKmh, double distanceM);
  void OnRated(Sample const & sample, int64_t dtMs, std::vector<SpeedingEpisode> & finished);
  // The rated driving ends: the episode that goes on is over.
  void EndRated(std::vector<SpeedingEpisode> & finished);
  void FinishEpisode(std::vector<SpeedingEpisode> & finished);
  void Emit(Stretch const & stretch, std::vector<SpeedingEpisode> & finished);
  // The held episode is done when no continuation can come any more.
  void Release(int64_t nowMs, std::vector<SpeedingEpisode> & finished);

  SpeedingTrip m_trip;
  std::optional<int64_t> m_prevMs;
  bool m_rated = false;
  std::optional<int> m_limit;
  double m_lowerLimitM = 0;
  // Over the limit by the tolerance, and for how long (an episode is confirmed after kSpeedingStartS).
  std::optional<Stretch> m_over;
  bool m_confirmed = false;
  // Under the end threshold since this time, with what the car did there: it comes back into the episode if the car
  // speeds up again.
  std::optional<Stretch> m_under;
  // The finished episode, waiting for a continuation.
  std::optional<Stretch> m_held;
};
}  // namespace nogps
