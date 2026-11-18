#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace nogps
{
enum class SprintKind
{
  // 0-100 km/h.
  To100,
  // A quarter mile from a standing start.
  QuarterMile,
};

std::string DebugPrint(SprintKind kind);

/// A timed run kept for the car.
struct Sprint
{
  SprintKind m_kind = SprintKind::To100;
  int64_t m_unixTimeMs = 0;
  // Rounded to 0.01 s.
  double m_sec = 0;
  // The speed at the end of the quarter mile, 0 for 0-100 km/h.
  int m_trapKmh = 0;
};

/// "kind:unixMs:centisec:trapKmh", see Storage::kSprints.
std::string SerializeSprint(Sprint const & sprint);
/// \returns the runs of Storage::kSprints in their order, without the broken ones.
std::vector<Sprint> ParseSprints(std::string_view sprints);

/// Times the runs from a standing start by the car speed: 0-100 km/h and the quarter mile. A run starts at the last
/// sample of 0 km/h before the speed rises, a rolling start is not a run. The car reports its speed late, but the
/// whole run is shifted by the same lag, so it cancels out.
class SprintTimer
{
public:
  static double constexpr kTo100Kmh = 100;
  static double constexpr kSprintMaxSec = 15;
  static double constexpr kQuarterMileM = 402.336;
  // A normal start that cruises at 60 km/h takes about 27 s.
  static double constexpr kQuarterMaxSec = 25;
  static double constexpr kQuarterMinTrapKmh = 100;
  // The driver has lifted: what the run hasn't finished is thrown away.
  static double constexpr kSprintDropKmh = 5;
  // A longer pause between the samples ends the run, as InertialNavigator::kSpeedStaleMs.
  static int64_t constexpr kSpeedStaleMs = 2000;
  // The box repeats a speed sample in its lines until the next one, 100 ms later: a sample this close to the last one
  // with the same speed is that one again.
  static int64_t constexpr kMinSampleGapMs = 50;

  struct Result
  {
    SprintKind m_kind = SprintKind::To100;
    double m_sec = 0;
    // The speed at the end of the quarter mile, 0 for 0-100 km/h.
    double m_trapKmh = 0;
  };

  /// \param kmh the real speed: the car speed corrected by the speed table.
  /// \returns the results the sample has finished.
  std::vector<Result> OnSample(double kmh, int64_t timeMs);

private:
  struct Sample
  {
    double m_kmh = 0;
    int64_t m_timeMs = 0;
  };
  struct Run
  {
    int64_t m_startMs = 0;
    double m_distanceM = 0;
    double m_maxKmh = 0;
    bool m_to100Done = false;
    bool m_quarterDone = false;
  };

  std::optional<Sample> m_last;
  std::optional<Run> m_run;
};
}  // namespace nogps
