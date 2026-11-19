#pragma once

#include "map/nogps/accel_speed.hpp"
#include "map/nogps/clock.hpp"
#include "map/nogps/speed_lag.hpp"

#include <cstdint>
#include <functional>
#include <optional>
#include <utility>

namespace nogps
{
/// Tells which way the car drives, forward or backward, by the accelerometer of the box and the car speed, which has
/// no sign. It depends on the car speed, the accelerometer, the clock and the way driven only: what the way changes
/// in the marks is done by the owner through the two functions it passes.
class DirectionTracker
{
public:
  // Nobody drives backwards this fast.
  static int constexpr kMaxBackSpeedKmh = 15;
  // The car speed has no sign. Which way the car has started, the accelerometer of the box tells: the speed it
  // has felt since the car stood, by the time the car reports that it moves and a little later. The car reports
  // its speed late by the lag, so it stood for sure from when it has reported 0 until the lag and a margin before it
  // has reported that it moves. A stand of 1.5 s between driving back and forth was too short to feel that way, on
  // October 16 at 23:28 and October 18 at 21:23: a stand too short is taken from up to the lag before the report of
  // 0, with the margin, only as much as it needs. Taken so always, the braking before a stand of 3 s was felt as
  // standing on October 11 at 23:55:22, and a start backward was told forward. On the trips checked 43 of 50 starts
  // were felt as 0.5 m/s forward or more, 4 at a parking place as 0.3 m/s backward or more, 3 were in between.
  static double constexpr kReverseStartSpeedMps = 0.3;
  static int64_t constexpr kStartFeltAfterMs = 300;
  static int64_t constexpr kStandMarginMs = 300;
  // What the accelerometer feels while the car stands is taken from this time at most and at least.
  static int64_t constexpr kMaxStandFeltMs = 2000;
  static int64_t constexpr kMinStandFeltMs = 300;
  // A car changing the gear stands for a moment, but the speed it reports may not reach 0 then: on October 18 at
  // 21:23:40 it reported 1 km/h for 1.4 s between driving backwards and forward. The speed rising again after it
  // is a start too, told by what was felt at the last stand, but it only ends driving backwards: a car slowing down
  // and speeding up forward was felt as driving backwards on October 11 at 12:58:55, and was driven so for 2 min.
  static int constexpr kSlowSpeedKmh = 1;
  // A car maneuvering at a parking place stands for a second between driving back and forth, too short to feel
  // it standing: what was felt at its last longer stand is taken, while the car is about there and the slope
  // under it is the same. On the trips checked every such start was within 20 s and 16 m of that stand.
  static int64_t constexpr kKeepStandFeltMs = 30'000;
  static double constexpr kKeepStandFeltM = 20;
  // The first jerk of a start tells the wrong way sometimes, e.g. of a car rolling back before it starts uphill.
  // For this long after the start the speed the accelerometer has felt is compared with the one the car reports,
  // which is the speed of the lag ago. Felt clearly the other way for a while, the car drives the other way. Felt
  // much faster than the car reports, it is the slope that has changed under the car: on a ramp going down a car
  // driving forward is felt as driving backwards 3 s after its start, so only the first seconds tell that. On
  // the trips of October 11-12 GPS has seen the way of 43 starts: 33 were told right before, 41 with this.
  static int64_t constexpr kStartCheckMs = 4000;
  static int64_t constexpr kStartCheckBackMs = 2000;
  static int64_t constexpr kStartCheckHoldMs = 500;
  static double constexpr kMinFeltSpeedRatio = 0.5;
  static double constexpr kMaxFeltSpeedRatio = 2;
  static double constexpr kMaxFeltSpeedExtraMps = 0.5;
  // A crawling car reports its first 1 km/h without the lag, and may drive backwards only later: on November 13 at
  // 19:24:36 it rolled forward a little when shifted into reverse, reported 1 km/h, and was felt backing only from
  // 0.15 s after its start, at about 4 km/h. Till the lag ago 0.5 s of that pull was summed in the first 2 s, too
  // little: the car was followed apart and its road was lost. While it reports up to this speed, a start backward
  // is told by what was felt till now, for longer. Summed for that long, a jerk or a slope tells the wrong way more
  // often: not after a start felt clearly forward (October 19 at 07:55:51, +1.4 m/s, then braking), nor with the stand
  // taken from before (October 15 at 09:47:12, the car then drove 85 m forward).
  static int constexpr kCrawlSpeedKmh = 5;
  static int64_t constexpr kCrawlCheckBackMs = 4000;
  static double constexpr kCrawlClearForwardMps = 0.5;
  // The stop of a slow segment is a clearer pull than its start: a car driving forward brakes with a pull backward,
  // and one driving backward with a pull forward. Where the start of a segment was not felt clearly, the way told by
  // the speed felt while it braked, against the stand felt after, turns the segment if it is felt this clearly the
  // other way. Only a short and slow segment is checked: braking hard on a ramp or over a curb looks like a pull.
  // On the trips of November 14-15 the sign of the pull matched the way in 6 stops of 6.
  static double constexpr kStopFeltSpeedMps = 0.5;
  static int constexpr kStopCheckMaxKmh = 8;
  static double constexpr kStopCheckMaxM = 30;
  static int64_t constexpr kStopBrakeMs = 2000;
  // The accelerometer is compared with the last seconds of the car speed, which has no sign: it is not learned
  // from and doesn't tell how much faster the car is while the car drives backwards and for this time after it.
  // A start backward is not always told, so it is learned from at a speed nobody drives backwards at only: a
  // parking maneuver has made it useless for the next 6 minutes of a trip.
  static int64_t constexpr kAccelAfterBackMs = 7000;

