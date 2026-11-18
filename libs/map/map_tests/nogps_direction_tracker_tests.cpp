#include "testing/testing.hpp"

#include "map/map_tests/nogps_test_env.hpp"
#include "map/nogps/accel_speed.hpp"
#include "map/nogps/direction_tracker.hpp"
#include "map/nogps/speed_lag.hpp"

namespace nogps_direction_tracker_tests
{
using namespace nogps;

// The tracker without the engine: the marks are replaced by counters.
struct Env
{
  nogps_test::TestClock m_clock;
  SpeedLag m_lag;
  AccelSpeed m_accel;
  int m_turned = 0;
  int m_forgotten = 0;
  DirectionTracker m_tracker{m_clock, m_lag, m_accel, [this](int turned) { m_turned += turned; },
                             [this]() { ++m_forgotten; }};
};

UNIT_TEST(NoGps_DirectionTracker_ForwardWithoutAccelerometer)
{
  Env env;
  // The accelerometer tells nothing about a start: it is a start forward.
  for (int i = 0; i < 20; ++i)
  {
    env.m_tracker.OnSpeed(10, 0);
    env.m_clock.Advance(100);
  }
  TEST_EQUAL(env.m_tracker.GetDirection(), 1, ());
  TEST(!env.m_tracker.IsDrivingBack(), ());
  TEST_EQUAL(env.m_turned, 0, ());
  TEST_EQUAL(env.m_forgotten, 0, ());
}

UNIT_TEST(NoGps_DirectionTracker_BackwardTurnsStartSegment)
{
  Env env;
  env.m_tracker.OnSpeed(3, 0);
  env.m_tracker.SetDirection(-1);
  // What was driven since the start was counted forward: it is turned to backward, i.e. by 2 of its length.
  TEST_EQUAL(env.m_turned, -2, ());
  TEST_EQUAL(env.m_forgotten, 1, ());
  TEST(env.m_tracker.IsDrivingBack(), ());
  // The same way again changes nothing.
  env.m_tracker.SetDirection(-1);
  TEST_EQUAL(env.m_turned, -2, ());
  TEST_EQUAL(env.m_forgotten, 1, ());
}

UNIT_TEST(NoGps_DirectionTracker_StandAndFastDriveForward)
{
  Env env;
  env.m_tracker.OnSpeed(3, 0);
  env.m_tracker.SetDirection(-1);
  // A car that drives fast has driven forward since the start.
  env.m_tracker.OnSpeed(DirectionTracker::kMaxBackSpeedKmh, 0);
  TEST_EQUAL(env.m_tracker.GetDirection(), 1, ());
  TEST_EQUAL(env.m_turned, 0, ());

  env.m_tracker.SetDirection(-1);
  TEST(env.m_tracker.IsDrivingBack(), ());
  // A standing car is ready to drive forward.
  env.m_tracker.OnSpeed(0, 0);
  TEST_EQUAL(env.m_tracker.GetDirection(), 1, ());
  TEST(env.m_tracker.GetStandMs().has_value(), ());
}

UNIT_TEST(NoGps_DirectionTracker_DrivenBackLately)
{
  Env env;
  TEST(!env.m_tracker.HasDrivenBackLately(), ());
  env.m_tracker.OnDrivingBack(env.m_clock.NowMs());
  TEST(env.m_tracker.HasDrivenBackLately(), ());
  env.m_clock.Advance(DirectionTracker::kAccelAfterBackMs + 1);
  TEST(!env.m_tracker.HasDrivenBackLately(), ());
  env.m_tracker.OnDrivingBack(env.m_clock.NowMs());
  env.m_tracker.ForgetLastBack();
  TEST(!env.m_tracker.HasDrivenBackLately(), ());
}
}  // namespace nogps_direction_tracker_tests