  /// \param moveStartSegment moves the marks and the cars by |turned| times what the car has driven since its start.
  /// \param forgetWay forgets what was learned of the way driven forward: the car drives backwards.
  DirectionTracker(Clock const & clock, SpeedLag const & lag, AccelSpeed const & accel,
                   std::function<void(int turned)> moveStartSegment, std::function<void()> forgetWay)
    : m_clock(clock)
    , m_lag(lag)
    , m_accel(accel)
    , m_moveStartSegment(std::move(moveStartSegment))
    , m_forgetWay(std::move(forgetWay))
  {}

  /// The way the car drives since its last start: 1 forward, -1 backward.
  int GetDirection() const { return m_direction; }
  bool IsDrivingBack() const { return m_direction < 0; }
  /// Since when the car reports that it stands.
  std::optional<int64_t> const & GetStandMs() const { return m_standMs; }
  /// Driven since the start, either way, and how far the mark of the car was moved for that.
  double GetStartM() const { return m_startM; }
  double GetStartMarkM() const { return m_startMarkM; }
  void AddStartM(double meters) { m_startM += meters; }
  void AddStartMarkM(double meters) { m_startMarkM += meters; }

  /// Call it when the car reports its speed. \param speedKmh the speed it reports, \param pathM all the car has
  /// driven.
  void OnSpeed(int speedKmh, double pathM);
  /// Nothing is known about the way the car drives: it drives forward.
  void Reset();
  void SetDirection(int direction);
  /// The car has driven backwards at |nowMs|.
  void OnDrivingBack(int64_t nowMs) { m_lastBackMs = nowMs; }
  void ForgetLastBack() { m_lastBackMs.reset(); }
  bool HasDrivenBackLately() const;

private:
  void StartStopCheck();
  void CheckStop();

  Clock const & m_clock;
  SpeedLag const & m_lag;
  AccelSpeed const & m_accel;
  std::function<void(int)> m_moveStartSegment;
  std::function<void()> m_forgetWay;

  // The way the car drives since its last start: 1 forward, -1 backward. A standing car is ready to drive forward.
  int m_direction = 1;
  // Since when it reports that it stands, and when it has reported that it moves after that.
  std::optional<int64_t> m_standMs;
  std::optional<int64_t> m_startMs;
  // It has driven faster than kSlowSpeedKmh since the start, and since when it reports that speed or slower.
  bool m_fasterSinceStart = false;
  std::optional<int64_t> m_slowMs;
  // The start is the speed rising again after it, the car didn't report that it stands. It had that speed the way it
  // drove then, m/s with the sign.
  bool m_startAfterSlow = false;
  double m_startFromMps = 0;
  // The way of the start is told by the accelerometer already.
  bool m_startFelt = true;
  // The start may be told backward by what was felt till now while the car crawls.
  bool m_crawlCheck = false;
  // Until when the car stood for sure before that start.
  int64_t m_startStandToMs = 0;
  // What the accelerometer of the box has felt along the car standing, m/s2: at the last stand long enough to
  // feel it, when that was and what the car had driven by then.
  std::optional<double> m_standAccel;
  int64_t m_standAccelMs = 0;
  double m_standAccelPathM = 0;
  // Since when the accelerometer feels the car driving the other way than it is known to drive.
  std::optional<int64_t> m_otherWayMs;
  // Driven since the start, either way, and how far the mark of the car was moved for that.
  double m_startM = 0;
  double m_startMarkM = 0;
  // The segment since the start: the speed felt at its start, m/s with the sign, its top speed and when it was
  // reported.
  double m_startFeltMps = 0;
  int m_segMaxKmh = 0;
  int64_t m_segPeakMs = 0;
  // A slow segment that has ended is checked by its stop when the stand after it is felt: the way it was told, the
  // time it has stopped, the time its braking is summed from and its top speed.
  struct StopCheck
  {
    int m_way;
    int64_t m_stopMs;
    int64_t m_brakeFromMs;
    double m_peakMps;
  };
  std::optional<StopCheck> m_stopCheck;
  // When it drove backwards the last time.
  std::optional<int64_t> m_lastBackMs;
};
}  // namespace nogps
