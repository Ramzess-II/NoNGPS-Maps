#include "testing/testing.hpp"

#include "map/map_tests/nogps_test_env.hpp"

#include "map/nogps/accel_speed.hpp"
#include "map/nogps/box_car_values.hpp"
#include "map/nogps/engine.hpp"
#include "map/nogps/esp32_protocol.hpp"
#include "map/nogps/geo.hpp"
#include "map/nogps/speed_lag.hpp"
#include "map/nogps/speed_table.hpp"
#include "map/nogps/storage.hpp"

#include "base/logging.hpp"
#include "base/math.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace nogps_engine_tests
{
using namespace nogps;
using namespace nogps_test;

int constexpr kCalibratedFlags = esp32::kFlagImuOk | esp32::kFlagBiasOk | esp32::kFlagUpOk | esp32::kFlagObdOk;

class Env
{
public:
  /// \param roads the roads instead of the grid of streets.
  /// \param save what the application has saved before the start.
  explicit Env(bool inertial, Roads * roads = nullptr, std::function<void(TestStorage &)> const & save = {})
  {
    // The inertial navigation takes the roads when it starts.
    m_map.m_roads = roads;
    m_storage.Set(Storage::kInertialEnabled, inertial);
    if (save)
      save(m_storage);
    m_engine.Start();
    ConnectBox();
  }

  /// The platform has found the box and has connected to it.
  void ConnectBox(std::string const & boxId = {}) { m_engine.OnEsp32BleState(BleState::Connected, false, boxId); }

  /// The ESP32 box sends its data 50 times a second for |ms|: the car drives at |speedKmh| turning at |yawRateDegS|,
  /// clockwise is positive.
  void Drive(int64_t ms, int speedKmh, double yawRateDegS, int flags = kCalibratedFlags, int shakePct = -1)
  {
    for (int64_t t = 0; t < ms; t += 20)
    {
      m_clock.Advance(20);
      m_boxTimeMs += 20;
      m_yawMdeg += yawRateDegS * 20;
      m_distMm += speedKmh / 3.6 * 20;
      m_engine.OnEsp32BleBytes(BoxDataLine(++m_seq, m_boxTimeMs, std::llround(m_yawMdeg), speedKmh, flags,
                                           std::llround(m_distMm), shakePct));
    }
  }

  /// A line of the box with the accelerations: the car at |speedKmh| feels the jolt along `up`.
  void Jolt(int speedKmh, double joltMs2)
  {
    m_clock.Advance(20);
    m_boxTimeMs += 20;
    m_distMm += speedKmh / 3.6 * 20;
    char body[160];
    std::snprintf(body, sizeof(body), "NGD,1,%lld,%lld,%lld,0,%lld,%d,0,%X,0,0,0,%d", static_cast<long long>(++m_seq),
                  static_cast<long long>(m_boxTimeMs), std::llround(m_yawMdeg), std::llround(m_distMm), speedKmh,
                  kCalibratedFlags, static_cast<int>(joltMs2 * 1000));
    m_engine.OnEsp32BleBytes(BoxLine(body));
  }

  /// GPS positions every second for |seconds| at |speedMps| from the point, going east along the street.
  void DriveGps(int seconds, double eastM, double speedMps)
  {
    for (int i = 0; i < seconds; ++i)
    {
      m_clock.Advance(1000);
      m_engine.OnFix(GpsAt(m_clock, eastM + i * speedMps, 0, 90.0, speedMps));
    }
  }

  /// The box starts again: it counts its lines, time and rotation from the start.
  void RestartBox()
  {
    m_seq = 0;
    m_boxTimeMs = 0;
    m_yawMdeg = 0;
    m_distMm = 0;
  }

  /// The box sends nothing, |ms| pass by its clock.
  void SleepBox(int64_t ms) { m_boxTimeMs += ms; }

  /// The lines of the box are lost for |ms| while the car turns on at |yawRateDegS|.
  void LoseBoxLines(int64_t ms, double yawRateDegS)
  {
    m_clock.Advance(ms);
    m_boxTimeMs += ms;
    m_yawMdeg += yawRateDegS * ms;
  }

  Fix const & Last() const { return m_delegate.m_positions.back(); }

  TestClock m_clock;
  TestStorage m_storage;
  TestDelegate m_delegate;
  TestMap m_map;
  Engine m_engine{m_delegate, m_map, m_storage, m_clock, m_clock};

private:
  int64_t m_seq = 0;
  int64_t m_boxTimeMs = 100'000;
  double m_yawMdeg = 0;
  double m_distMm = 0;
};

void TestAlmostEqualAbs(double actual, double expected, double eps)
{
  TEST_ALMOST_EQUAL_ABS(actual, expected, eps, ());
}

// The car is marked on the street going east, the box tells it stands.
void MarkCar(Env & env, double eastM)
{
  env.m_engine.SetManualMode(true);
  env.Drive(500, 0, 0);
  TEST(env.m_engine.PlaceMarkByTap(At(eastM, 3)), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Manual, ());
  TestAlmostEqualAbs(East(env.Last().m_position), eastM, 0.5);
}

/// The engine of a user who has set nothing but what the test saves before the start.
struct NewUser
{
  nogps::Status Start()
  {
    m_engine.Start();
    return m_engine.GetStatus();
  }

  TestClock m_clock;
  TestStorage m_storage;
  TestDelegate m_delegate;
  TestMap m_map;
  Engine m_engine{m_delegate, m_map, m_storage, m_clock, m_clock};
};

UNIT_TEST(NoGps_Engine_LooksForBoxOverBluetoothOnceSetUp)
{
  {
    // A new install has no box: the app offers to connect one.
    NewUser user;
    TEST(!user.Start().m_inertialEnabled, ());
    TEST(!user.m_delegate.m_esp32BleOpen, ());
    TEST(!user.m_delegate.m_sensorsStarted, ());
  }
  {
    // The box connected once is looked for over Bluetooth.
    NewUser user;
    user.m_storage.Set(Storage::kInertialEnabled, true);
    auto const status = user.Start();
    TEST(status.m_inertialEnabled, ());
    TEST(status.m_esp32Source, ());
    TEST(user.m_delegate.m_esp32BleOpen, ());
    TEST(user.m_delegate.m_elm327Connects.empty(), ());
  }
  {
    // The user has forgotten the box.
    NewUser user;
    user.m_storage.Set(Storage::kInertialEnabled, false);
    TEST(!user.Start().m_inertialEnabled, ());
    TEST(!user.m_delegate.m_esp32BleOpen, ());
    TEST(!user.m_delegate.m_sensorsStarted, ());
  }
  {
    // The box was heard when the navigation was on by default and the choice wasn't saved: it stays.
    NewUser user;
    user.m_storage.Set(Storage::kBoxPowerOns, std::string("C47D:3"));
    TEST(user.Start().m_inertialEnabled, ());
    TEST(user.m_delegate.m_esp32BleOpen, ());
  }
  {
    // The adapter was chosen when the phone was the default source and the choice wasn't saved: it stays.
    NewUser user;
    user.m_storage.Set(Storage::kElm327Address, std::string("00:11:22:33:44:55"));
    TEST(!user.Start().m_esp32Source, ());
    TEST(!user.m_delegate.m_esp32BleOpen, ());
    TEST_EQUAL(user.m_delegate.m_elm327Connects.size(), 1, ());
  }
  {
    // The box was reached over its Wi-Fi, which it has no more: it is found over Bluetooth.
    NewUser user;
    user.m_storage.Set(Storage::kInertialEnabled, true);
    user.m_storage.Set(Storage::kEsp32Source, true);
    user.m_storage.SetString("NoGpsEsp32Bluetooth", "false");
    TEST(user.Start().m_esp32Source, ());
    TEST(user.m_delegate.m_esp32BleOpen, ());
  }
}

UNIT_TEST(NoGps_Engine_StartsTheBox)
{
  Env env(true /* inertial */);
  TEST(env.m_delegate.m_esp32BleOpen, ());
  // The accelerometer goes to the trip log, the gyroscope is in the box.
  TEST(env.m_delegate.m_sensorsStarted, ());
  TEST(!env.m_delegate.m_gyroscope, ());
  env.Drive(500, 0, 0);
  auto const status = env.m_engine.GetStatus();
  TEST(status.m_inertialStarted, ());
  TEST(status.m_esp32Source, ());
  TEST_EQUAL(status.m_sourceState, SourceState::Connected, ());
  TEST_EQUAL(status.m_calibration, CalibrationState::Done, ());
  TEST_EQUAL(status.m_speedKmh, 0, ());

  env.m_engine.Stop();
  TEST(!env.m_delegate.m_esp32BleOpen, ());
  TEST(!env.m_delegate.m_sensorsStarted, ());
}

UNIT_TEST(NoGps_Engine_MarkIsOnRoadAndShowsCarHeading)
{
  Env env(false /* inertial */);
  env.m_engine.SetManualMode(true);
  TEST(env.m_delegate.HasEvent(Event::ManualModeChanged), ());
  // A tap between the streets is not where the car is.
  TEST(!env.m_engine.PlaceMarkByTap(At(50, 50)), ());
  TEST(env.m_delegate.HasEvent(Event::MarkNoRoad), ());
  TEST(env.m_engine.PlaceMarkByTap(At(60, 4)), ());
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
  TEST_EQUAL(env.Last().m_bearingDeg, 90.0, ());
  TEST(env.m_engine.IsCarHeadingShown(), ());
  TEST_EQUAL(env.m_map.m_carHeading, 90.0, ());
  auto const status = env.m_engine.GetStatus();
  TEST_EQUAL(status.m_source, PositionSource::Manual, ());
  TEST(status.m_movedByHand, ());

  // The mark is sent again and again, otherwise the position is treated as lost.
  size_t const positions = env.m_delegate.m_positions.size();
  env.m_clock.Advance(Engine::kManualRepeatIntervalMs);
  TEST_EQUAL(env.m_delegate.m_positions.size(), positions + 1, ());

  env.m_engine.ReverseDirection();
  TEST_EQUAL(env.Last().m_bearingDeg, 270.0, ());
}

// The car is marked at 0 m of the east street, GPS gives a fix at |eastM|, |northM| from the origin. The fix is
// |ageMs| old when the user taps the panel.
bool PlaceByGpsFix(Env & env, double eastM, double northM, double accuracyM, int64_t ageMs = 0)
{
  env.m_engine.OnFix(GpsAt(env.m_clock, eastM, northM, {}, {}, accuracyM));
  env.m_clock.Advance(ageMs);
  return env.m_engine.PlaceMarkByGps();
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsTakesAccurateFixNearMark)
{
  Env env(false /* inertial */);
  MarkCar(env, 0);
  TEST(PlaceByGpsFix(env, 60, 3, 4), ());
  TEST(env.m_engine.IsManualMode(), ());
  TestAlmostEqualAbs(East(env.Last().m_position), 60, 0.5);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
  TEST_EQUAL(env.Last().m_bearingDeg, 90.0, ());
  TEST_EQUAL(env.Last().m_accuracyM, Engine::kManualAccuracyM, ());
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsRefusesFarFixAndKeepsTapArmed)
{
  Env env(false /* inertial */);
  MarkCar(env, 0);
  env.m_engine.SetMarkByTap(true);
  // A fix 360 m from a mark tapped just before is wrong, not the car.
  TEST(!PlaceByGpsFix(env, 360, 3, 2.5), ());
  TestAlmostEqualAbs(East(env.Last().m_position), 0, 0.5);
  TEST(env.m_engine.IsMarkByTap(), ());
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsRefusesBadFix)
{
  Env env(false /* inertial */);
  MarkCar(env, 0);
  TEST(!PlaceByGpsFix(env, 60, 3, 4, Engine::kGpsMaxAgeMs + 1000), ());
  TEST(PlaceByGpsFix(env, 60, 3, 4, Engine::kGpsMaxAgeMs - 1000), ());
  TEST(!PlaceByGpsFix(env, 62, 3, 400), ());
  TEST(PlaceByGpsFix(env, 62, 3, 4), ());

  // GPS is on another continent.
  env.m_clock.Advance(1000);
  Fix spoofed = GpsAt(env.m_clock, 0, 0, 90.0, 10.0);
  spoofed.m_position = {-12.0453, -77.0569};
  env.m_engine.OnFix(spoofed);
  TEST(env.m_engine.GetStatus().m_gpsSpoofed, ());
  TEST(!env.m_engine.PlaceMarkByGps(), ());
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsTakesFixWhenGpsIsTurnedOff)
{
  Env env(false /* inertial */);
  MarkCar(env, 0);
  env.m_engine.SetGpsDisabled(true);
  TEST(PlaceByGpsFix(env, 60, 3, 4), ());
  TestAlmostEqualAbs(East(env.Last().m_position), 60, 0.5);
  TEST(env.m_engine.IsManualMode(), ());
  TEST(env.m_engine.GetStatus().m_gpsDisabled, ());
  // The refusals of the other conditions stay.
  TEST(!PlaceByGpsFix(env, 62, 3, 400), ());
  TEST(!PlaceByGpsFix(env, 360, 3, 4), ());
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsTakesFreshFusedFixWhenGpsIsOld)
{
  Env env(false /* inertial */);
  MarkCar(env, 0);
  env.m_engine.OnFix(GpsAt(env.m_clock, 60, 3, {}, {}, 4));
  env.m_clock.Advance(Engine::kGpsMaxAgeMs + 5000);
  // The GPS has stopped in a tunnel, the fused provider still gives a fix.
  Fix fused = GpsAt(env.m_clock, 62, 3, {}, {}, 8);
  fused.m_provider = Provider::Fused;
  env.m_engine.OnFix(fused);
  TEST(env.m_engine.PlaceMarkByGps(), ());
  TestAlmostEqualAbs(East(env.Last().m_position), 62, 0.5);
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsSnapsInaccurateFixToRoadFartherThanAccurateOne)
{
  // The fix is 80 m from the street the car drives along.
  PieceRoads roads({{-500, 0, 500, 0}}, {});
  Env env(false /* inertial */, &roads);
  MarkCar(env, -20);
  TEST(PlaceByGpsFix(env, 30, 80, 150), ());
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
  TestAlmostEqualAbs(East(env.Last().m_position), 30, 0.5);
  TEST_EQUAL(env.Last().m_accuracyM, 150.0, ());
  // An accurate fix has a road within 30 m only.
  TEST(!PlaceByGpsFix(env, 60, 80, 5), ());
}

UNIT_TEST(NoGps_Engine_ButtonLetsNextTapMarkCar)
{
  Env env(false /* inertial */);
  env.DriveGps(5, 0 /* eastM */, 10 /* speedMps */);
  TEST(!env.m_engine.IsManualMode(), ());

  env.m_engine.SetMarkByTap(true);
  TEST(env.m_engine.GetStatus().m_markByTap, ());
  // A tap between the streets is not where the car is: the next one may be.
  TEST(!env.m_engine.PlaceMarkByTap(At(50, 50)), ());
  TEST(env.m_delegate.HasEvent(Event::MarkNoRoad), ());
  TEST(env.m_engine.IsMarkByTap(), ());
  TEST(!env.m_engine.IsManualMode(), ());

  // GPS works, but the user shows that the car is elsewhere: it is followed without GPS from there.
  TEST(env.m_engine.PlaceMarkByTap(At(60, 4)), ());
  TEST(env.m_engine.IsManualMode(), ());
  TEST(env.m_delegate.HasEvent(Event::ManualModeChanged), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Manual, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 60, 0.5);
  // The button is pressed for one tap.
  TEST(!env.m_engine.IsMarkByTap(), ());
  TEST(!env.m_engine.GetStatus().m_markByTap, ());
}

// The button of the place page shows where the car is without the button on the map.
UNIT_TEST(NoGps_Engine_PlaceMarkByTapWithoutArming)
{
  Env env(false /* inertial */);
  env.DriveGps(5, 0 /* eastM */, 10 /* speedMps */);
  TEST(!env.m_engine.IsMarkByTap(), ());
  size_t const positions = env.m_delegate.m_positions.size();

  // No road there: GPS still shows the car.
  TEST(!env.m_engine.PlaceMarkByTap(At(50, 50)), ());
  TEST(env.m_delegate.HasEvent(Event::MarkNoRoad), ());
  TEST(!env.m_engine.IsManualMode(), ());
  TEST_EQUAL(env.m_delegate.m_positions.size(), positions, ());
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());

  TEST(env.m_engine.PlaceMarkByTap(At(60, 4)), ());
  TEST(env.m_engine.IsManualMode(), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Manual, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 60, 0.5);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
  TEST(!env.m_engine.IsMarkByTap(), ());
}

UNIT_TEST(NoGps_Engine_ShiftStopsAtCrossing)
{
  Env env(false /* inertial */);
  env.m_engine.SetManualMode(true);
  TEST(env.m_engine.PlaceMarkByTap(At(60, 2)), ());
  // There is no route, the position is moved along the road up to the crossing.
  TestAlmostEqualAbs(env.m_engine.ShiftPosition(100), 40, 0.5);
  TestAlmostEqualAbs(East(env.Last().m_position), 100, 0.5);
  // The car may turn at the crossing: it is not moved further that way, but it is moved back.
  TEST(env.m_engine.IsShiftBlocked(true /* forward */), ());
  TEST(!env.m_engine.IsShiftBlocked(false /* forward */), ());
  TEST_EQUAL(env.m_engine.ShiftPosition(50), 0, ());
  TestAlmostEqualAbs(env.m_engine.ShiftPosition(-30), -30, 0.5);
  TestAlmostEqualAbs(East(env.Last().m_position), 70, 0.5);
  TEST(!env.m_engine.IsShiftBlocked(true /* forward */), ());
}

// The app starts again with what the app before has saved.
std::function<void(TestStorage &)> SavedBy(Env const & before)
{
  return [&before](TestStorage & storage) { storage = before.m_storage; };
}

UNIT_TEST(NoGps_Engine_CarIsWhereItWasLeftAfterRestart)
{
  Env before(true /* inertial */);
  MarkCar(before, 20);
  before.Drive(5000, 36, 0);
  before.Drive(3000, 0, 0);
  Fix const left = before.Last();
  TEST_EQUAL(left.m_provider, Provider::Inertial, ());
  TEST_GREATER(East(left.m_position), 50, ());

  // The app is killed, not stopped: the standing car is saved anyway.
  Env after(true /* inertial */, nullptr, SavedBy(before));
  after.Drive(500, 0, 0);
  TEST(after.m_engine.IsManualMode(), ());
  TestAlmostEqualAbs(Distance(after.Last().m_position, left.m_position), 0, 0.1);
  TestAlmostEqualAbs(*after.Last().m_bearingDeg, *left.m_bearingDeg, 0.1);
  TEST(after.m_engine.IsCarHeadingShown(), ());

  // GPS was not trusted when the car was left: it comes back as after any mark, not by one position.
  after.m_engine.OnFix(GpsAt(after.m_clock, East(left.m_position), 0, 90.0, 0.0));
  TEST(after.m_engine.IsManualMode(), ());

  // The car drives on from where it was left.
  after.Drive(5000, 36, 0);
  TEST_EQUAL(after.Last().m_provider, Provider::Inertial, ());
  TEST_GREATER(East(after.Last().m_position), East(left.m_position) + 40, ());
  TestAlmostEqualAbs(North(after.Last().m_position), 0, 1);
}

UNIT_TEST(NoGps_Engine_DisabledGpsIsKeptAfterRestart)
{
  Env before(false /* inertial */);
  before.m_engine.SetGpsDisabled(true);

  Env disabled(false /* inertial */, nullptr, SavedBy(before));
  TEST(disabled.m_engine.GetStatus().m_gpsDisabled, ());
  disabled.DriveGps(3, 0, 10);
  TEST(disabled.m_delegate.m_positions.empty(), ());

  disabled.m_engine.SetGpsDisabled(false);
  Env enabled(false /* inertial */, nullptr, SavedBy(disabled));
  TEST(!enabled.m_engine.GetStatus().m_gpsDisabled, ());
  enabled.DriveGps(3, 0, 10);
  TEST_EQUAL(enabled.m_engine.GetStatus().m_source, PositionSource::Gps, ());
}

UNIT_TEST(NoGps_Engine_DrivingCarIsSavedSeldom)
{
  Env env(true /* inertial */);
  MarkCar(env, 50);
  // Every save writes the settings file anew.
  std::set<std::string> saves;
  for (int i = 0; i < 30; ++i)
  {
    env.Drive(1000, 36, 0);
    saves.insert(env.m_storage.Get<std::string>(Storage::kCarPosition, ""));
  }
  TEST_LESS_OR_EQUAL(saves.size(), 5, (saves));

  // The car is saved where it has stopped.
  env.Drive(3000, 0, 0);
  Env after(true /* inertial */, nullptr, SavedBy(env));
  after.Drive(500, 0, 0);
  TestAlmostEqualAbs(Distance(after.Last().m_position, env.Last().m_position), 0, 0.1);
}

UNIT_TEST(NoGps_Engine_CarIsKnownAfterRestartAsWhenItWasLeft)
{
  // The car has driven 500 m since it was marked: it is 25 m off at most, and as much on the next trip.
  Env before(true /* inertial */);
  MarkCar(before, 20);
  before.Drive(50'000, 36, 0);
  before.Drive(3000, 0, 0);
  double const leftAccuracyM = before.Last().m_accuracyM;
  TEST_GREATER(leftAccuracyM, DeadReckoning::kBaseAccuracyM + 8, ());
  Env after(true /* inertial */, nullptr, SavedBy(before));
  after.Drive(5000, 36, 0);
  TEST_EQUAL(after.Last().m_provider, Provider::Inertial, ());
  TestAlmostEqualAbs(after.Last().m_accuracyM, leftAccuracyM + 1, 1);

  // A car saved before the way was is a known place.
  TestStorage old;
  old.Set(Storage::kInertialEnabled, true);
  auto const saved = before.m_storage.Get<std::string>(Storage::kCarPosition, "");
  auto const parts = strings::Tokenize(saved, ",");
  TEST_EQUAL(parts.size(), 7, (saved));
  old.Set(Storage::kCarPosition, std::string(parts[0]) + "," + std::string(parts[1]) + "," + std::string(parts[2]) +
                                     "," + std::string(parts[3]) + "," + std::string(parts[6]));
  Env older(true /* inertial */, nullptr, [&old](TestStorage & storage) { storage = old; });
  older.Drive(5000, 36, 0);
  TEST_EQUAL(older.Last().m_provider, Provider::Inertial, ());
  TestAlmostEqualAbs(older.Last().m_accuracyM, DeadReckoning::kBaseAccuracyM + 1, 1);
}

/// Counts the TRIP lines of the trip log while it lives, the other messages are logged as before.
class TripLines
{
public:
  TripLines()
  {
    s_count = 0;
    s_saved = base::SetLogMessageFn(&Count);
  }
  ~TripLines() { base::SetLogMessageFn(s_saved); }

  /// \returns the lines written since the last call.
  int Take() { return std::exchange(s_count, 0); }

private:
  static void Count(base::LogLevel level, base::SrcPoint const & src, std::string const & message)
  {
    if (message.starts_with("TRIP "))
      ++s_count;
    else
      s_saved(level, src, message);
  }

  static inline int s_count = 0;
  static inline base::LogMessageFn s_saved = nullptr;
};

// The seconds after a stop are written, but the first one may go by while the speed is old.
int constexpr kTailLines = Engine::kTripLogStandTailMs / 1000 - 1;

// Ten intervals of a stand have about ten lines.
void TestStandLines(int count)
{
  TEST_GREATER_OR_EQUAL(count, 9, ());
  TEST_LESS_OR_EQUAL(count, 11, ());
}

UNIT_TEST(NoGps_Engine_TripLogIsWrittenWhileCarMoves)
{
  {
    Env env(true /* inertial */);
    MarkCar(env, 50);
    TripLines lines;
    env.Drive(20'000, 36, 0);
    TEST_GREATER_OR_EQUAL(lines.Take(), 19, ());
    // After a stop every second still: the car reports its speed late.
    env.Drive(Engine::kTripLogStandTailMs, 0, 0);
    TEST_GREATER_OR_EQUAL(lines.Take(), kTailLines, ());
    // Then seldom: the application runs.
    env.Drive(10 * Engine::kTripLogStandIntervalMs, 0, 0);
    TestStandLines(lines.Take());
    // The box is lost: the state is written every second again.
    env.m_engine.OnEsp32BleState(BleState::Searching);
    env.m_clock.Advance(Engine::kTripLogStandTailMs);
    TEST_GREATER_OR_EQUAL(lines.Take(), kTailLines, ());
    env.m_clock.Advance(10 * Engine::kTripLogStandIntervalMs);
    TestStandLines(lines.Take());
    env.ConnectBox();
    env.Drive(3000, 10, 0);
    TEST_GREATER_OR_EQUAL(lines.Take(), 2, ());
  }
  {
    // GPS alone: no box, the car drives and stands.
    Env env(false /* inertial */);
    TripLines lines;
    env.DriveGps(20, 0 /* eastM */, 10 /* speedMps */);
    TEST_GREATER_OR_EQUAL(lines.Take(), 19, ());
    env.DriveGps(Engine::kTripLogStandTailMs / 1000, 200 /* eastM */, 0 /* speedMps */);
    TEST_GREATER_OR_EQUAL(lines.Take(), kTailLines, ());
    env.DriveGps(10 * Engine::kTripLogStandIntervalMs / 1000, 200 /* eastM */, 0 /* speedMps */);
    TestStandLines(lines.Take());
  }
}

UNIT_TEST(NoGps_Engine_CarLeftWithGpsWaitsForGps)
{
  Env before(false /* inertial */);
  Fix network = GpsAt(before.m_clock, 0, 0, {}, {}, 100);
  network.m_provider = Provider::Network;
  before.m_engine.OnFix(network);
  before.DriveGps(5, 0, 10);
  before.DriveGps(2, 40, 0);
  // GPS is gone, the cell towers tell a place a few hundred meters off: the place by GPS is kept.
  before.m_clock.Advance(30'000);
  network = GpsAt(before.m_clock, 300, 0, {}, {}, 100);
  network.m_provider = Provider::Network;
  before.m_engine.OnFix(network);
  TEST_EQUAL(before.Last().m_provider, Provider::Network, ());
  TEST(!before.m_engine.IsManualMode(), ());
  before.m_clock.Advance(2000);

  Env after(false /* inertial */, nullptr, SavedBy(before));
  after.m_clock.Advance(1000);
  TEST(after.m_engine.IsManualMode(), ());
  TEST_EQUAL(after.Last().m_provider, Provider::Manual, ());
  TestAlmostEqualAbs(East(after.Last().m_position), 40, 0.1);
  TEST_EQUAL(after.Last().m_bearingDeg, 90.0, ());
  // GPS absent since the start is not untrusted: the car is still left with GPS.
  after.m_engine.Stop();
  auto const saved = after.m_storage.Get<std::string>(Storage::kCarPosition, "");
  TEST(saved.find(",90.0,0,") != std::string::npos, (saved));

  // The first GPS position takes the car over, as at any start, and the user is not told about it.
  after.m_engine.Start();
  after.m_engine.OnFix(GpsAt(after.m_clock, 45, 0, 90.0, 0.0));
  TEST(!after.m_engine.IsManualMode(), ());
  TEST_EQUAL(after.Last().m_provider, Provider::Gps, ());
  TEST(!after.m_delegate.HasEvent(Event::GpsBack), ());
}

UNIT_TEST(NoGps_Engine_CarLeftWithGpsAndMovedSinceChecksGps)
{
  Env before(true /* inertial */);
  before.DriveGps(5, 0, 10);
  before.DriveGps(2, 40, 0);
  TEST(!before.m_engine.IsManualMode(), ());

  // The car has driven away from where GPS was trusted: one position does not take it over.
  Env driven(true /* inertial */, nullptr, SavedBy(before));
  driven.Drive(500, 0, 0);
  driven.Drive(5000, 36, 0);
  TEST_EQUAL(driven.Last().m_provider, Provider::Inertial, ());
  driven.m_engine.OnFix(GpsAt(driven.m_clock, East(driven.Last().m_position), 0, 90.0, 10.0));
  TEST(driven.m_engine.IsManualMode(), ());

  // The user shows that GPS is wrong.
  Env marked(true /* inertial */, nullptr, SavedBy(before));
  marked.Drive(500, 0, 0);
  TEST(marked.m_engine.PlaceMarkByTap(At(60, 3)), ());
  marked.m_engine.OnFix(GpsAt(marked.m_clock, 60, 0, 90.0, 0.0));
  TEST(marked.m_engine.IsManualMode(), ());

  // GPS is turned off for a test and on again.
  Env disabled(true /* inertial */, nullptr, SavedBy(before));
  disabled.m_engine.SetGpsDisabled(true);
  disabled.m_engine.SetGpsDisabled(false);
  disabled.m_engine.OnFix(GpsAt(disabled.m_clock, 40, 0, 90.0, 0.0));
  TEST(disabled.m_engine.IsManualMode(), ());
}

// The value of a field of the trip line, e.g. "turn".
std::string TripField(Env & env, std::string const & name)
{
  std::string const line = env.m_engine.GetTripLine();
  auto const key = line.find(" " + name + "=");
  TEST(key != std::string::npos, (name, line));
  auto const from = key + name.size() + 2;
  return line.substr(from, line.find(' ', from) - from);
}

// The car maneuvering off the roads is followed apart from the road it has left, the mark follows it.
bool FollowedApart(Env & env)
{
  return env.m_engine.GetTripLine().find(" self=1 car=") != std::string::npos;
}

// The car driving 10 m/s east turns left at the crossing at 200 m, the calculated position lags behind it: it is
// |beforeTurnM| east when the turn starts. Then the car drives north.
void TurnLeftAtCrossing(Env & env, double beforeTurnM)
{
  // The position is 112 m farther after 10 s.
  MarkCar(env, beforeTurnM - 112);
  env.Drive(10'000, 36, 0);
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  TestAlmostEqualAbs(East(env.Last().m_position), beforeTurnM, 2);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 1);
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
  env.Drive(3000, 36, -30);
  env.Drive(3000, 36, 0);
  // The car is on the street going north from the crossing.
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 1);
  TEST_GREATER(North(env.Last().m_position), 20, ());
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 3);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_BoxPauseInTurnKeepsHeading)
{
  Env env(true /* inertial */);
  MarkCar(env, 200 - 112);
  env.Drive(10'000, 36, 0);
  // The lines of half the turn are lost.
  env.Drive(1000, 36, -30);
  env.LoseBoxLines(1500, -30);
  env.Drive(500, 36, -30);
  env.Drive(3000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 1);
  TEST_GREATER(North(env.Last().m_position), 20, ());
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 3);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_InertialTurnIsMovedToCrossing)
{
  Env env(true /* inertial */);
  // The car starts turning 5 m before the middle of a crossing: this one is 18 m farther.
  TurnLeftAtCrossing(env, 177);
  TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 18, 2);
  // The crossing is a known place: the error of the calculated distance is gone, the car has driven 20 m since.
  TEST_LESS(env.Last().m_accuracyM, DeadReckoning::kBaseAccuracyM + 1, ());
}

UNIT_TEST(NoGps_Engine_InertialTurnFarFromCrossingIsNotMovedToIt)
{
  Env env(true /* inertial */);
  // The crossing is 33 m farther than the turn, and a crossing is searched within 25 m: farther away another
  // crossing may be the one. The street going north is 14 m aside of the car after the turn, the car is on it
  // as on any road it drives along.
  TurnLeftAtCrossing(env, 162);
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
  // Its place along the street is not known better than before the turn.
  TEST_GREATER(env.Last().m_accuracyM, DeadReckoning::kBaseAccuracyM + 2, ());
}

// A street going east, a street going north from the crossing at 200 m, which goes |deg| degrees to the east of north
// from 6 m on, so that the road checked 12 m from the crossing goes that way.
PieceRoads StreetTurningAfterCrossing(double deg)
{
  double const sin = std::sin(math::DegToRad(deg));
  double const cos = std::cos(math::DegToRad(deg));
  return PieceRoads({{-300, 0, 400, 0}, {200, 0, 200, 6}, {200, 6, 200 + 300 * sin, 6 + 300 * cos}}, {{200, 0}});
}

UNIT_TEST(NoGps_Engine_TurnMovedToCrossingKeepsGyroHeading)
{
  // The road after the crossing is 20 degrees off the way the gyroscope says the car has turned: the car is on it,
  // looking where the gyroscope says, the snapping pulls the heading to the road later.
  auto roads = StreetTurningAfterCrossing(20);
  Env env(true /* inertial */, &roads);
  MarkCar(env, 177 - 112);
  env.Drive(10'000, 36, 0);
  TEST(TripField(env, "hdg").ends_with("/ROAD"), (TripField(env, "hdg")));
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 18, 2);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 8);
  // The trip log tells the heading is the gyroscope's, not the one of the road or GPS it was set from before.
  TEST(TripField(env, "hdg").ends_with("/GYRO"), (TripField(env, "hdg")));
  // The crossing is a known place: the heading is pulled to the road at once, not after 50 m.
  env.Drive(6000, 36, 0);
  TEST_LESS(std::fabs(AngleDiff(*env.Last().m_bearingDeg, 20)), 11, (*env.Last().m_bearingDeg));
}

UNIT_TEST(NoGps_Engine_SmallRotationAfterCrossingKeepsRoadTrusted)
{
  // After the turn the car rotates 5 degrees away from the road, less than a branch would take: the road is still
  // trusted, the heading 25 degrees off is pulled to it at once.
  auto roads = StreetTurningAfterCrossing(20);
  Env env(true /* inertial */, &roads);
  MarkCar(env, 177 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 18, 2);
  env.Drive(1000, 36, -5);
  env.Drive(8000, 36, 0);
  TEST_LESS(std::fabs(AngleDiff(*env.Last().m_bearingDeg, 20)), 11, (*env.Last().m_bearingDeg));
}

UNIT_TEST(NoGps_Engine_BranchSoonAfterCrossingIsToldByHeading)
{
  // The street going north from the crossing forks 35 m from it, a branch leaves 20 degrees to the east. The car
  // turns into the street and slowly, below the speed the forks are checked at, keeps to the branch: its heading
  // is not pulled to the street, which the snapping keeps it on, and the car is on the branch when it speeds up.
  double const tan20 = std::tan(math::DegToRad(20.0));
  PieceRoads roads({{-300, 0, 400, 0}, {200, 0, 200, 35}, {200, 35, 200, 400}, {200, 35, 200 + 365 * tan20, 400}},
                   {{200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 177 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 18, 2);
  env.Drive(1000, 15, 0);
  env.Drive(4000, 15, 5);
  env.Drive(4000, 15, 0);
  env.Drive(4000, 30, 0);
  double const north = North(env.Last().m_position);
  TEST_GREATER(north, 90, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 200 + (north - 35) * tan20, 2);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 20, 3);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_TurnToRoadFartherOffThanSnappingTakesIsNotMoved)
{
  // The road after the crossing is 33 degrees off: the snapping does not take the car to it, the turn is not moved.
  auto roads = StreetTurningAfterCrossing(33);
  Env env(true /* inertial */, &roads);
  MarkCar(env, 177 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
}

// The car marked at |markedEastM| drives east at 36 km/h, at 165 m turns left onto a road going north not joined to
// the street on the map, ahead of it by the calculation, as on November 8, and drives on straight.
void TurnPastRoadGoingNorth(Env & env, double markedEastM = 65)
{
  MarkCar(env, markedEastM);
  env.Drive(std::lround((165 - markedEastM) * 100), 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(5000, 36, 0);
}

UNIT_TEST(NoGps_Engine_CarIsPutOnRoadGoingItsWayBeforeRoadIsLost)
{
  // The turn finds no crossing, the car drives north 31 m beside the road: it is put on it, not lost.
  PieceRoads roads({{-300, 0, 400, 0}, {165, 10, 165, 400}}, {});
  Env env(true /* inertial */, &roads);
  TurnPastRoadGoingNorth(env);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TEST_EQUAL(TripField(env, "road"), "1", ());
  TestAlmostEqualAbs(East(env.Last().m_position), 165, 1);
  TEST_GREATER(North(env.Last().m_position), 40, ());
}

UNIT_TEST(NoGps_Engine_RoadsGoingCarWayAreOtherMarks)
{
  // Two roads go north, 31 m to the left and 36 m to the right: the car is put on the closer one, the other is an other
  // mark.
  PieceRoads roads({{-300, 0, 400, 0}, {165, 10, 165, 400}, {232, 10, 232, 400}}, {});
  Env env(true /* inertial */, &roads);
  TurnPastRoadGoingNorth(env);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), 165, 1);
  TEST(env.m_engine.GetTripLine().find(" marks=2 ") != std::string::npos, (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_RoadGoingCarWayWithinAccuracyIsTaken)
{
  for (bool longWay : {false, true})
  {
    // A road goes north ~50 m to the right of the car, farther than kJumpSearchM. After 2.6 km without a known place
    // the accuracy is ~70 m: the car is shown there, not lost.
    PieceRoads roads({{-3000, 0, 400, 0}, {245, 10, 245, 400}}, {});
    Env env(true /* inertial */, &roads);
    TurnPastRoadGoingNorth(env, longWay ? -2500 : 65);
    TEST_EQUAL(env.m_delegate.HasEvent(Event::RoadLost), !longWay, (env.m_engine.GetTripLine()));
    if (longWay)
      TestAlmostEqualAbs(East(env.Last().m_position), 245, 1);
  }

  // The road within kJumpSearchM is taken first, the far one is an other mark.
  PieceRoads roads({{-3000, 0, 400, 0}, {165, 10, 165, 400}, {245, 10, 245, 400}}, {});
  Env env(true /* inertial */, &roads);
  TurnPastRoadGoingNorth(env, -2500);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), 165, 1);
  TEST(env.m_engine.GetTripLine().find(" marks=2 ") != std::string::npos, (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_RoadIsNotLostWhileOtherMarkLives)
{
  // The road the car is put on ends at 100 m north. The other one, 67 m to the right, has a gap at 115-160 m: its mark
  // is off the road when the shown one is lost, and comes back onto it.
  PieceRoads roads({{-300, 0, 400, 0}, {165, 10, 165, 100}, {232, 10, 232, 115}, {232, 160, 232, 400}}, {});
  Env env(true /* inertial */, &roads);
  TurnPastRoadGoingNorth(env);
  TEST(env.m_engine.GetTripLine().find(" marks=2 ") != std::string::npos, (env.m_engine.GetTripLine()));
  env.Drive(15'000, 36, 0);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), 232, 1);
  TEST_GREATER(North(env.Last().m_position), 160, ());
}

UNIT_TEST(NoGps_Engine_TurnOfCarManeuveringOffRoadsIsNotMoved)
{
  for (bool twoStreets : {true, false})
  {
    // A street going east. 30 m to the south of it another one going east crosses a street going south, or two of
    // them 30 m apart.
    std::vector<PieceRoads::Piece> pieces = {{-300, 0, 300, 0}, {-100, -30, 100, -30}, {22, -10, 22, -60}};
    if (twoStreets)
      pieces.push_back({-8, -10, -8, -60});
    PieceRoads roads(pieces, {{-8, -30}, {22, -30}});
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    // The car leaves the street to the south at a walking speed, between the streets going south and 15 m from
    // each, drives 10 m and turns east.
    env.Drive(2000, 9, 0);
    env.Drive(1000, 9, 90);
    env.Drive(4000, 9, 0);
    TEST(env.m_engine.GetTripLine().find(" road=0 ") != std::string::npos, (env.m_engine.GetTripLine()));
    env.Drive(1000, 9, -90);
    env.Drive(2000, 9, 0);
    // The car was maneuvering off the roads: it has turned where it is, be there two crossings to turn at or one.
    TEST_EQUAL(TripField(env, "turn"), "NaN", (twoStreets));
  }

  // A turn as slow of a car driving along a street is moved to the crossing of that street, 12 m ahead.
  PieceRoads roads({{-300, 0, 300, 0}, {40, -300, 40, 300}}, {{40, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  env.Drive(8000, 9, 0);
  TEST(env.m_engine.GetTripLine().find(" road=1 ") != std::string::npos, (env.m_engine.GetTripLine()));
  env.Drive(3000, 9, -30);
  env.Drive(2000, 9, 0);
  TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 12, 4);
  TestAlmostEqualAbs(East(env.Last().m_position), 40, 1);
}

UNIT_TEST(NoGps_Engine_TurnEnteredSmoothlyStartsOnRoad)
{
  for (int kmh : {36, 15})
  {
    // The street going east crosses a street going north at 200 m.
    PieceRoads roads({{-300, 0, 400, 0}, {200, -300, 200, 400}}, {{200, 0}});
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    // 150 m east.
    env.Drive(540'000 / kmh, kmh, 0);
    // The car enters the turn smoothly: it rotates slower than a turn starts until it looks 35 degrees off the
    // street, then turns left fast. The turn starts on the street, looking along it: the crossing is the one the
    // car has come to by that street.
    env.Drive(4000, kmh, -9);
    env.Drive(2000, kmh, -30);
    // 30 m north.
    env.Drive(108'000 / kmh, kmh, 0);
    // The car has left the street in the turn, it has not followed the roads: it is moved to the crossing.
    TEST_NOT_EQUAL(TripField(env, "turn"), "NaN", (kmh));
    TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
    TEST_GREATER(North(env.Last().m_position), 20, (kmh));
    TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 5);
  }
}

// A street going east with a crossing at 200 m: a road leaves it there |sideDeg| degrees to the left, if any.
PieceRoads StreetWithSideRoad(std::optional<double> sideDeg)
{
  std::vector<PieceRoads::Piece> pieces = {{-3000, 0, 400, 0}};
  if (sideDeg)
  {
    double const bearing = math::DegToRad(90 - *sideDeg);
    pieces.push_back({200, 0, 200 + 300 * std::sin(bearing), 300 * std::cos(bearing)});
  }
  return PieceRoads(pieces, {{200, 0}});
}

// The car marked 2.2 km before drives east at 25 km/h, its place is known within 60 m. From 135 m east it turns
// left by |turnDeg| slower than a turn starts, as on November 4, and drives on straight.
void TurnLeftSlowly(Env & env, double turnDeg)
{
  MarkCar(env, -2200);
  while (East(env.Last().m_position) < 135)
    env.Drive(100, 25, 0);
  // 5-9 degrees a second.
  double const rates[] = {5, 9, 7};
  double leftDeg = turnDeg;
  for (size_t i = 0; leftDeg > 0; ++i)
  {
    double const rate = std::min(rates[i % 3], leftDeg);
    env.Drive(1000, 25, -rate);
    leftDeg -= rate;
  }
  TEST_EQUAL(TripField(env, "turning"), "0", ());
  env.Drive(5000, 25, 0);
}

UNIT_TEST(NoGps_Engine_SlowTurnIsMatchedBeforeRoadIsLost)
{
  // The car turns 46 degrees into the road leaving the street 46 degrees to the left. It has turned 40 m before the
  // crossing by the calculation, and leaves the street 29 m aside of that road: the turn is matched before the road
  // is lost, and the car is moved onto that road.
  auto roads = StreetWithSideRoad(46);
  Env env(true /* inertial */, &roads);
  TurnLeftSlowly(env, 46);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TEST_NOT_EQUAL(TripField(env, "turn"), "NaN", ());
  TEST_EQUAL(TripField(env, "road"), "1", ());
  auto const & position = env.Last().m_position;
  double const sin44 = std::sin(math::DegToRad(44.0));
  double const cos44 = std::cos(math::DegToRad(44.0));
  TestAlmostEqualAbs((East(position) - 200) * cos44 - North(position) * sin44, 0, 1);
  TEST_GREATER(North(position), 20, ());
}

UNIT_TEST(NoGps_Engine_SlowTurnWithoutRoadThatWayIsLost)
{
  // The road leaving the street goes 90 degrees to the left, not the way the car has turned: the road is lost.
  auto roads = StreetWithSideRoad(90);
  Env env(true /* inertial */, &roads);
  TurnLeftSlowly(env, 46);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
}

UNIT_TEST(NoGps_Engine_PlaceMarkByGpsRadiusGrowsWithDistanceDrivenWhenRoadIsLost)
{
  auto roads = StreetWithSideRoad(90);
  Env env(true /* inertial */, &roads);
  TurnLeftSlowly(env, 46);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  double const markEastM = East(env.Last().m_position);
  // The car stands at the mark when the road is lost: a fix 250 m behind it is too far.
  TEST(!PlaceByGpsFix(env, markEastM - 250, 3, 4), ());
  // The car drives on, the mark stands: the fix may be that far from it now.
  env.Drive(20'000, 25, 0);
  TEST(PlaceByGpsFix(env, markEastM - 250, 3, 4), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_SlowDriftOffRoadIsNotTurn)
{
  // The heading drifts by 34 degrees, less than a turn: the road is lost as before, no turn is matched.
  auto roads = StreetWithSideRoad(90);
  Env env(true /* inertial */, &roads);
  TurnLeftSlowly(env, 34);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
}

UNIT_TEST(NoGps_Engine_RotatingCarIsNotPutOnRoadGoingItsWay)
{
  // A road going 44 degrees, the way the car looks after the slow turn, not joined to the street, is 30 m aside when
  // the road is lost. The car still rotates then: it does not drive along a road, it is lost.
  double const sin44 = std::sin(math::DegToRad(44.0));
  double const cos44 = std::cos(math::DegToRad(44.0));
  PieceRoads roads({{-3000, 0, 400, 0}, {163.5, 37.7, 163.5 + 300 * sin44, 37.7 + 300 * cos44}}, {});
  Env env(true /* inertial */, &roads);
  TurnLeftSlowly(env, 46);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnAlongBranchIsNotMovedToNextCrossing)
{
  // A road branches off the street going east to the north-east at 100 m, and a street goes the same way from
  // the crossing at 115 m, 13 m aside of the branch. The branch leaves the street not at a crossing of the map.
  double const sin30 = 0.5;
  double const cos30 = std::sqrt(0.75);
  PieceRoads roads(
      {{-300, 0, 500, 0}, {100, 0, 100 + 300 * sin30, 300 * cos30}, {115, 0, 115 + 300 * sin30, 300 * cos30}},
      {{115, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  // 10 m/s east, then the car takes the branch, 60 degrees to the left: the turn of 19 m radius starts 11 m
  // before the branch.
  env.Drive(7700, 36, 0);
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 89, 3);
  env.Drive(2000, 36, -30);
  env.Drive(4000, 36, 0);
  // The car is on the branch, not on the street going the same way from the crossing.
  auto const & position = env.Last().m_position;
  double const fromBranchM = (East(position) - 100) * cos30 - North(position) * sin30;
  TestAlmostEqualAbs(fromBranchM, 0, 3);
  TEST_GREATER(North(position), 30, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

// A street going east, a street going north from the crossing at 200 m for |crossingEndM| m and another one 40 m to
// the east of it, which has no crossing with the first street on the map and goes north |parallelEndM| m.
PieceRoads TwoStreetsNorth(double crossingEndM, double parallelEndM)
{
  return PieceRoads({{-300, 0, 400, 0}, {200, 0, 200, crossingEndM}, {240, -10, 240, parallelEndM}}, {{200, 0}});
}

// The car turns left at the crossing at 200 m, its calculated position 19 m ahead: the turn ends next to the street
// 40 m to the east, where the regular snapping takes the car, as on October 16. The car has left the roads in the
// turn, it has not followed them there: it is moved to the crossing, and the street to the east is another place
// it may be on.
void TurnLeftBesideCrossing(Env & env)
{
  MarkCar(env, 219 - 112);
  env.Drive(10'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 219, 2);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
  TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 24, 3);
}

UNIT_TEST(NoGps_Engine_TurnFittingTwoStreetsFollowsBoth)
{
  auto roads = TwoStreetsNorth(80, 400);
  Env env(true /* inertial */, &roads);
  TurnLeftBesideCrossing(env);
  // The car may be on either street: the mark stays where the rules put it, the other street is followed too.
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  TEST(env.m_engine.GetTripLine().find(" marks=2 ") != std::string::npos, (env.m_engine.GetTripLine()));
  // That street ends: the car is on the other one.
  env.Drive(10'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 240, 2);
  TEST_GREATER(North(env.Last().m_position), 100, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, ());
}

UNIT_TEST(NoGps_Engine_MarkOnRoadOfShownOneIsDropped)
{
  // The street 40 m to the east turns towards the street of the car 60 m north of the crossing and ends 10 m from
  // it: the other mark comes onto the street of the car behind the shown one, as on October 19 at 17:36.
  PieceRoads roads({{-300, 0, 400, 0}, {200, 0, 200, 600}, {240, -10, 240, 60}, {240, 60, 210, 124}}, {{200, 0}});
  Env env(true /* inertial */, &roads);
  TurnLeftBesideCrossing(env);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  // The two marks are one road: there is no other road to show the car on.
  env.Drive(20'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, (env.m_engine.GetTripLine()));
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_UserSwitchesMarkToAnotherStreet)
{
  auto roads = TwoStreetsNorth(80, 400);
  Env env(true /* inertial */, &roads);
  TurnLeftBesideCrossing(env);
  int const rebuilds = env.m_map.m_rebuilds;
  env.m_engine.SwitchMark();
  // The car is shown on the other street, the route goes from there.
  TestAlmostEqualAbs(East(env.Last().m_position), 240, 2);
  TEST_GREATER(env.m_map.m_rebuilds, rebuilds, ());
  // The street the car was shown on is followed too, until it ends.
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, ());
  env.Drive(10'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 240, 2);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());

  // The user switches again and again: the marks go round.
  auto roads2 = TwoStreetsNorth(400, 400);
  Env env2(true /* inertial */, &roads2);
  TurnLeftBesideCrossing(env2);
  env2.m_engine.SwitchMark();
  TestAlmostEqualAbs(East(env2.Last().m_position), 240, 2);
  env2.m_engine.SwitchMark();
  TestAlmostEqualAbs(East(env2.Last().m_position), 200, 2);
  TEST_EQUAL(env2.m_engine.GetStatus().m_otherMarks, 1, ());
  // A mark of the user tells where the car is.
  env2.Drive(500, 0, 0);
  TEST(env2.m_engine.PlaceMarkByTap(At(200, 70)), ());
  TEST_EQUAL(env2.m_engine.GetStatus().m_otherMarks, 0, ());
}

UNIT_TEST(NoGps_Engine_TurnTellsWhichStreetCarIsOn)
{
  // A short street goes east from the street at 200 m, 150 m to the north, and ends before the one 40 m to the east,
  // which has no street going east there.
  PieceRoads roads({{-300, 0, 400, 0}, {200, 0, 200, 400}, {240, -10, 240, 400}, {200, 150, 235, 150}},
                   {{200, 0}, {200, 150}});
  Env env(true /* inertial */, &roads);
  TurnLeftBesideCrossing(env);
  // The user shows the car on the street to the east, by mistake.
  env.m_engine.SwitchMark();
  TestAlmostEqualAbs(East(env.Last().m_position), 240, 2);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, ());
  while (North(env.Last().m_position) < 140)
    env.Drive(100, 36, 0);
  // The car turns right where only the other street has a street going that way: it is there.
  env.Drive(3000, 36, 30);
  env.Drive(1500, 36, 0);
  TestAlmostEqualAbs(North(env.Last().m_position), 150, 3);
  TEST_LESS(East(env.Last().m_position), 236, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_WayAfterTurnOffRoadsDropsNoMark)
{
  // The street going east ends at the crossing at 200 m, the calculated position is 19 m past it when the car turns:
  // the turn starts off the roads, the rules put the car at the crossing. The way driven lies on the roads only there,
  // but it is drawn along a heading that may be wrong, as on October 16 at 17:19.
  PieceRoads roads({{-300, 0, 200, 0}, {200, 0, 200, 400}, {240, -10, 240, 400}}, {{200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 219 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(8000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
  // The car may be on the other street still: both streets go on, it is followed too.
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_TurnFitsCrossingCarHasPassed)
{
  // The street going east has a side street going north at 200 m only. The mark is 46 m ahead of the car when it turns
  // there, as on November 5 after a yard: the crossing is out of the search, the car is not at a crossing by the
  // rules. It may have passed the crossing: the car may be on the side street too.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}}, {{200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 246 - 112);
  env.Drive(10'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 246, 2);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  // The way driven lies on the side street, not where the mark is: the car is shown there before the road is lost.
  env.Drive(5000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
  TEST_GREATER(North(env.Last().m_position), 30, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnFitsCrossingCarHasNotReached)
{
  // The same, the mark 46 m behind the car: the crossing is ahead of it, the car may be on the side street too.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}}, {{200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 154 - 112);
  env.Drive(10'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 154, 2);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  env.Drive(5000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
  TEST_GREATER(North(env.Last().m_position), 30, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_FarMarkIsNotTakenByFewMisses)
{
  // The car turns north at a crossing, its street goes 6 degrees off the heading, a far crossing is 46 m behind, as on
  // October 24. The way misses the roads at a few points where the car is shown and at none at the far crossing: the
  // car stays shown where the rules put it, the far one is only another mark.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}, {246, 0, 288, 400}}, {{200, 0}, {246, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 246 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(1000, 36, -90);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  env.Drive(20'000, 36, 0);
  TEST_GREATER(East(env.Last().m_position), 250, ());
  TEST_GREATER(North(env.Last().m_position), 100, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnIntoYardTakesNoFarMark)
{
  // The car turns north at a crossing, a far crossing is 46 m behind: the far one is another mark. 110 m later the
  // car turns east into a yard missing on the map, where only the street of the far mark has a road east, as on
  // October 22 at 21:07:33: the car stays shown where it is.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}, {246, 0, 246, 400}, {200, 110, 230, 110}},
                   {{200, 0}, {246, 0}, {200, 110}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 246 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(1000, 36, -90);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  while (North(env.Last().m_position) < 110 - 6)
    env.Drive(100, 36, 0);
  env.Drive(3000, 18, 30);
  env.Drive(3000, 18, 0);
  TEST_GREATER(East(env.Last().m_position), 240, (env.m_engine.GetTripLine()));
  // The far one stays another mark: the way may still tell the car is there.
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_LostRoadTakesFarMark)
{
  // As in the test above the car is shown at the crossing at 246 m, the far one is 46 m behind, its street goes on. The
  // street of the shown mark ends 150 m to the north: it stands lost while the car drives on along the far street.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}, {246, 0, 246, 150}}, {{200, 0}, {246, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 246 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(1000, 36, -90);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  env.Drive(20'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 3);
  TEST_GREATER(North(env.Last().m_position), 150, ());
}

UNIT_TEST(NoGps_Engine_LostRoadTakesNearMarkBeforeFarOne)
{
  // The car turns north at the crossing at 246 m and is shown on the street at 262 m, the other one is at 240 m, a far
  // one at 200 m. The user switches the mark to 240 m: the marks are the far one first, the street at 262 m after it.
  // The street at 240 m ends 150 m to the north: the car stands lost and the mark that is not a far one is taken,
  // not the far one that comes first. FindOtherMarkOnRoad() goes by the far flag, not by the distance.
  PieceRoads roads({{-300, 0, 600, 0}, {262, 0, 262, 400}, {240, 0, 240, 150}, {200, 0, 200, 400}},
                   {{262, 0}, {240, 0}, {200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 246 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(1000, 36, -90);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 2, (env.m_engine.GetTripLine()));
  env.m_engine.SwitchMark();
  env.Drive(1000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 240, 3);
  env.Drive(20'000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 262, 3);
  TEST_GREATER(North(env.Last().m_position), 150, ());
}

UNIT_TEST(NoGps_Engine_OtherMarkSearchesNoFarCrossingBehindAfterUTurn)
{
  // The car turns north at a crossing, the other mark is on the street 46 m aside. It makes a U-turn 100 m to the
  // north and drives back: the street it has left 145 m from the crossing is not the road the marks came by, so a
  // street going west there is not a far crossing behind when the car turns west at the main street.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}, {246, 0, 246, 400}, {100, 145, 200, 145}},
                   {{200, 0}, {246, 0}, {200, 145}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 246 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(1000, 36, -90);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  while (North(env.Last().m_position) < 100)
    env.Drive(100, 36, 0);
  env.Drive(2000, 18, -90);
  env.Drive(2000, 36, 0);
  while (North(env.Last().m_position) > 12)
    env.Drive(100, 36, 0);
  env.Drive(1000, 18, 90);
  env.Drive(3000, 36, 0);
  // The other mark is on the road of the shown one, no far one is added at the street.
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnFitsCrossingOtherMarkHasPassed)
{
  // After the turn the car may be on either street going north. A street goes east from the one 40 m to the east,
  // 150 m to the north. The car turns right 46 m past it by the calculation: only the other mark has passed it.
  PieceRoads roads({{-300, 0, 400, 0}, {200, 0, 200, 400}, {240, -10, 240, 400}, {240, 150, 400, 150}},
                   {{200, 0}, {240, 150}});
  Env env(true /* inertial */, &roads);
  TurnLeftBesideCrossing(env);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  while (North(env.Last().m_position) < 196 - 12)
    env.Drive(100, 36, 0);
  env.Drive(3000, 36, 30);
  env.Drive(5000, 36, 0);
  TestAlmostEqualAbs(North(env.Last().m_position), 150, 3);
  TEST_GREATER(East(env.Last().m_position), 260, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_OtherMarkSearchesCrossingByItsOwnAlongError)
{
  // The car turns left beside two streets going north, 40 m apart: the shown mark is on the street at 200, an other
  // mark is on the one at 240. The car drives 25 km north, and the bends of the shown street tell its place: the
  // shown mark is known then, the other one has the along error of 190 m still. A street goes east from the other
  // street 150 m ahead of where the car turns east: the shown street has none, and the other mark is moved to that
  // street, because it searches by its own along error, not by the shown one.
  double constexpr kTurnNorthM = 26'100;
  double const bend = math::DegToRad(25.0);
  PieceRoads roads({{-300, 0, 400, 0},
                    {200, 0, 200, 25'000},
                    {200, 25'000, 200 + 800 * std::sin(bend), 25'000 + 800 * std::cos(bend)},
                    {200 + 800 * std::sin(bend), 25'000 + 800 * std::cos(bend), 200 + 800 * std::sin(bend), 28'000},
                    {240, -10, 240, 25'000},
                    {240, 25'000, 240 + 800 * std::sin(bend), 25'000 + 800 * std::cos(bend)},
                    {240 + 800 * std::sin(bend), 25'000 + 800 * std::cos(bend), 240 + 800 * std::sin(bend), 28'000},
                    {240 + 800 * std::sin(bend), kTurnNorthM + 150, 1500, kTurnNorthM + 150}},
                   {{200, 0}, {240 + 800 * std::sin(bend), kTurnNorthM + 150}});
  Env env(true /* inertial */, &roads);
  TurnLeftBesideCrossing(env);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  for (int i = 0; i < 25; ++i)
    env.Drive(33'333, 108, 0);
  env.Drive(500, 108, 0);
  env.Drive(1000, 36, 25);
  env.Drive(79'000, 36, 0);
  env.Drive(1000, 36, -25);
  env.Drive(30'000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  TEST_LESS(env.Last().m_accuracyM, 30, (env.m_engine.GetTripLine()));
  // The car turns right where the calculation has it at 26'100 m.
  while (North(env.Last().m_position) < kTurnNorthM - 12)
    env.Drive(100, 36, 0);
  env.Drive(3000, 36, 30);
  // The turn is moved to the crossing of the other mark when it ends, not when the shown road is lost 30 m later.
  env.Drive(2500, 36, 0);
  TestAlmostEqualAbs(North(env.Last().m_position), kTurnNorthM + 150, 3);
  env.Drive(5000, 36, 0);
  TEST_GREATER(East(env.Last().m_position), 600, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnStartedWithoutCrossingIsMatchedLate)
{
  // The car turns left 40 m before the crossing at 200 m by the calculation: no crossing is in reach then. It drives
  // north off the road, and is moved to the crossing when the road is lost, as on October 16 at 17:18.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}}, {{200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 100);
  env.Drive(4000, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(6000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 3);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnDoesNotFitCrossingBeforeKnownPlace)
{
  // The same, the car marked 30 m past the crossing: it has not passed the crossing since, the road is lost.
  PieceRoads roads({{-300, 0, 600, 0}, {200, 0, 200, 400}}, {{200, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 230);
  env.Drive(1600, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnFittingTwoCrossingsKeepsThemInReach)
{
  // Streets go north from the street going east at 200 and 240 m, the one at 240 m to a street going east 100 m to the
  // north. The car turns left 17 m past the crossing at 200 m by the calculation, 23 m before the one at 240 m: both
  // fit, the nearer is taken.
  PieceRoads roads(
      {{-300, 0, 600, 0}, {200, 0, 200, 400}, {240, 0, 240, 100}, {150, 100, 600, 100}, {300, 100, 300, 400}},
      {{200, 0}, {240, 0}, {200, 100}, {240, 100}, {300, 100}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 212 - 112);
  env.Drive(10'000, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(2000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 1, (env.m_engine.GetTripLine()));
  // The car may be at the other crossing: its place is known no better than that.
  TEST_GREATER_OR_EQUAL(env.Last().m_accuracyM, 40, ());

  // The car turns right onto the street going east: the other mark comes onto it 40 m ahead of the shown one and is
  // dropped, the car may be there still.
  while (North(env.Last().m_position) < 100 - 12)
    env.Drive(100, 36, 0);
  env.Drive(3000, 36, 30);
  env.Drive(3000, 36, 0);
  TestAlmostEqualAbs(North(env.Last().m_position), 100, 2);
  TEST_EQUAL(env.m_engine.GetStatus().m_otherMarks, 0, (env.m_engine.GetTripLine()));
  TEST_GREATER_OR_EQUAL(env.Last().m_accuracyM, 40, ());

  // It turns left at the street at 300 m, the mark is 33 m before it: the crossing is still found.
  while (East(env.Last().m_position) < 300 - 33 - 5)
    env.Drive(100, 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(3000, 36, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 300, 2);
  TEST_GREATER(North(env.Last().m_position), 120, (env.m_engine.GetTripLine()));
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_SlowTurnWhereWayMissesRoadsIsNotKnownPlace)
{
  // The car drives at 15 km/h along the street going east and turns left 12 m before the crossing at 200 m by the
  // calculation. On the way there it swerves aside by 10 m and back, as through a yard missing on the map: the way
  // driven misses the street where the turn is moved to, the place is known no better than before.
  for (bool const swerves : {false, true})
  {
    PieceRoads roads({{-400, 0, 600, 0}, {200, 0, 200, 400}}, {{200, 0}});
    Env env(true /* inertial */, &roads);
    MarkCar(env, -150);
    while (East(env.Last().m_position) < 60)
      env.Drive(100, 15, 0);
    if (swerves)
    {
      env.Drive(4000, 15, -5);
      env.Drive(6000, 15, 0);
      env.Drive(4000, 15, 5);
    }
    while (East(env.Last().m_position) < 183)
      env.Drive(100, 15, 0);
    double const accuracyM = env.Last().m_accuracyM;
    env.Drive(3000, 15, -30);
    env.Drive(2000, 15, 0);
    TestAlmostEqualAbs(East(env.Last().m_position), 200, 2);
    TestAlmostEqualAbs(std::stod(TripField(env, "turn")), 12, 3);
    if (swerves)
      TEST_GREATER(env.Last().m_accuracyM, accuracyM, (env.m_engine.GetTripLine()));
    else
      TEST_LESS(env.Last().m_accuracyM, DeadReckoning::kBaseAccuracyM + 1, (env.m_engine.GetTripLine()));
  }
}

UNIT_TEST(NoGps_Engine_CarAtRoundaboutIsNotLost)
{
  // The street the car leaves the roundabout by is where the car is, or 30 m to the left of it: the car came to
  // the roundabout with its distance wrong by that much.
  for (auto const & [roundabout, exitNorth] :
       std::vector<std::pair<bool, double>>{{true, 7.5}, {false, 7.5}, {true, 37.5}, {false, 37.5}})
  {
    // A street going east comes to a roundabout and leaves it to the north of where it came. The mark doesn't
    // follow the circle of the map: here the circle has no pieces at all.
    PieceRoads roads({{-300, 0, -30, 0}, {75, exitNorth, 400, exitNorth}}, {});
    if (roundabout)
      roads.AddRoundabout(15, 0, 25);
    Env env(true /* inertial */, &roads);
    MarkCar(env, -100);
    env.Drive(8000, 27, 0);
    TEST(env.m_engine.GetTripLine().find(" road=1 ") != std::string::npos, (env.m_engine.GetTripLine()));
    // The car drives 7.5 m/s around the circle: to the right, to the left by 70 degrees, straight for 1.5 s, which
    // ends its turn, and slowly to the right for 37 m, slower than a turn begins.
    env.Drive(1000, 27, 45);
    env.Drive(2000, 27, -35);
    env.Drive(1500, 27, 0);
    env.Drive(2500, 27, 5);
    std::string const line = env.m_engine.GetTripLine();
    TEST(line.find(" road=0 ") != std::string::npos, (line));
    TEST_EQUAL(line.find(" ring=1") != std::string::npos, roundabout, (line));
    env.Drive(2500, 27, 5);
    env.Drive(4000, 27, 0);
    // Without the roundabout a car driving so far off the roads is lost and stopped.
    TEST_EQUAL(env.m_delegate.HasEvent(Event::RoadLost), !roundabout, ());
    if (!roundabout)
      continue;
    // The car is on the street it has left the roundabout by.
    TEST(!FollowedApart(env), ());
    std::string const after = env.m_engine.GetTripLine();
    TEST(after.find(" road=1 ") != std::string::npos, (after));
    TEST(after.find(" ring=0") != std::string::npos, (after));
    TestAlmostEqualAbs(North(env.Last().m_position), exitNorth, 1);
    TEST_GREATER(East(env.Last().m_position), 75, ());
    TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 90), 0, 3);
  }
}

UNIT_TEST(NoGps_Engine_MarkAheadWaitsAtRoundaboutForCar)
{
  // As on November 5: 2 km after the tap the mark is 29.5 m ahead by the along error, less than the waiting at a bend
  // needs. The car is 90 m behind it: it drives straight on after its mark has come to the roundabout, stops before
  // it, and drives around it as in NoGps_Engine_CarAtRoundaboutIsNotLost.
  PieceRoads roads({{-3000, 0, -30, 0}, {75, 7.5, 400, 7.5}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(150'000, 48, 0);
  TEST_EQUAL(TripField(env, "road"), "1", ());
  env.Drive(10'000, 48, 0);
  // The mark waits on its road before the roundabout.
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  auto const waiting = env.Last().m_position;
  TEST_LESS(East(waiting), -25, ());
  TEST_GREATER(East(waiting), -45, ());
  env.Drive(2000, 48, 0);
  env.Drive(5000, 0, 0);
  TestAlmostEqualAbs(Distance(env.Last().m_position, waiting), 0, 0.01);
  env.Drive(1000, 27, 45);
  env.Drive(2000, 27, -35);
  env.Drive(1500, 27, 0);
  env.Drive(5000, 27, 5);
  env.Drive(4000, 27, 0);
  // The mark has gone around the roundabout from where it waited and is on the street the car has left it by.
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_EQUAL(TripField(env, "wait"), "-", ());
  TEST_EQUAL(TripField(env, "road"), "1", ());
  TEST_EQUAL(TripField(env, "ring"), "0", ());
  TestAlmostEqualAbs(North(env.Last().m_position), 7.5, 1);
  TEST_GREATER(East(env.Last().m_position), 75, ());
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 90), 0, 3);
}

UNIT_TEST(NoGps_Engine_MarkWaitingAtRoundaboutIsNotPutOnExitAcrossIt)
{
  // The street leaving the roundabout goes on straight across it. The car is 200 m behind its mark: the way straight
  // on from where the mark waits goes through the roundabout to that street, which the car can't drive to straight.
  PieceRoads roads({{-3000, 0, -30, 0}, {60, 0, 400, 0}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(160'000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  auto const waiting = env.Last().m_position;
  env.Drive(13'000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  TestAlmostEqualAbs(Distance(env.Last().m_position, waiting), 0, 0.01);
}

UNIT_TEST(NoGps_Engine_MarkWaitingAtRoundaboutGoesOnAlongRoadPastIt)
{
  // The street going east passes a roundabout 25 m to the north of it, and is missing on the map for 45 m there: the
  // mark loses it next to the roundabout while the car drives straight on.
  PieceRoads roads({{-3000, 0, -5, 0}, {40, 0, 3000, 0}}, {});
  roads.AddRoundabout(15, 40, 15);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(150'000, 48, 0);
  env.Drive(9000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  // The car drives on along the street: the mark is put on it after the roundabout, where the car is.
  env.Drive(20'000, 48, 0);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_EQUAL(TripField(env, "wait"), "-", ());
  TEST_EQUAL(TripField(env, "road"), "1", ());
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 1);
  TestAlmostEqualAbs(East(env.Last().m_position), 287, 20);
}

// Drives the car around the roundabout of NoGps_Engine_MarkAheadWaitsAtRoundaboutForCar and checks that its mark is
// on the street the car has left it by.
void DriveAroundRoundaboutToExit(Env & env, double entryYawDegS = 45)
{
  env.Drive(1000, 27, entryYawDegS);
  env.Drive(2000, 27, -35);
  env.Drive(1500, 27, 0);
  env.Drive(5000, 27, 5);
  env.Drive(4000, 27, 0);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TEST_EQUAL(TripField(env, "road"), "1", ());
  TestAlmostEqualAbs(North(env.Last().m_position), 7.5, 1);
  TEST_GREATER(East(env.Last().m_position), 75, ());
}

UNIT_TEST(NoGps_Engine_MarkWaitingAtRoundaboutGoesOnWhenCarSwervesBeforeIt)
{
  // The car swerves 15 degrees to the right 40 m before the roundabout, as on a road curving into it, and drives so to
  // the roundabout: the mark goes on from where it waited, and comes to the roundabout before the car again.
  PieceRoads roads({{-3000, 0, -30, 0}, {75, 7.5, 400, 7.5}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(160'000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  env.Drive(1000, 48, 15);
  env.Drive(2000, 48, 0);
  env.Drive(5000, 0, 0);
  DriveAroundRoundaboutToExit(env, 30);
}

UNIT_TEST(NoGps_Engine_MarkAheadAtRoundaboutWithCarSlowingDown)
{
  // As in NoGps_Engine_MarkAheadWaitsAtRoundaboutForCar, but the car brakes to 15 km/h before its mark comes to the
  // roundabout, and drives around it slowly.
  PieceRoads roads({{-3000, 0, -30, 0}, {75, 7.5, 400, 7.5}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(150'000, 48, 0);
  TEST_EQUAL(TripField(env, "road"), "1", ());
  env.Drive(25'000, 15, 0);
  env.Drive(1800, 15, 25);
  env.Drive(3600, 15, -19.5);
  env.Drive(2700, 15, 0);
  env.Drive(9000, 15, 2.8);
  env.Drive(4000, 27, 0);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
  TEST_EQUAL(TripField(env, "road"), "1", ());
  TestAlmostEqualAbs(North(env.Last().m_position), 7.5, 1);
  TEST_GREATER(East(env.Last().m_position), 75, ());
}

UNIT_TEST(NoGps_Engine_MarkWaitingAtRoundaboutAfterGapOnMap)
{
  // The street is missing on the map for the last 25 m before the roundabout: the mark has left it there before it
  // comes to the roundabout, and waits at the end of the street.
  PieceRoads roads({{-3000, 0, -65, 0}, {75, 7.5, 400, 7.5}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(160'000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  env.Drive(2000, 48, 0);
  env.Drive(5000, 0, 0);
  DriveAroundRoundaboutToExit(env);
}

UNIT_TEST(NoGps_Engine_MarkWaitingAtRoundaboutAfterLaneChange)
{
  // The car is 200 m behind its mark. It changes lanes before the roundabout, which ends the waiting, drives straight
  // on 60 m and stops at the roundabout.
  PieceRoads roads({{-3000, 0, -30, 0}, {75, 7.5, 400, 7.5}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(160'000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  env.Drive(1000, 48, 12);
  env.Drive(4500, 48, 0);
  env.Drive(1000, 48, -12);
  env.Drive(5000, 0, 0);
  // The car has not come to the roundabout yet: its mark is not on the street it leaves the roundabout by.
  TEST(TripField(env, "road") == "0" || North(env.Last().m_position) < 3, (env.m_engine.GetTripLine()));
  DriveAroundRoundaboutToExit(env);
}

UNIT_TEST(NoGps_Engine_MarkWaitingAtRoundaboutOnGentleBend)
{
  // The car is 250 m behind its mark, and the road bends 13 degrees to the right over 150 m before the roundabout:
  // the mark waits on.
  PieceRoads roads({{-3000, 0, -30, 0}, {75, 7.5, 400, 7.5}}, {});
  roads.AddRoundabout(15, 0, 25);
  Env env(true /* inertial */, &roads);
  MarkCar(env, -2100);
  env.Drive(160'000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  env.Drive(11'000, 48, 1.2);
  env.Drive(2000, 48, 0);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  TEST_LESS(East(env.Last().m_position), -25, ());
  env.Drive(5000, 0, 0);
  DriveAroundRoundaboutToExit(env, 32);
}

// A highway going east: 1 km straight, 600 m bending to the right by 12 degrees, 1 km straight, as pieces of 20 m.
// \param points the starts of the pieces if needed.
std::vector<PieceRoads::Piece> HighwayPieces(std::vector<std::pair<double, double>> * points = nullptr)
{
  std::vector<PieceRoads::Piece> pieces;
  double x = -100;
  double y = 0;
  double bearing = 90;
  for (int i = 0; i < 135; ++i)
  {
    // The bend is the pieces from 1000 m to 1600 m from the start of the car, which is at 0.
    double const from = -100 + i * 20.0;
    if (from >= 1000 && from < 1600)
      bearing += 12.0 / 30;
    double const nx = x + 20 * std::sin(math::DegToRad(bearing));
    double const ny = y + 20 * std::cos(math::DegToRad(bearing));
    pieces.push_back({x, y, nx, ny});
    if (points)
      points->emplace_back(x, y);
    x = nx;
    y = ny;
  }
  return pieces;
}

UNIT_TEST(NoGps_Engine_GentleBendRemovesAlongError)
{
  std::vector<std::pair<double, double>> points;
  PieceRoads roads(HighwayPieces(&points), {});
  Env env(true /* inertial */, &roads);
  int driven = 0;
  // The car stands at 0 and is marked there.
  env.m_engine.SetManualMode(true);
  env.Drive(500, 0, 0);
  TEST(env.m_engine.PlaceMarkByTap(At(0, 3)), ());
  // 50 s to the bend at 72 km/h, 30 s along it, 20 s after it.
  env.Drive(50'000, 72, 0);
  auto const alongError = [&]()
  {
    // The car is |driven| m from where it stood, the road starts 100 m before.
    return std::hypot(East(env.Last().m_position) - points[(driven + 100) / 20].first,
                      North(env.Last().m_position) - points[(driven + 100) / 20].second);
  };
  driven = 1000;
  // The mark runs ahead of the car at the start of the bend: the box speed is taken as 1.2 s old.
  double const before = alongError();
  TEST_GREATER(before, 15.0, ());
  env.Drive(30'000, 72, 0.4);
  env.Drive(20'000, 72, 0);
  driven = 2000;
  TEST_LESS(alongError(), 15.0, (env.m_engine.GetTripLine()));
}

// The car marked at 0 drives east at 108 km/h for 25 km without a known place on a road with no bends: the along error
// is 15 + 0.007 * 25000 = 190 m, a crossing 150 m ahead of the mark is within it, one 330 m ahead is not.
void DriveLongWayAndTurnLeft(Env & env)
{
  MarkCar(env, 0);
  for (int i = 0; i < 25; ++i)
    env.Drive(33'333, 108, 0);
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
  TEST_GREATER(env.Last().m_accuracyM, 100, ());
  env.Drive(3000, 36, -30);
  env.Drive(3000, 36, 0);
}

UNIT_TEST(NoGps_Engine_TurnAfterLongWayIsMovedToFarCrossing)
{
  PieceRoads roads({{-300, 0, 40'000, 0}, {25'225, 0, 25'225, 400}}, {{25'225, 0}});
  Env env(true /* inertial */, &roads);
  DriveLongWayAndTurnLeft(env);
  // The crossing is 150 m ahead, within the along error: the turn is moved to it, and the place is known there.
  TestAlmostEqualAbs(East(env.Last().m_position), 25'225, 3);
  TEST_GREATER(North(env.Last().m_position), 20, ());
  TEST_LESS(env.Last().m_accuracyM, DeadReckoning::kBaseAccuracyM + 1, ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnAfterLongWayIsNotMovedFartherThanAlongError)
{
  PieceRoads roads({{-300, 0, 40'000, 0}, {25'320, 0, 25'320, 400}}, {{25'320, 0}});
  Env env(true /* inertial */, &roads);
  DriveLongWayAndTurnLeft(env);
  // The crossing is 250 m ahead: farther than the along error of 190 m, but within TurnMatcher::kMaxFarSearchM, so
  // the test fails if the search takes the cap instead of the along error. The car has turned somewhere else.
  TEST_EQUAL(TripField(env, "turn"), "NaN", ());
  TEST_LESS(East(env.Last().m_position), 25'200, ());
}

// A street going east for 20 km, then bends by 25 degrees left and right in turn every 800 m, 4 km on.
PieceRoads ZigzagAfterLongWay()
{
  std::vector<PieceRoads::Piece> pieces = {{-300, 0, 20'000, 0}};
  double x = 20'000;
  double y = 0;
  for (int i = 1; i < 6; ++i)
  {
    double const heading = math::DegToRad(i % 2 == 1 ? 65.0 : 90.0);
    pieces.push_back({x, y, x + 800 * std::sin(heading), y + 800 * std::cos(heading)});
    x = pieces.back()[2];
    y = pieces.back()[3];
  }
  return PieceRoads(pieces, {});
}

// The car marked |markShiftM| from itself drives 20 km without a known place: the along error is 155 m. Then it drives
// the zigzag at 36 km/h and rotates through 10 m of each bend.
// \returns where the mark is at the end.
ms::LatLon DriveZigzagAfterLongWay(double markShiftM)
{
  auto roads = ZigzagAfterLongWay();
  Env env(true /* inertial */, &roads);
  MarkCar(env, markShiftM);
  for (int i = 0; i < 26; ++i)
    env.Drive(25'000, 108, 0);
  env.Drive(16'167, 108, 0);
  env.Drive(1000, 36, -25);
  for (int i = 2; i < 6; ++i)
  {
    env.Drive(79'000, 36, 0);
    env.Drive(1000, 36, i % 2 == 0 ? 25 : -25);
  }
  env.Drive(20'000, 36, 0);
  return env.Last().m_position;
}

UNIT_TEST(NoGps_Engine_BendsMoveMarkBehindFartherThanNearSearch)
{
  // The mark put 140 m behind the car is ~100 m behind it at the first bend, farther than kMaxBendShiftM: only the
  // search up to the along error finds the bends where the car rotated, and moves the mark there after it has been
  // told 3 times. The car that was marked right is the reference.
  auto const exact = DriveZigzagAfterLongWay(0);
  auto const behind = DriveZigzagAfterLongWay(-140);
  TestAlmostEqualAbs(Distance(behind, exact), 0, 15);
}

UNIT_TEST(NoGps_Engine_StopsCarThatLeftRoads)
{
  Env env(true /* inertial */);
  MarkCar(env, 50);
  TEST(!env.m_engine.GetStatus().m_roadLost, ());
  // The heading goes wrong slowly, slower than a turn: the car leaves the road.
  env.Drive(12'000, 36, -5);
  env.Drive(5000, 36, 0);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  // The car stands where it was on the road the last time until the user marks it, and the status tells it.
  TEST(env.m_engine.GetStatus().m_roadLost, ());
  auto const stopped = env.Last().m_position;
  env.Drive(2000, 36, 0);
  TestAlmostEqualAbs(Distance(env.Last().m_position, stopped), 0, 0.01);
  TEST(env.m_engine.PlaceMarkByTap(At(300, 0)), ());
  env.Drive(1000, 36, 0);
  TEST_GREATER(East(env.Last().m_position), 300, ());
}

// A road going east bends to the north at 0: its piece up to 17 m east goes 35 degrees off the east, a car going
// straight leaves it there. From 30 m north on it goes north at 20 m east.
PieceRoads RoadBendingNorth()
{
  return PieceRoads({{-35'000, 0, 0, 0}, {0, 0, 14.3, 10}, {14.3, 10, 20, 30}, {20, 30, 20, 1000}}, {});
}

// The car marked |wayM| before the bend drives east without a known place until its mark comes to the bend, ahead of
// the car: it leaves the road there, and waits or is lost.
void DriveMarkToBend(Env & env, double wayM)
{
  MarkCar(env, -wayM);
  env.Drive(std::llround((wayM - 300) / 30 * 1000), 108, 0);
  for (int i = 0; i < 60 && TripField(env, "wait") == "-" && !env.m_delegate.HasEvent(Event::RoadLost); ++i)
    env.Drive(1000, 36, 0);
}

UNIT_TEST(NoGps_Engine_MarkAheadWaitsAtBendForCar)
{
  auto roads = RoadBendingNorth();
  Env env(true /* inertial */, &roads);
  // After 30 km the mark may be 225 m ahead: it waits on its road before the bend.
  DriveMarkToBend(env, 30'000);
  TEST_NOT_EQUAL(TripField(env, "wait"), "-", ());
  TEST_EQUAL(TripField(env, "road"), "1", ());
  auto const waiting = env.Last().m_position;
  TEST_LESS(East(waiting), 0.5, ());
  TEST_GREATER(East(waiting), -15, ());
  TestAlmostEqualAbs(North(waiting), 0, 0.5);
  // The car is 150 m behind the mark: it drives straight to the bend, the mark waits.
  env.Drive(14'000, 36, 0);
  TestAlmostEqualAbs(Distance(env.Last().m_position, waiting), 0, 0.01);
  TEST_GREATER(std::stoi(TripField(env, "wait")), 140, ());
  // The car turns along the bend: the mark goes on from where it waited and is on the road going north.
  env.Drive(3000, 36, -30);
  env.Drive(5000, 36, 0);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_EQUAL(TripField(env, "wait"), "-", ());
  TEST_EQUAL(TripField(env, "road"), "1", ());
  TestAlmostEqualAbs(East(env.Last().m_position), 20, 1);
  // The car has driven 80 m from the bend along the road.
  TestAlmostEqualAbs(North(env.Last().m_position), 30 + 80 - 38, 20);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 5);
}

UNIT_TEST(NoGps_Engine_MarkAheadWaitsNotFartherThanItMayBeAhead)
{
  auto roads = RoadBendingNorth();
  Env env(true /* inertial */, &roads);
  DriveMarkToBend(env, 30'000);
  auto const waiting = env.Last().m_position;
  // The car drives straight on past the bend: it is lost where it left the road when it has driven the 225 m the mark
  // may be ahead.
  env.Drive(20'000, 36, 0);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_GREATER(std::stoi(TripField(env, "wait")), 200, ());
  env.Drive(20'000, 36, 0);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_EQUAL(TripField(env, "lost"), "1", ());
  TEST_EQUAL(TripField(env, "wait"), "-", ());
  TestAlmostEqualAbs(Distance(env.Last().m_position, waiting), 0, 0.01);
}

UNIT_TEST(NoGps_Engine_MarkAfterShortWayDoesNotWaitLong)
{
  for (double const wayM : {4000.0, 1000.0})
  {
    auto roads = RoadBendingNorth();
    Env env(true /* inertial */, &roads);
    // After 4 km the mark may be 43 m ahead: it waits that long. After 1 km 22 m, less than a car off the roads drives
    // before it is lost: it does not wait.
    DriveMarkToBend(env, wayM);
    TEST_EQUAL(TripField(env, "wait") != "-", wayM > 2000, (wayM));
    env.Drive(15'000, 36, 0);
    TEST(env.m_delegate.HasEvent(Event::RoadLost), (wayM));
    // Stopped where it was on the road the last time.
    TEST_LESS(East(env.Last().m_position), 0.5, (wayM));
    TEST_GREATER(East(env.Last().m_position), -15, (wayM));
    TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
  }
}

UNIT_TEST(NoGps_Engine_MarkLooksAlongRoadWhateverGyroscopeCounted)
{
  // The street going east, a street going north crosses it at -100 m.
  PieceRoads roads({{-300, 0, 600, 0}, {-100, -300, -100, 300}}, {{-100, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  env.Drive(2000, 18, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 1);

  // The heading has gone 18 degrees aside of the street the car drives along: the car has left a parking place,
  // and its turns were taken for the turns of the road. The mark is drawn across the street.
  env.Drive(1000, 18, 18);
  env.Drive(4000, 18, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 108, 1);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 2);

  // The user marks the car on the street while it drives: it looks along the street at once, and keeps looking.
  double const east = East(env.Last().m_position);
  TEST(env.m_engine.PlaceMarkByTap(At(east + 10, 2)), ());
  env.Drive(InertialNavigator::kOutputIntervalMs, 18, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 0.01);
  TestAlmostEqualAbs(*env.m_map.m_carHeading, 90, 0.01);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.01);
  env.Drive(2000, 18, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 0.01);
  TestAlmostEqualAbs(East(env.Last().m_position), east + 10 + 10.5, 4);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.01);

  // The same with a heading 25 degrees to the other side, and the way of the street is the one the car goes.
  env.Drive(1000, 18, -25);
  env.Drive(InertialNavigator::kOutputIntervalMs, 18, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 65, 3);
  TEST(env.m_engine.PlaceMarkByTap(At(East(env.Last().m_position), -2)), ());
  env.Drive(InertialNavigator::kOutputIntervalMs, 18, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 0.01);
  // It is turned around by the button only.
  env.m_engine.ReverseDirection();
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 270, 0.01);
  env.m_engine.ReverseDirection();
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 0.01);

  // A mark on the crossing street: the car has turned to it and looks along it.
  env.Drive(1000, 0, 0);
  TEST(env.m_engine.PlaceMarkByTap(At(-100, 100)), ());
  env.Drive(500, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), -100, 1);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 1);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_BranchOfForkIsToldByHeading)
{
  // The street going east forks at 100 m: a branch goes on east, the other one leaves 5 degrees to the right. The
  // route the car follows goes on east.
  double const tan5 = std::tan(math::DegToRad(5.0));
  PieceRoads roads({{-300, 0, 100, 0}, {100, 0, 700, 0}, {100, 0, 700, -600 * tan5}}, {{100, 0}});
  roads.SetRoutePiece(1);
  for (bool right : {false, true})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    // 15 m/s: the car passes the fork in the seventh second, keeping east or turning the 5 degrees.
    env.Drive(6000, 54, 0);
    env.Drive(1000, 54, right ? 5 : 0);
    env.Drive(8000, 54, 0);
    // The route takes a mark that is as near to it as to its road, and here it is so for the first seconds after
    // the fork. The car that has turned is on the branch it has turned to nevertheless.
    double const east = East(env.Last().m_position);
    TEST_GREATER(east, 200, ());
    TestAlmostEqualAbs(North(env.Last().m_position), right ? -(east - 100) * tan5 : 0, 1);
    TestAlmostEqualAbs(*env.Last().m_bearingDeg, right ? 95 : 90, 1);
    TEST(!env.m_delegate.HasEvent(Event::RoadLost), (right));
  }
}

UNIT_TEST(NoGps_Engine_MarkAheadKeepsItsBentBranchOfFork)
{
  // The street going east bends to the right after 100 m, to 30 degrees in 90 m; a branch leaves it there going
  // straight on, 10 degrees to the left.
  PieceRoads roads({{-300, 0, 100, 0},
                    {100, 0, 130, -4},
                    {130, -4, 160, -14},
                    {160, -14, 190, -31},
                    {190, -31, 450, -181},
                    {100, 0, 400, 53}},
                   {{100, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  // The mark is 15 m ahead of the car: it is on the bend while the car still drives east, then the car follows the
  // bend. The mark never takes the branch.
  for (int i = 0; i < 16; ++i)
  {
    env.Drive(1000, 54, i >= 8 && i < 11 ? 10 : 0);
    if (East(env.Last().m_position) > 115)
      TEST_LESS(North(env.Last().m_position), -1, (i, East(env.Last().m_position)));
  }
  TEST_LESS(North(env.Last().m_position), -50, ());
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 120, 3);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_CarOnRoadBesideRouteHasLeftRoute)
{
  Env env(true /* inertial */);
  env.m_map.m_navigating = true;
  env.m_map.m_routeAsideM = 0;
  MarkCar(env, 0);
  env.Drive(5000, 54, 0);
  int const lefts = env.m_map.m_routeLefts;

  // The road of the car leaves the route: the car is on the route for the core while it is nearer to the route
  // than its position may be wrong, tens of meters. A road beside the route for a moment is a wide crossing.
  env.m_map.m_routeAsideM = -25;
  env.Drive(1500, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts, ());
  env.Drive(2000, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts + 1, ());

  // The route built anew does not start from the road of the car: it is not built again and again.
  env.Drive(8000, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts + 1, ());

  // The car has been on the road of the route since, and has left it again, to the other side.
  env.m_map.m_routeAsideM = 1;
  env.Drive(2000, 54, 0);
  env.m_map.m_routeAsideM = 40;
  env.Drive(4000, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts + 2, ());
}

UNIT_TEST(NoGps_Engine_CarNearRouteOrTurningHasNotLeftRoute)
{
  Env env(true /* inertial */);
  env.m_map.m_navigating = true;
  env.m_map.m_routeAsideM = 0;
  MarkCar(env, 0);
  env.Drive(5000, 54, 0);
  int const lefts = env.m_map.m_routeLefts;

  // The other carriageway of the street of the route, or the route cutting a bend of its road.
  env.m_map.m_routeAsideM = 12;
  env.Drive(8000, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts, ());

  // The car turns at a crossing: the mark is off the roads there, and the route is beside it for a while.
  env.m_map.m_routeAsideM = 30;
  env.Drive(4500, 20, 20);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts, ());

  // The core sees a car that far from the route leaving it by itself.
  env.m_map.m_routeAsideM = 2000;
  env.Drive(5000, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts, ());

  // No route is followed.
  env.m_map.m_routeAsideM = 30;
  env.m_map.m_navigating = false;
  env.Drive(5000, 54, 0);
  TEST_EQUAL(env.m_map.m_routeLefts, lefts, ());
}

UNIT_TEST(NoGps_Engine_OtherCarriagewayIsNotBranchOfFork)
{
  // The street going east splits in two carriageways at 100 m, as before a roundabout: the one of the car leaves
  // 15 degrees to the right, the one of the cars coming back, one-way to the west, goes straight on.
  double const tan15 = std::tan(math::DegToRad(15.0));
  PieceRoads roads({{-300, 0, 100, 0}, {100, 0, 700, -600 * tan15}, {700, 0, 100, 0}}, {{100, 0}});
  roads.SetOneWay(2);
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  // The mark is ahead of the car: it has passed the split and the car has not turned yet, so it looks along the
  // carriageway coming back. That one is not a branch the car may take: the mark follows its own carriageway,
  // within the 4 m it drives off it in a second.
  env.Drive(8500, 54, 0);
  double const east = East(env.Last().m_position);
  TEST_GREATER(east, 115, ());
  TestAlmostEqualAbs(North(env.Last().m_position), -(east - 100) * tan15 + 2, 3);
}

UNIT_TEST(NoGps_Engine_MarkSetDuringTurnKeepsLookingAlongRoad)
{
  // The street going east, a street going north crosses it at 100 m, and another street going east 200 m to the
  // north.
  PieceRoads roads({{-300, 0, 600, 0}, {100, -300, 100, 600}, {-300, 200, 600, 200}}, {{100, 0}, {100, 200}});
  for (int standMs : {0, 3000})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    env.Drive(6000, 36, 0);
    TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 1);

    // The car turns left to the street going north. In the middle of the turn, looking north-east, the user
    // marks it on that street: the mark looks north.
    env.Drive(1500, 18, -30);
    TEST(env.m_engine.GetTripLine().find(" turning=1 ") != std::string::npos, (env.m_engine.GetTripLine()));
    TEST(env.m_engine.PlaceMarkByTap(At(100, 15)), ());
    // It may creep on and stand for a while, e.g. letting a car pass, and makes the other half of the turn.
    if (standMs > 0)
      env.Drive(1500, 2, 0);
    env.Drive(standMs, 0, 0);
    env.Drive(1500, 18, -30);
    env.Drive(3000, 18, 0);
    // The mark was not turned away from the street by the rest of the turn.
    TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 2);
    TestAlmostEqualAbs(East(env.Last().m_position), 100, 0.5);
    TEST_GREATER(North(env.Last().m_position), 30, (standMs));
    TEST(env.m_engine.GetTripLine().find(" road=1 ") != std::string::npos, (env.m_engine.GetTripLine()));

    // The next turn is a turn as any other: to the right, to the other street going east.
    env.Drive(31'000, 18, 0);
    env.Drive(3000, 18, 30);
    env.Drive(3000, 18, 0);
    TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 90), 0, 3);
    TestAlmostEqualAbs(North(env.Last().m_position), 200, 1);
    TEST(!env.m_delegate.HasEvent(Event::RoadLost), (standMs));
  }

  // A car turning right is marked on a street that goes farther to the left than it looks: it is not the turn
  // the car is making, the heading was wrong. The mark looks along the street, and a turn right after it is a turn.
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  env.Drive(6000, 36, 0);
  env.Drive(1500, 18, 30);
  TEST(env.m_engine.PlaceMarkByTap(At(100, 15)), ());
  env.Drive(500, 18, 0);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 1);
  env.Drive(1500, 18, -30);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, -45), 0, 3);
}

UNIT_TEST(NoGps_Engine_MarkAheadOnBendComesBackToRoad)
{
  // The street going east bends 25 degrees to the left at 100 m.
  double const sin65 = std::sin(math::DegToRad(65.0));
  double const cos65 = std::cos(math::DegToRad(65.0));
  PieceRoads roads({{-300, 0, 100, 0}, {100, 0, 100 + 600 * sin65, 600 * cos65}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 30);
  env.Drive(4000, 36, 0);
  env.Drive(1000, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 82, 3);

  // The car stands 20 m before the bend, the user taps 15 m behind it: the mark is where the user has put it and
  // looks along the street there.
  TEST(env.m_engine.PlaceMarkByTap(At(100 + 15 * sin65, 15 * cos65)), ());
  env.Drive(500, 0, 0);
  TestAlmostEqualAbs(North(env.Last().m_position), 15 * cos65, 1);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 65, 0.5);

  // The car drives through the bend the mark has passed already: the mark looks 25 degrees aside of the street, is
  // kept on it, and looks along it again in 50 m.
  env.Drive(2000, 36, 0);
  env.Drive(1000, 36, -25);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 40, 3);
  env.Drive(30000, 36, 0);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 65, 3);
  auto const & position = env.Last().m_position;
  TestAlmostEqualAbs((East(position) - 100) * cos65 - North(position) * sin65, 0, 1);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

// A street going east bends 25 degrees left and right in turn every 800 m, 4 km on.
PieceRoads ZigzagStreet()
{
  std::vector<PieceRoads::Piece> pieces;
  double x = -300;
  double y = 0;
  for (int i = 0; i < 6; ++i)
  {
    double const heading = math::DegToRad(i % 2 == 0 ? 90.0 : 65.0);
    double const length = i == 0 ? 1100 : 800;
    pieces.push_back({x, y, x + length * std::sin(heading), y + length * std::cos(heading)});
    x = pieces.back()[2];
    y = pieces.back()[3];
  }
  return PieceRoads(pieces, {});
}

// The car marked on the street drives along it at 36 km/h by its speedometer, 3% faster really: it rotates at the
// bends, which the calculated position comes to 3% later.
void DriveZigzag(Env & env)
{
  MarkCar(env, 0);
  double const realMps = 10 * 1.03;
  // To the first bend at 800 m, then from bend to bend, rotating through 10 m of each.
  env.Drive(std::llround((800 - realMps / 2) / realMps * 1000), 36, 0);
  for (int i = 1; i < 6; ++i)
  {
    env.Drive(1000, 36, i % 2 == 1 ? -25 : 25);
    env.Drive(std::llround((800 - realMps) / realMps * 1000), 36, 0);
  }
}

UNIT_TEST(NoGps_Engine_RoadsTellSpeedErrorBeforeGps)
{
  auto roads = ZigzagStreet();
  Env env(true /* inertial */, &roads);
  TEST_EQUAL(TripField(env, "scale"), "1.000", ());
  DriveZigzag(env);
  // Without GPS the bends have told the car is 3% faster than it reports.
  TEST_GREATER_OR_EQUAL(std::stoi(TripField(env, "rough")), 1, (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(std::stod(TripField(env, "scale")), 1.03, 0.01);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());

  // All the calibration is cleared: the next trip learns it again.
  env.m_engine.ClearSpeedCalibration();
  TEST_EQUAL(TripField(env, "rough"), "0", ());
  TEST_EQUAL(TripField(env, "scale"), "1.000", ());
}

UNIT_TEST(NoGps_Engine_RoadsTellFactorAfterGps)
{
  // GPS has measured the speedometer right at 30-40 km/h and the factor 1 over the last 1.6 km, the car is 3%
  // faster now, e.g. on other tyres.
  SpeedTable table;
  table.OnDistance(36, 400, 400);
  SpeedFactor factor;
  factor.OnDistance(1600, 1600);
  auto roads = ZigzagStreet();
  Env env(true /* inertial */, &roads, [&table, &factor](TestStorage & storage)
  {
    storage.Set(Storage::kSpeedTable, table.Serialize());
    storage.Set(Storage::kSpeedFactor, factor.Serialize());
  });
  DriveZigzag(env);
  // The rough table is not learned, the bends tell the factor over the GPS table: 3.2 km of them count as 800 m
  // of GPS.
  TEST_EQUAL(TripField(env, "rough"), "0", ());
  TestAlmostEqualAbs(std::stod(TripField(env, "factor")), 1 + 0.03 * 800 / 2400, 0.004);
  TestAlmostEqualAbs(std::stod(TripField(env, "scale")), std::stod(TripField(env, "factor")), 0.002);
  TestAlmostEqualAbs(env.m_engine.GetStatus().m_speedTable[3].m_scale, std::stod(TripField(env, "factor")), 1e-3);

  // It is cleared with the calibration.
  env.m_engine.ClearSpeedCalibration();
  TEST_EQUAL(TripField(env, "factor"), "1.000", ());
}

UNIT_TEST(NoGps_Engine_RoadsTellFactorNothingWhereGpsMeasures)
{
  // As above, but GPS switched off for the mark in the sheet tells the car speed is right, and it measures better.
  SpeedTable table;
  table.OnDistance(36, 400, 400);
  SpeedFactor factor;
  factor.OnDistance(1600, 1600);
  auto roads = ZigzagStreet();
  Env env(true /* inertial */, &roads, [&table, &factor](TestStorage & storage)
  {
    storage.Set(Storage::kSpeedTable, table.Serialize());
    storage.Set(Storage::kSpeedFactor, factor.Serialize());
  });
  env.m_engine.SetGpsDisabled(true);
  MarkCar(env, 0);
  auto const drive = [&env](int64_t ms, double yawDegPerSec)
  {
    for (int64_t done = 0; done < ms; done += 1000)
    {
      env.Drive(std::min<int64_t>(1000, ms - done), 36, yawDegPerSec);
      auto const & position = env.Last().m_position;
      env.m_engine.OnFix(GpsAt(env.m_clock, East(position), North(position), *env.Last().m_bearingDeg, 10));
    }
  };
  double const realMps = 10 * 1.03;
  drive(std::llround((800 - realMps / 2) / realMps * 1000), 0);
  for (int i = 1; i < 6; ++i)
  {
    drive(1000, i % 2 == 1 ? -25 : 25);
    drive(std::llround((800 - realMps) / realMps * 1000), 0);
  }
  TestAlmostEqualAbs(std::stod(TripField(env, "factor")), 1, 0.002);
}

UNIT_TEST(NoGps_Engine_GpsFollowsStepChangeOfSpeedError)
{
  // The table has measured 10 km at 30-40 km/h with the car 3% slow, the error is 1.5% overnight.
  SpeedTable table;
  table.OnDistance(36, 10'000, 10'300);
  PieceRoads roads({{-300, 0, 4000, 0}}, {});
  Env env(true /* inertial */, &roads,
          [&table](TestStorage & storage) { storage.Set(Storage::kSpeedTable, table.Serialize()); });
  MarkCar(env, 0);
  TestAlmostEqualAbs(std::stod(TripField(env, "scale")), 1.03, 1e-3);
  env.m_engine.SetGpsDisabled(true);
  for (int i = 0; i < 300; ++i)
  {
    env.Drive(1000, 36, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 10.15 * i, 0, 90.0, 10.15));
  }
  // 3 km later the range has moved a little, the factor has taken the rest.
  TEST_GREATER(env.m_engine.GetStatus().m_speedTable[3].m_carM, 0, ());
  TEST_ALMOST_EQUAL_ABS(std::stod(TripField(env, "scale")), 1.015, 0.003, (env.m_engine.GetTripLine()));
  TEST_LESS(std::stod(TripField(env, "factor")), 0.995, ());
}

UNIT_TEST(NoGps_Engine_WrongGpsSpeedTellsFactorNothing)
{
  // The table is right at 30-40 km/h, GPS tells 10% faster for 40 s.
  SpeedTable table;
  table.OnDistance(36, 10'000, 10'000);
  SpeedFactor factor;
  factor.OnDistance(2000, 2000);
  PieceRoads roads({{-300, 0, 4000, 0}}, {});
  Env env(true /* inertial */, &roads, [&table, &factor](TestStorage & storage)
  {
    storage.Set(Storage::kSpeedTable, table.Serialize());
    storage.Set(Storage::kSpeedFactor, factor.Serialize());
  });
  MarkCar(env, 0);
  env.m_engine.SetGpsDisabled(true);
  for (int i = 0; i < 40; ++i)
  {
    env.Drive(1000, 36, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 10 * i, 0, 90.0, 11));
  }
  TEST_EQUAL(TripField(env, "factor"), "1.000", ());
}

UNIT_TEST(NoGps_Engine_TurnAtCrossingTellsSpeedError)
{
  // The street going east bends 25 degrees to the left at 800 m, a street crosses it 500 m after the bend.
  double const sin65 = std::sin(math::DegToRad(65.0));
  double const cos65 = std::cos(math::DegToRad(65.0));
  double const crossingEast = 800 + 500 * sin65;
  double const crossingNorth = 500 * cos65;
  double const sin335 = std::sin(math::DegToRad(335.0));
  double const cos335 = std::cos(math::DegToRad(335.0));
  PieceRoads roads({{-300, 0, 800, 0},
                    {800, 0, 800 + 900 * sin65, 900 * cos65},
                    {crossingEast - 300 * sin335, crossingNorth - 300 * cos335, crossingEast + 400 * sin335,
                     crossingNorth + 400 * cos335}},
                   {{crossingEast, crossingNorth}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  // The car is 3% faster than it reports: the bend moves the mark ahead, from there the turn at the crossing tells
  // the error.
  double const realMps = 10 * 1.03;
  env.Drive(std::llround((800 - realMps / 2) / realMps * 1000), 36, 0);
  env.Drive(1000, 36, -25);
  env.Drive(std::llround((495 - realMps / 2) / realMps * 1000), 36, 0);
  TEST_EQUAL(TripField(env, "rough"), "0", ());
  env.Drive(3000, 36, -30);
  env.Drive(3000, 36, 0);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 335), 0, 3);
  TEST_GREATER(std::stod(TripField(env, "turn")), 5, ());
  TEST_EQUAL(TripField(env, "rough"), "1", (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(std::stod(TripField(env, "scale")), 1.03, 0.01);
}

UNIT_TEST(NoGps_Engine_TurnFittingTwoCrossingsTellsNoSpeedError)
{
  // As above, another street crosses the street after the bend 30 m before the crossing, parallel to the other one:
  // the turn fits both, it tells nothing about the speed.
  double const sin65 = std::sin(math::DegToRad(65.0));
  double const cos65 = std::cos(math::DegToRad(65.0));
  double const sin335 = std::sin(math::DegToRad(335.0));
  double const cos335 = std::cos(math::DegToRad(335.0));
  std::vector<PieceRoads::Piece> pieces{{-300, 0, 800, 0}, {800, 0, 800 + 900 * sin65, 900 * cos65}};
  std::vector<std::pair<double, double>> crossings;
  for (double const alongM : {470.0, 500.0})
  {
    double const east = 800 + alongM * sin65;
    double const north = alongM * cos65;
    pieces.push_back({east - 300 * sin335, north - 300 * cos335, east + 400 * sin335, north + 400 * cos335});
    crossings.emplace_back(east, north);
  }
  PieceRoads roads(pieces, crossings);
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  double const realMps = 10 * 1.03;
  env.Drive(std::llround((800 - realMps / 2) / realMps * 1000), 36, 0);
  env.Drive(1000, 36, -25);
  env.Drive(std::llround((495 - realMps / 2) / realMps * 1000), 36, 0);
  env.Drive(3000, 36, -30);
  env.Drive(3000, 36, 0);
  TEST_GREATER(std::stod(TripField(env, "turn")), 5, ());
  TEST_EQUAL(TripField(env, "rough"), "0", (env.m_engine.GetTripLine()));
  TEST_EQUAL(TripField(env, "scale"), "1.000", ());
}

UNIT_TEST(NoGps_Engine_GpsOffInSheetMeasuresSpeedOverRoughTable)
{
  // The roads have told the speedometer is 5% low at 30-40 km/h on the first trip.
  SpeedTable rough;
  rough.OnDistance(36, 1000, 1050);
  Env env(true /* inertial */, nullptr,
          [&rough](TestStorage & storage) { storage.Set(Storage::kRoughSpeedTable, rough.Serialize()); });
  MarkCar(env, 0);
  TEST_EQUAL(TripField(env, "scale"), "1.050", ());
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_speedTableRanges, 0, ());

  // The user has switched GPS off in the sheet to drive without it, GPS works on: the car is not put where GPS
  // tells, but GPS measures the speedometer 3% low.
  env.m_engine.SetGpsDisabled(true);
  for (int i = 0; i < 60; ++i)
  {
    env.Drive(1000, 36, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 10.3 * i, 0, 90.0, 10.3));
  }
  TEST_NOT_EQUAL(env.Last().m_provider, Provider::Gps, ());
  TEST_GREATER_OR_EQUAL(env.m_engine.GetStatus().m_speedTableRanges, 1, ());
  TestAlmostEqualAbs(std::stod(TripField(env, "scale")), 1.03, 0.005);
}

UNIT_TEST(NoGps_Engine_StatusShowsSpeedTableInUse)
{
  // The roads have told the speedometer is 5% low at 30-40 km/h.
  SpeedTable rough;
  rough.OnDistance(36, 1000, 1050);
  Env roughOnly(true /* inertial */, nullptr,
                [&rough](TestStorage & storage) { storage.Set(Storage::kRoughSpeedTable, rough.Serialize()); });
  MarkCar(roughOnly, 0);
  auto status = roughOnly.m_engine.GetStatus();
  TEST_EQUAL(status.m_speedTable[3].m_carM, 1000, ());
  TestAlmostEqualAbs(status.m_speedTable[3].m_scale, 1.05, 1e-9);

  // GPS has measured 50-60 km/h: its table is shown, the rough one is not.
  SpeedTable gps;
  gps.OnDistance(55, 400, 408);
  Env withGps(true /* inertial */, nullptr, [&rough, &gps](TestStorage & storage)
  {
    storage.Set(Storage::kRoughSpeedTable, rough.Serialize());
    storage.Set(Storage::kSpeedTable, gps.Serialize());
  });
  MarkCar(withGps, 0);
  status = withGps.m_engine.GetStatus();
  TEST_EQUAL(status.m_speedTable[3].m_carM, 0, ());
  TEST_EQUAL(status.m_speedTable[3].m_scale, 0, ());
  TEST_EQUAL(status.m_speedTable[5].m_carM, 400, ());
  TestAlmostEqualAbs(status.m_speedTable[5].m_scale, 1.02, 1e-9);
}

// The car drives east along the street at |kmh| for |seconds| with the GPS of the phone switched off in the sheet:
// GPS tells the speed of the car, and measures it, but the car is not put where it tells.
void DriveWithGps(Env & env, int seconds, int kmh)
{
  for (int i = 0; i < seconds; ++i)
  {
    env.Drive(1000, kmh, 0);
    auto const & position = env.Last().m_position;
    env.m_engine.OnFix(GpsAt(env.m_clock, East(position), North(position), 90.0, kmh / 3.6));
  }
}

int CountEvents(Env const & env, Event event)
{
  return static_cast<int>(std::count(env.m_delegate.m_events.begin(), env.m_delegate.m_events.end(), event));
}

/// Drives with GPS at |kmh| until GPS measures a range, \returns false if it doesn't within a minute.
bool DriveUntilRangeCalibrated(Env & env, int kmh)
{
  int const before = CountEvents(env, Event::SpeedRangeCalibrated);
  for (int i = 0; i < 60; ++i)
  {
    DriveWithGps(env, 1, kmh);
    if (CountEvents(env, Event::SpeedRangeCalibrated) > before)
      return true;
  }
  return false;
}

/// A table GPS has measured |ranges| of, the others are 50 m short of it.
SpeedTable GpsTable(std::set<int> const & ranges)
{
  SpeedTable table;
  for (int i = 0; i < SpeedTable::kRanges; ++i)
  {
    double const carM = ranges.count(i) ? SpeedTable::kMinDistanceM : SpeedTable::kMinDistanceM - 50;
    table.OnDistance(i * SpeedTable::kRangeKmh + 7, carM, carM);
  }
  return table;
}

/// The box says 100 km/h, GPS 60: seconds of fixes at the car position.
bool IsGpsSpoofedBySpeed(Env & env)
{
  for (int i = 0; i < 2 * GpsSpoofingDetector::kSpeedMismatchFixes; ++i)
  {
    env.Drive(1000, 100, 0);
    auto const & position = env.Last().m_position;
    env.m_engine.OnFix(GpsAt(env.m_clock, East(position), North(position), 90.0, 60 / 3.6));
  }
  return env.m_engine.GetStatus().m_gpsSpoofed;
}

UNIT_TEST(NoGps_Engine_CarSpeedIsNotCheckedBeforeItsScaleIsMeasured)
{
  // The default scale may be far off, e.g. a box in mph: GPS is not called spoofed by it, and can't be stuck so.
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  TEST(!IsGpsSpoofedBySpeed(env), ());
}

UNIT_TEST(NoGps_Engine_CarSpeedChecksGpsOnceItsScaleIsMeasured)
{
  SpeedTable table;
  table.OnDistance(100, 400, 400);
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads,
          [&table](TestStorage & storage) { storage.Set(Storage::kSpeedTable, table.Serialize()); });
  MarkCar(env, 0);
  TEST(IsGpsSpoofedBySpeed(env), ());
}

UNIT_TEST(NoGps_Engine_MphCarSpeedIsConverted)
{
  // The box of this car tells 62 where the car drives 100 km/h, and GPS says so for a couple of kilometers.
  int constexpr kRawKmh = 62;
  double const realMps = kRawKmh * SpeedUnit::kMph / 3.6;
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  env.Drive(1000, kRawKmh, 0);
  // Until GPS has told the unit the car speed is taken as it comes.
  TEST_EQUAL(TripField(env, "speed"), std::to_string(kRawKmh), ());
  for (int i = 0; i < 80; ++i)
  {
    env.Drive(1000, kRawKmh, 0);
    auto const & position = env.Last().m_position;
    env.m_engine.OnFix(GpsAt(env.m_clock, East(position), North(position), 90.0, realMps));
  }
  TEST_EQUAL(TripField(env, "speed"), "100", ());
  // The tables learned in the other unit are cleared, the unit is kept for the next trip.
  TEST_EQUAL(env.m_engine.GetStatus().m_speedTableRanges, 0, ());
  SpeedUnit saved;
  saved.Deserialize(env.m_storage.Get<std::string>(Storage::kSpeedUnit, ""));
  TEST_EQUAL(saved.Get(), SpeedUnit::kMph, ());

  // The application starts again: the first speed of the box is converted already.
  Env after(true /* inertial */, &roads, SavedBy(env));
  after.Drive(1000, kRawKmh, 0);
  TEST_EQUAL(TripField(after, "speed"), "100", ());
}

UNIT_TEST(NoGps_Engine_SpeedUnitChangeClearsWhatTheOtherUnitLearned)
{
  // The roads have measured the error of the raw speed of this car, as far as the clamp of the table allows, and the
  // user has shifted the mark: both were learned with the car taken for a km/h one.
  SpeedTable rough(false /* learnsOffset */);
  rough.OnDistance(62, 400, 500);
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads, [&rough](TestStorage & storage)
  {
    storage.Set(Storage::kRoughSpeedTable, rough.Serialize());
    storage.Set(Storage::kSpeedScale, 1.15);
  });
  MarkCar(env, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());

  // The box tells 62 where GPS drives 100 km/h: the unit of the car turns out to be mph.
  int constexpr kRawKmh = 62;
  double const realMps = kRawKmh * SpeedUnit::kMph / 3.6;
  for (int i = 0; i < 80; ++i)
  {
    env.Drive(1000, kRawKmh, 0);
    auto const & position = env.Last().m_position;
    env.m_engine.OnFix(GpsAt(env.m_clock, East(position), North(position), 90.0, realMps));
  }
  TEST_EQUAL(TripField(env, "speed"), "100", ());
  // Nothing learned in the other unit is kept.
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 0, ());
  TEST_EQUAL(env.m_storage.Get<double>(Storage::kSpeedScale, 0), 1.0, ());
}

UNIT_TEST(NoGps_Engine_ResetOfTheSpeedCalibrationForgetsTheUnit)
{
  // The box of this car tells 62 where GPS drives 100 km/h: mph is learned.
  int constexpr kRawKmh = 62;
  double const realMps = kRawKmh * SpeedUnit::kMph / 3.6;
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  for (int i = 0; i < 80; ++i)
  {
    env.Drive(1000, kRawKmh, 0);
    auto const & position = env.Last().m_position;
    env.m_engine.OnFix(GpsAt(env.m_clock, East(position), North(position), 90.0, realMps));
  }
  TEST_EQUAL(TripField(env, "speed"), "100", ());

  // The box is moved to a car that tells km/h and the user resets the calibration: the unit of the car before is
  // forgotten too, otherwise the mark runs 61% too fast until tens of kilometers of GPS unlearn it.
  env.m_engine.ClearSpeedCalibration();
  TEST_EQUAL(TripField(env, "speed"), std::to_string(kRawKmh), ());
  SpeedUnit saved;
  saved.Deserialize(env.m_storage.Get<std::string>(Storage::kSpeedUnit, ""));
  TEST_EQUAL(saved.Get(), 1.0, ());

  // The application starts again: the raw speed of the box is taken as it comes.
  Env after(true /* inertial */, &roads, SavedBy(env));
  after.Drive(1000, kRawKmh, 0);
  TEST_EQUAL(TripField(after, "speed"), std::to_string(kRawKmh), ());
}

UNIT_TEST(NoGps_SpeedHint_ShownAtSpeedGpsHasNotMeasured)
{
  // GPS has measured 50-60 km/h.
  auto const table = GpsTable({5});
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads,
          [&table](TestStorage & storage) { storage.Set(Storage::kSpeedTable, table.Serialize()); });
  MarkCar(env, 0);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());

  // Not below 5 km/h: the speed is too rough there.
  env.Drive(5000, SpeedTable::kMinSpeedKmh - 1, 0);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());

  // Not at once at 30-40 km/h, which GPS has not measured.
  env.Drive(Engine::kSpeedHintDelayMs - 200, 36, 0);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());
  env.Drive(2000, 36, 0);
  auto status = env.m_engine.GetStatus();
  TEST(status.m_speedHintShown, ());
  TEST_EQUAL(status.m_speedHintRange, 3, ());
  TEST(!status.m_speedHintGps, ());
  TEST_EQUAL(status.m_gpsSpeedTable[3].m_scale, 0, ());
  TEST_EQUAL(status.m_gpsSpeedTable[3].m_carM, SpeedTable::kMinDistanceM - 50, ());
  TEST_GREATER(status.m_gpsSpeedTable[5].m_scale, 0, ());

  // It stays a while at the measured 50-60 km/h, telling about 30-40 km/h.
  env.Drive(Engine::kSpeedHintLingerMs - 1000, 55, 0);
  status = env.m_engine.GetStatus();
  TEST(status.m_speedHintShown, ());
  TEST_EQUAL(status.m_speedHintRange, 3, ());
  env.Drive(2000, 55, 0);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());

  // As when the car slows down.
  env.Drive(3000, 25, 0);
  TEST(env.m_engine.GetStatus().m_speedHintShown, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_speedHintRange, 2, ());
  env.Drive(Engine::kSpeedHintLingerMs - 1000, 0, 0);
  TEST(env.m_engine.GetStatus().m_speedHintShown, ());
  env.Drive(2000, 0, 0);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());
  TEST(!env.m_delegate.HasEvent(Event::SpeedRangeCalibrated), ());
}

UNIT_TEST(NoGps_SpeedHint_GpsMeasuresRangeOnce)
{
  auto const table = GpsTable({});
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads,
          [&table](TestStorage & storage) { storage.Set(Storage::kSpeedTable, table.Serialize()); });
  MarkCar(env, 0);
  env.m_engine.SetGpsDisabled(true);
  DriveWithGps(env, 3, 36);
  auto status = env.m_engine.GetStatus();
  TEST(status.m_speedHintShown, ());
  TEST_EQUAL(status.m_speedHintRange, 3, ());

  // GPS measures the range: the bar tells it, and doesn't stay.
  TEST(DriveUntilRangeCalibrated(env, 36), ());
  status = env.m_engine.GetStatus();
  TEST_EQUAL(status.m_speedHintRange, 3, ());
  TEST_EQUAL(status.m_speedMilestone, SpeedMilestone::Range, ());
  TEST_GREATER(status.m_gpsSpeedTable[3].m_scale, 0, ());
  TEST(!status.m_speedHintShown, ());
  TEST(status.m_speedHintGps, ());
  DriveWithGps(env, 10, 36);
  TEST_EQUAL(CountEvents(env, Event::SpeedRangeCalibrated), 1, ());
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());

  // GPS measures nothing a while after its last good position.
  env.Drive(3000, 25, 0);
  status = env.m_engine.GetStatus();
  TEST(status.m_speedHintShown, ());
  TEST_EQUAL(status.m_speedHintRange, 2, ());
  TEST(!status.m_speedHintGps, ());

  // A cleared table is measured anew.
  env.m_engine.ClearSpeedCalibration();
  env.Drive(3000, 36, 0);
  TEST(env.m_engine.GetStatus().m_speedHintShown, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_speedHintRange, 3, ());
}

UNIT_TEST(NoGps_SpeedHint_TableRestoredIsNotMeasuredAgain)
{
  // GPS measured 30-40 km/h on the trip before.
  auto const table = GpsTable({3});
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads,
          [&table](TestStorage & storage) { storage.Set(Storage::kSpeedTable, table.Serialize()); });
  MarkCar(env, 0);
  env.m_engine.SetGpsDisabled(true);
  DriveWithGps(env, 20, 36);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());
  TEST(!env.m_delegate.HasEvent(Event::SpeedRangeCalibrated), ());
}

UNIT_TEST(NoGps_SpeedHint_Milestones)
{
  // All but 50-60, 90-100 and 130+ km/h are measured.
  auto const table = GpsTable({0, 1, 2, 3, 4, 6, 7, 8, 10, 11, 12});
  PieceRoads roads({{-300, 0, 10'000, 0}}, {});
  Env env(true /* inertial */, &roads,
          [&table](TestStorage & storage) { storage.Set(Storage::kSpeedTable, table.Serialize()); });
  MarkCar(env, 0);
  env.m_engine.SetGpsDisabled(true);

  TEST(DriveUntilRangeCalibrated(env, 55), ());
  auto status = env.m_engine.GetStatus();
  TEST_EQUAL(status.m_speedHintRange, 5, ());
  TEST_EQUAL(status.m_speedMilestone, SpeedMilestone::City, ());

  TEST(DriveUntilRangeCalibrated(env, 95), ());
  status = env.m_engine.GetStatus();
  TEST_EQUAL(status.m_speedHintRange, 9, ());
  TEST_EQUAL(status.m_speedMilestone, SpeedMilestone::OutOfTown, ());

  TEST(DriveUntilRangeCalibrated(env, 135), ());
  status = env.m_engine.GetStatus();
  TEST_EQUAL(status.m_speedHintRange, 13, ());
  TEST_EQUAL(status.m_speedMilestone, SpeedMilestone::Full, ());
  TEST_EQUAL(CountEvents(env, Event::SpeedRangeCalibrated), 3, ());

  // Nothing is left to measure.
  DriveWithGps(env, 5, 25);
  TEST(!env.m_engine.GetStatus().m_speedHintShown, ());
}

UNIT_TEST(NoGps_Engine_BendsToldRepeatedlyMoveSlowCar)
{
  // The street going east bends evenly by 30 degrees to the left at 200 m: by 5 degrees in a second at 20 km/h.
  double constexpr kBendStartM = 200;
  double constexpr kPieceM = 20 / 3.6;
  std::vector<PieceRoads::Piece> pieces = {{-300, 0, kBendStartM, 0}};
  double endEast = kBendStartM;
  double endNorth = 0;
  for (int i = 0; i < 6; ++i)
  {
    double const bearing = math::DegToRad(87.5 - 5 * i);
    pieces.push_back(
        {endEast, endNorth, endEast + kPieceM * std::sin(bearing), endNorth + kPieceM * std::cos(bearing)});
    endEast = pieces.back()[2];
    endNorth = pieces.back()[3];
  }
  double const sin60 = std::sin(math::DegToRad(60.0));
  double const cos60 = std::cos(math::DegToRad(60.0));
  pieces.push_back({endEast, endNorth, endEast + 600 * sin60, endNorth + 600 * cos60});
  PieceRoads roads(pieces, {});
  Env env(true /* inertial */, &roads);

  // The user marks the car 15 m ahead of it. The car drives slower than a single look at the bends is trusted at.
  MarkCar(env, 15);
  while (East(env.Last().m_position) < kBendStartM + 15)
    env.Drive(100, 20, 0);
  double const bendOdometerM = std::stod(TripField(env, "odo"));
  env.Drive(6000, 20, -5);
  env.Drive(20000, 20, 0);

  // The bends have told the mark is ahead several times while the car drove on: it is where the car is.
  double const afterBendM = std::stod(TripField(env, "odo")) - bendOdometerM - 6 * kPieceM;
  TEST_GREATER(afterBendM, 50, ());
  auto const car = At(endEast + afterBendM * sin60, endNorth + afterBendM * cos60);
  TestAlmostEqualAbs(Distance(env.Last().m_position, car), 0, 4);
}

UNIT_TEST(NoGps_Engine_TellsThatMovedBoxDoesNotFollowCar)
{
  Env env(true /* inertial */);
  MarkCar(env, 50);
  env.Drive(5000, 36, 0);
  TEST_GREATER(East(env.Last().m_position), 90, ());
  TEST(!env.m_delegate.HasEvent(Event::NotCalibrated), ());

  // The box tells it has been moved in the car: its rotation is not trusted, the car is not followed.
  auto const stopped = env.Last().m_position;
  int const movedFlags = kCalibratedFlags | esp32::kFlagMountMoved;
  env.Drive(Engine::kNotCalibratedDelayMs - 1500, 36, 0, movedFlags);
  // Not at once: the box needs a couple of seconds after it wakes up.
  TEST(!env.m_delegate.HasEvent(Event::NotCalibrated), ());
  env.Drive(4000, 36, 0, movedFlags);
  TEST(env.m_delegate.HasEvent(Event::NotCalibrated), ());
  TestAlmostEqualAbs(Distance(env.Last().m_position, stopped), 0, 0.01);

  // The user is told once in a while, not every second, and not while the car stands.
  auto const count = [&env]
  { return std::count(env.m_delegate.m_events.begin(), env.m_delegate.m_events.end(), Event::NotCalibrated); };
  TEST_EQUAL(count(), 1, ());
  env.Drive(Engine::kMotionSourceWarningIntervalMs, 36, 0, movedFlags);
  TEST_EQUAL(count(), 2, ());
  env.Drive(Engine::kMotionSourceWarningIntervalMs + 5000, 0, 0, movedFlags);
  TEST_EQUAL(count(), 2, ());

  // Calibrated again: the car is followed.
  env.Drive(3000, 36, 0);
  TEST_GREATER(Distance(env.Last().m_position, stopped), 10, ());
}

UNIT_TEST(NoGps_Engine_AdvisesToCalibratePluggedBox)
{
  Env env(true /* inertial */);
  auto const count = [&env]
  { return std::count(env.m_delegate.m_events.begin(), env.m_delegate.m_events.end(), Event::BoxCalibrationAdvised); };
  auto const advised = [&env] { return env.m_engine.GetStatus().m_boxCalibrationAdvised; };
  // The first event of the journal of the box: how it has started.
  auto const boot = [&env](std::string const & reason)
  { env.m_engine.OnEsp32BleBytes(BoxLine("NGE,1,1,40,I,BOOT,fw 0.3.3 reset " + reason)); };
  // The box tells about itself, its firmware doesn't count its power-ons.
  auto const info = [&env]
  {
    env.m_engine.OnEsp32BleBytes(
        BoxLine("NGI,1,0.3.3,2026-10-10T07:33,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,WIFI BLE OTA"));
  };

  // The box was plugged into the car: it may stand in another way than it was calibrated.
  env.Drive(2000, 0, 0);
  boot("POWERON");
  env.Drive(2000, 0, 0);
  // Not before the box tells what it is.
  TEST_EQUAL(count(), 0, ());
  TEST(!advised(), ());
  info();
  env.Drive(2000, 0, 0);
  TEST_EQUAL(count(), 1, ());
  TEST(advised(), ());
  // The user is told once, the status tells it until the box is calibrated.
  env.Drive(5000, 0, 0);
  TEST_EQUAL(count(), 1, ());
  TEST(advised(), ());

  env.m_engine.Calibrate();
  std::string const command = env.m_delegate.m_esp32BleSent.back();
  auto const idEnd = command.find(",CAL_UP*");
  TEST(idEnd != std::string::npos, (command));
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + command.substr(5, idEnd - 5) + ",OK"));
  env.Drive(2000, 0, 0);
  TEST(!advised(), ());

  // The journal of the box is read again: the same power-on.
  env.m_engine.SetEsp32Source(true);
  env.ConnectBox();
  env.Drive(1000, 0, 0);
  info();
  boot("POWERON");
  env.Drive(2000, 0, 0);
  TEST_EQUAL(count(), 1, ());
  TEST(!advised(), ());

  // The box has slept, its clock is 5 % slow then: still the same power-on.
  env.m_clock.Advance(1'000'000);
  env.SleepBox(950'000);
  env.Drive(3000, 0, 0);
  TEST_EQUAL(count(), 1, ());
  TEST(!advised(), ());

  // It has restarted by itself and stays in its place.
  env.RestartBox();
  env.Drive(1000, 0, 0);
  boot("SW");
  env.Drive(2000, 0, 0);
  TEST_EQUAL(count(), 1, ());
  TEST(!advised(), ());

  // Plugged in again while the car drives: the user is told when it stops.
  env.RestartBox();
  env.Drive(1000, 36, 0);
  boot("POWERON");
  env.Drive(3000, 36, 0);
  TEST_EQUAL(count(), 1, ());
  TEST(advised(), ());
  env.Drive(2000, 0, 0);
  TEST_EQUAL(count(), 2, ());
}

// The box is connected and shakes at |shakePct|; the user asks to calibrate it when the car stands still.
class CalibrateWhenStillBox
{
public:
  // An uncalibrated box asks to be calibrated by the core, see Engine::NeedsBoxCalibration().
  explicit CalibrateWhenStillBox(Env & env, bool calibrated = true)
    : m_env(env)
    , m_flags(calibrated ? kCalibratedFlags : esp32::kFlagImuOk | esp32::kFlagObdOk)
  {
    env.ConnectBox();
    env.Drive(1000, 0, 0, m_flags, 150);
  }

  void Wait(int64_t ms, bool still, int shakePct)
  {
    m_env.Drive(ms, 0, 0, m_flags | (still ? esp32::kFlagStill : 0), shakePct);
  }

  void Drive(int64_t ms, int speedKmh, int shakePct) { m_env.Drive(ms, speedKmh, 0, m_flags, shakePct); }

  // The box has found its vertical.
  void SetCalibrated() { m_flags = kCalibratedFlags; }

  size_t Calibrations() const
  {
    auto const & sent = m_env.m_delegate.m_esp32BleSent;
    return std::count_if(sent.begin(), sent.end(),
                         [](std::string const & line) { return line.find(",CAL_UP*") != std::string::npos; });
  }

  void Reply(std::string const & reply)
  {
    // The phone says hello to the box every second, the calibration is not the last command.
    auto const & sent = m_env.m_delegate.m_esp32BleSent;
    auto const it = std::find_if(sent.rbegin(), sent.rend(),
                                 [](std::string const & line) { return line.find(",CAL_UP*") != std::string::npos; });
    TEST(it != sent.rend(), ());
    auto const idEnd = it->find(",CAL_UP*");
    m_env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + it->substr(5, idEnd - 5) + "," + reply));
  }

  Env & m_env;
  int m_flags;
};

UNIT_TEST(NoGps_Engine_CalibratesBoxWhenCarStands)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env);
  env.m_engine.CalibrateWhenStill();
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
  // The car shakes, then it stands for a while, but the box has not told it is still.
  box.Wait(2000, false, 150);
  TEST_EQUAL(box.Calibrations(), 0, ());
  TEST(!env.m_engine.GetStatus().m_boxStill, ());
  TEST_EQUAL(env.m_engine.GetBoxShake().size(), Esp32Source::kShakeLines, ());
  TEST_EQUAL(env.m_engine.GetBoxShake().back(), 150, ());
  // The box tells it: the calibration is sent once.
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
  TEST(env.m_engine.GetStatus().m_boxStill, ());
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST_EQUAL(env.m_engine.GetBoxShake().back(), 40, ());
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
  // The box has calibrated: the core is not armed any more.
  box.Reply("OK");
  box.Wait(500, true, 40);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_calibration, CalibrationState::Done, ());
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
}

UNIT_TEST(NoGps_Engine_CalibrationWhenStillStartsAgainAfterMoving)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env);
  env.m_engine.CalibrateWhenStill();
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
  // Someone gets into the car.
  box.Reply("ERR,MOVING");
  box.Wait(1000, false, 200);
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_calibration, CalibrationState::FailedMoving, ());
  TEST_EQUAL(box.Calibrations(), 1, ());
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 2, ());
  box.Reply("OK");
  box.Wait(500, true, 40);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
}

UNIT_TEST(NoGps_Engine_CalibrationWhenStillGivesUpAfterRepeatedFailures)
{
  // A box that cannot calibrate on a still car (bad mounting) is reported as moving each time.
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env);
  env.m_engine.CalibrateWhenStill();
  for (int i = 0; i < Engine::kCalibrateWhenStillMaxFailures; ++i)
  {
    TEST(env.m_engine.GetStatus().m_calibrationArmed, (i));
    box.Wait(1000, true, 40);
    TEST_EQUAL(box.Calibrations(), static_cast<size_t>(i + 1), ());
    box.Reply("ERR,MOVING");
    box.Wait(1000, false, 200);
  }
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
}

UNIT_TEST(NoGps_Engine_CalibrationWhenStillIsCancelled)
{
  {
    // The car does not stand for 2 min.
    Env env(true /* inertial */);
    CalibrateWhenStillBox box(env);
    // A car that stood for a minute is calibrated by the core.
    env.m_engine.DeclineAutoCalibration();
    env.m_engine.CalibrateWhenStill();
    box.Wait(Engine::kCalibrateWhenStillTimeoutMs - 2000, false, 150);
    TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
    box.Wait(3000, false, 150);
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
    box.Wait(2000, true, 40);
    TEST_EQUAL(box.Calibrations(), 0, ());
  }
  {
    // The link is lost.
    Env env(true /* inertial */);
    CalibrateWhenStillBox box(env);
    env.m_engine.CalibrateWhenStill();
    box.Wait(1000, false, 150);
    env.m_engine.OnEsp32BleState(BleState::Searching);
    env.m_clock.Advance(500);
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  }
  {
    // The link is lost while the box calibrates.
    Env env(true /* inertial */);
    CalibrateWhenStillBox box(env);
    env.m_engine.CalibrateWhenStill();
    box.Wait(1000, true, 40);
    TEST_EQUAL(box.Calibrations(), 1, ());
    env.m_engine.OnEsp32BleState(BleState::Searching);
    env.m_clock.Advance(500);
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  }
  {
    // The user cancels.
    Env env(true /* inertial */);
    CalibrateWhenStillBox box(env);
    env.m_engine.CalibrateWhenStill();
    env.m_engine.CancelCalibrateWhenStill();
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
    box.Wait(2000, true, 40);
    TEST_EQUAL(box.Calibrations(), 0, ());
  }
  {
    // A box without the connection can't calibrate.
    Env env(true /* inertial */);
    env.m_engine.OnEsp32BleState(BleState::Searching);
    env.m_engine.CalibrateWhenStill();
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  }
}

UNIT_TEST(NoGps_Engine_CalibratesBoxByItselfAtLongStop)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env, false /* calibrated */);
  TEST(env.m_engine.GetStatus().m_boxNeedsCalibration, ());
  // The stop has lasted 1 s so far.
  box.Wait(Engine::kAutoCalibrateStopMs - 3000, false, 150);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  box.Wait(3000, false, 150);
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
  box.Reply("OK");
  box.SetCalibrated();
  box.Wait(500, true, 40);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST(!env.m_engine.GetStatus().m_boxNeedsCalibration, ());
  // Calibrated: nothing starts again.
  box.Wait(2 * Engine::kAutoCalibrateStopMs, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
}

UNIT_TEST(NoGps_Engine_AutoCalibrationEndsWhenCarMoves)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env, false /* calibrated */);
  box.Wait(Engine::kAutoCalibrateStopMs, false, 150);
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
  // The car goes before the box tells it is still.
  box.Drive(2000, 36, 150);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST_EQUAL(box.Calibrations(), 0, ());
  // The next stop is the next calibration.
  box.Wait(Engine::kAutoCalibrateStopMs - 1000, false, 150);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  box.Wait(2000, false, 150);
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
}

UNIT_TEST(NoGps_Engine_AutoCalibrationStartsAgainAfterFailedMoving)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env, false /* calibrated */);
  box.Wait(Engine::kAutoCalibrateStopMs, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
  box.Reply("ERR,MOVING");
  box.Drive(2000, 36, 200);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST(env.m_engine.GetStatus().m_boxNeedsCalibration, ());
  box.Wait(Engine::kAutoCalibrateStopMs + 2000, true, 40);
  TEST_EQUAL(box.Calibrations(), 2, ());
}

UNIT_TEST(NoGps_Engine_AutoCalibrationStopsWhenUserDeclines)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env, false /* calibrated */);
  box.Wait(Engine::kAutoCalibrateStopMs, false, 150);
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
  env.m_engine.DeclineAutoCalibration();
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  box.Wait(2 * Engine::kAutoCalibrateStopMs, true, 40);
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  TEST_EQUAL(box.Calibrations(), 0, ());
  // The page still calibrates when the user asks.
  env.m_engine.CalibrateWhenStill();
  box.Wait(1000, true, 40);
  TEST_EQUAL(box.Calibrations(), 1, ());
  // The box connects again: the core calibrates by itself again.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  box.Wait(1000, false, 150);
  env.ConnectBox();
  box.Wait(Engine::kAutoCalibrateStopMs + 2000, false, 150);
  TEST(env.m_engine.GetStatus().m_calibrationArmed, ());
}

UNIT_TEST(NoGps_Engine_AutoCalibrationIsNotForReadOnlyOrDisconnectedBox)
{
  {
    Env env(true /* inertial */);
    CalibrateWhenStillBox box(env, false /* calibrated */);
    env.m_engine.OnEsp32BleState(BleState::Searching);
    TEST(!env.m_engine.GetStatus().m_boxNeedsCalibration, ());
    box.Wait(2 * Engine::kAutoCalibrateStopMs, true, 40);
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
    TEST_EQUAL(box.Calibrations(), 0, ());
  }
  {
    Env env(true /* inertial */);
    CalibrateWhenStillBox box(env, false /* calibrated */);
    env.m_engine.OnEsp32BleBytes(
        BoxLine("NGI,1,0.4.1,2026-11-15T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA PHONES"));
    auto const & sent = env.m_delegate.m_esp32BleSent;
    auto const list = std::find_if(sent.begin(), sent.end(),
                                   [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
    TEST(list != sent.end(), ());
    env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*esp32::Parse(*list))[1] + ",OK,BC:D0:74:A9:71:92|Pixel 8|1|0,0"));
    TEST(!env.m_engine.GetStatus().m_boxNeedsCalibration, ());
    box.Wait(2 * Engine::kAutoCalibrateStopMs, true, 40);
    TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
    TEST_EQUAL(box.Calibrations(), 0, ());
  }
}

UNIT_TEST(NoGps_Engine_CalibrationWhenStillIsNotForReadOnlyBox)
{
  Env env(true /* inertial */);
  CalibrateWhenStillBox box(env);
  // The box knows its phones, another phone changes it: the list says so.
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.4.1,2026-11-15T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA PHONES"));
  auto const & sent = env.m_delegate.m_esp32BleSent;
  auto const list = std::find_if(sent.begin(), sent.end(),
                                 [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
  TEST(list != sent.end(), ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*esp32::Parse(*list))[1] + ",OK,BC:D0:74:A9:71:92|Pixel 8|1|0,0"));
  TEST(env.m_engine.GetStatus().m_boxReadOnly, ());
  env.m_engine.CalibrateWhenStill();
  TEST(!env.m_engine.GetStatus().m_calibrationArmed, ());
  box.Wait(2000, true, 40);
  TEST_EQUAL(box.Calibrations(), 0, ());
}

UNIT_TEST(NoGps_Engine_AdvisesToCalibrateBoxByItsPowerOns)
{
  Env env(true /* inertial */);
  auto const count = [&env]
  { return std::count(env.m_delegate.m_events.begin(), env.m_delegate.m_events.end(), Event::BoxCalibrationAdvised); };
  // The box tells how many times it was powered on.
  auto const info = [&env](std::string const & id, int powerOns)
  {
    env.m_engine.OnEsp32BleBytes(BoxLine("NGI,1,0.3.5,2026-10-10T11:00,esp32s3,s3zero," + id +
                                         ",4096,2031616,ota_0,VALID,WIFI BLE OTA," + std::to_string(powerOns)));
    env.Drive(2000, 0, 0);
  };

  // The box has got the counting firmware in its place in the car: it has not moved.
  info("C47D", 0);
  TEST_EQUAL(count(), 0, ());
  TEST(!env.m_engine.GetStatus().m_boxCalibrationAdvised, ());

  // It was taken out and plugged in. Its journal tells the same, the user is asked once.
  env.RestartBox();
  env.Drive(1000, 0, 0);
  env.m_engine.OnEsp32BleBytes(BoxLine("NGE,1,1,40,I,BOOT,fw 0.3.5 reset POWERON"));
  info("C47D", 1);
  TEST_EQUAL(count(), 1, ());
  TEST(env.m_engine.GetStatus().m_boxCalibrationAdvised, ());
  // The same power-on after a new connection.
  info("C47D", 1);
  TEST_EQUAL(count(), 1, ());

  // Another box, new for this phone: it is to be calibrated in its car.
  info("42FD", 7);
  TEST_EQUAL(count(), 2, ());
  // The first one is remembered.
  info("C47D", 1);
  info("42FD", 7);
  TEST_EQUAL(count(), 2, ());
  // Each by its car.
  TEST_EQUAL(env.m_storage.Get<std::string>(CarStorage::GetCarKey("C47D", Storage::kBoxPowerOns), ""), "C47D:1", ());
  TEST_EQUAL(env.m_storage.Get<std::string>(CarStorage::GetCarKey("42FD", Storage::kBoxPowerOns), ""), "42FD:7", ());

  // Plugged in again while the car drives: the user is told when it stops.
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.3.5,2026-10-10T11:00,esp32s3,s3zero,42FD,4096,2031616,ota_0,VALID,WIFI BLE OTA,8"));
  env.Drive(3000, 36, 0);
  TEST_EQUAL(count(), 2, ());
  env.Drive(2000, 0, 0);
  TEST_EQUAL(count(), 3, ());

  // The memory of the box was erased with its calibration: it counts from the start.
  info("42FD", 0);
  TEST_EQUAL(count(), 4, ());
}

// The box tells about itself, its id is the car.
void HearBox(Env & env, std::string const & id)
{
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.3.5,2026-10-10T11:00,esp32s3,s3zero," + id + ",4096,2031616,ota_0,VALID,WIFI BLE OTA"));
  env.Drive(1000, 0, 0);
}

std::vector<std::string> CarIds(std::vector<Car> const & cars)
{
  std::vector<std::string> ids;
  for (auto const & car : cars)
    ids.push_back(car.m_id);
  return ids;
}

/// The line without its " ms=<unix ms>": the tests compare the values, the time has its own tests.
std::string WithoutTime(std::string line)
{
  auto const from = line.find(" ms=");
  TEST_NOT_EQUAL(from, std::string::npos, (line));
  auto const to = line.find(' ', from + 1);
  line.erase(from, to == std::string::npos ? std::string::npos : to - from);
  return line;
}

/// Keeps the CALIBRATION lines of the trip log while it lives, the other messages are logged as before.
class CalibrationLines
{
public:
  CalibrationLines()
  {
    s_lines.clear();
    s_saved = base::SetLogMessageFn(&Keep);
  }
  ~CalibrationLines() { base::SetLogMessageFn(s_saved); }

  static size_t Count() { return s_lines.size(); }
  /// \returns the lines written since the last call.
  std::vector<std::string> Take() { return std::exchange(s_lines, {}); }

private:
  static void Keep(base::LogLevel level, base::SrcPoint const & src, std::string const & message)
  {
    if (message.starts_with("CALIBRATION "))
      s_lines.push_back(WithoutTime(message));
    else
      s_saved(level, src, message);
  }

  static inline std::vector<std::string> s_lines;
  static inline base::LogMessageFn s_saved = nullptr;
};

/// The values of a CALIBRATION line by their names.
std::map<std::string, std::string> CalibrationValues(std::string const & line)
{
  std::map<std::string, std::string> values;
  auto const words = strings::Tokenize(line, " ");
  TEST_EQUAL(words[0], "CALIBRATION", ());
  for (size_t i = 1; i < words.size(); ++i)
  {
    auto const eq = words[i].find('=');
    TEST_NOT_EQUAL(eq, std::string_view::npos, (line));
    TEST(values.emplace(words[i].substr(0, eq), words[i].substr(eq + 1)).second, (line));
  }
  return values;
}

int TripsStarted(Env const & env)
{
  auto const & events = env.m_delegate.m_events;
  return static_cast<int>(std::count(events.begin(), events.end(), Event::TripStarted));
}

UNIT_TEST(NoGps_TripStarted_BoxConnectedSoonAfterStartStaysInFileOfLaunch)
{
  Env env(true /* inertial */);
  env.Drive(2000, 0, 0);
  TEST_EQUAL(TripsStarted(env), 0, ());
  // The link is made again and again within the gap.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.m_clock.Advance(Engine::kTripFileLinkGapMs - 1000);
  env.ConnectBox();
  env.ConnectBox();
  TEST_EQUAL(TripsStarted(env), 0, ());
}

UNIT_TEST(NoGps_TripStarted_FirstConnectionLongAfterStart)
{
  NewUser user;
  user.m_storage.Set(Storage::kInertialEnabled, true);
  user.Start();
  user.m_clock.Advance(Engine::kTripFileLinkGapMs);
  // The box is found and asks for its code: not connected yet.
  user.m_engine.OnEsp32BleState(BleState::Searching);
  user.m_engine.OnEsp32BleState(BleState::Connecting);
  user.m_engine.OnEsp32BleState(BleState::Pairing);
  TEST(!user.m_delegate.HasEvent(Event::TripStarted), ());
  user.m_engine.OnEsp32BleState(BleState::Connected);
  TEST(user.m_delegate.HasEvent(Event::TripStarted), ());
}

UNIT_TEST(NoGps_TripStarted_LostPairingProbeIsNoLink)
{
  NewUser user;
  user.m_storage.Set(Storage::kInertialEnabled, true);
  user.Start();
  user.m_clock.Advance(Engine::kTripFileLinkGapMs);
  // The search for a box with a lost pairing connects to it: the UI keeps the hint, no trip starts.
  user.m_engine.OnEsp32BleState(BleState::Connected, true /* bondLost */);
  TEST(!user.m_delegate.HasEvent(Event::TripStarted), ());
  TEST_EQUAL(user.m_engine.GetStatus().m_bleState, BleState::BondLost, ());
  // The box is heard: the same connection is a link now.
  user.m_engine.OnEsp32BleState(BleState::Connected, false /* bondLost */);
  TEST(user.m_delegate.HasEvent(Event::TripStarted), ());
  TEST_EQUAL(user.m_engine.GetStatus().m_bleState, BleState::Connected, ());
}

UNIT_TEST(NoGps_TripStarted_LinkLostForLong)
{
  Env env(true /* inertial */);
  env.Drive(2000, 36, 0);
  // A dropout on the way.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.m_clock.Advance(5000);
  env.m_engine.OnEsp32BleState(BleState::Connecting);
  env.ConnectBox();
  TEST_EQUAL(TripsStarted(env), 0, ());

  // The gap is counted from the end of the link, not from the last try to make it.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.m_clock.Advance(Engine::kTripFileLinkGapMs - 1000);
  env.m_engine.OnEsp32BleState(BleState::Connecting);
  env.m_clock.Advance(1000);
  env.ConnectBox();
  TEST_EQUAL(TripsStarted(env), 1, ());
  env.Drive(2000, 36, 0);
  TEST_EQUAL(TripsStarted(env), 1, ());
}

UNIT_TEST(NoGps_TripStarted_BoxStoppedForLong)
{
  // The platform closes the link when the navigation stops and doesn't tell of it.
  Env env(true /* inertial */);
  env.m_engine.Stop();
  env.m_clock.Advance(Engine::kTripFileLinkGapMs);
  env.m_engine.Start();
  TEST_EQUAL(TripsStarted(env), 0, ());
  env.ConnectBox();
  TEST_EQUAL(TripsStarted(env), 1, ());

  // The box is started again for another car: no pause.
  HearBox(env, "C47D");
  HearBox(env, "42FD");
  env.m_engine.SelectCar("C47D");
  env.ConnectBox();
  TEST_EQUAL(TripsStarted(env), 1, ());
}

UNIT_TEST(NoGps_TripStarted_IsFollowedByCalibrationLine)
{
  // The platform starts the new file in the event: the line is written after it, into that file.
  struct FileDelegate : TestDelegate
  {
    void OnEvent(Event event) override
    {
      if (event == Event::TripStarted)
        m_linesBefore = CalibrationLines::Count();
    }
    std::optional<size_t> m_linesBefore;
  };
  TestClock clock;
  TestStorage storage;
  FileDelegate delegate;
  TestMap map;
  storage.Set(Storage::kInertialEnabled, true);
  Engine engine(delegate, map, storage, clock, clock);
  CalibrationLines lines;
  // The file of the launch has the line too.
  engine.Start();
  TEST_EQUAL(lines.Take(), std::vector<std::string>({"CALIBRATION car=-"}), ());

  clock.Advance(Engine::kTripFileLinkGapMs);
  engine.OnEsp32BleState(BleState::Connected);
  TEST(delegate.m_linesBefore, ());
  TEST_EQUAL(*delegate.m_linesBefore, 0, ());
  TEST_EQUAL(lines.Take(), std::vector<std::string>({"CALIBRATION car=-"}), ());
}

UNIT_TEST(NoGps_CalibrationLine_ValuesAreReadBack)
{
  SpeedTable table;
  for (int i = 0; i < 400; ++i)
    table.OnSample(50, 50 / 3.6 * 1.04, 1.0, 0);
  SpeedTable rough(false /* learnsOffset */);
  rough.OnDistance(36, 1000, 1050);
  SpeedFactor factor;
  factor.OnDistance(2000, 2040);
  // In the form the storage keeps them.
  std::string lagText = "500";
  for (int i = 0; i < SpeedLag::kSteps; ++i)
    lagText += ";" + std::to_string(10 + std::abs(i - 3)) + ".5";
  SpeedLag lag;
  lag.Deserialize(lagText);
  TEST_EQUAL(lag.Serialize(), lagText, ());
  // As many values as AccelSpeed keeps.
  std::string accelText = "40";
  for (int i = 1; i < 21; ++i)
    accelText += ";" + std::to_string(i) + ".25";
  AccelSpeed accel;
  TEST(accel.Deserialize(accelText), ());
  TEST_EQUAL(accel.Serialize(), accelText, ());

  CalibrationLines lines;
  Env env(true /* inertial */, nullptr, [&](TestStorage & storage)
  {
    storage.Set(Storage::kCars, std::string("C47D"));
    storage.Set(Storage::kCurrentCar, std::string("C47D"));
    auto const set = [&storage](std::string_view key, std::string const & value)
    { storage.Set(CarStorage::GetCarKey("C47D", key), value); };
    set(Storage::kSpeedTable, table.Serialize());
    set(Storage::kRoughSpeedTable, rough.Serialize());
    set(Storage::kSpeedFactor, factor.Serialize());
    set(Storage::kSpeedLag, lagText);
    set(Storage::kSpeedScale, "1.04");
    set(Storage::kBoxAccel, "C47D:" + accelText);
    set(Storage::kCarPosition, "50.45,30.52,90,0,1700000000000");
    set(CarStorage::kCarName, "Kia");
  });
  auto const written = lines.Take();
  TEST_EQUAL(written.size(), 1, ());
  auto values = CalibrationValues(written[0]);
  // Where the car is and how it is named is not in the line.
  TEST_EQUAL(values.size(), 7, (written[0]));
  TEST_EQUAL(written[0].find("50.45"), std::string::npos, ());
  TEST_EQUAL(written[0].find("Kia"), std::string::npos, ());
  TEST_EQUAL(values["car"], "C47D", ());
  TEST_EQUAL(values["scale"], "1.04", ());

  // Read back, each value is what the storage keeps.
  SpeedTable readTable;
  readTable.Deserialize(values["table"]);
  TEST_EQUAL(readTable.Serialize(), table.Serialize(), ());
  TEST_EQUAL(readTable.GetKnownRanges(), 1, ());
  SpeedTable readRough(false /* learnsOffset */);
  readRough.Deserialize(values["rough"]);
  TEST_EQUAL(readRough.Serialize(), rough.Serialize(), ());
  SpeedFactor readFactor;
  readFactor.Deserialize(values["factor"]);
  TEST_EQUAL(readFactor.Get(), factor.Get(), ());
  SpeedLag readLag;
  readLag.Deserialize(values["lag"]);
  TEST(readLag.IsMeasured(), ());
  TEST_EQUAL(readLag.Get(), lag.Get(), ());
  TEST_EQUAL(values["accel"], "C47D:" + accelText, ());
  AccelSpeed readAccel;
  TEST(readAccel.Deserialize(values["accel"].substr(5)), ());
  TEST_EQUAL(readAccel.GetSamples(), 40, ());
}

UNIT_TEST(NoGps_CalibrationLine_NewCarAndReset)
{
  Env env(true /* inertial */);
  CalibrationLines lines;
  // A new car has learned nothing.
  HearBox(env, "C47D");
  TEST_EQUAL(lines.Take(), std::vector<std::string>({"CALIBRATION car=C47D"}), ());

  env.m_engine.SetManualMode(true);
  TEST(lines.Take().empty(), ());
  // Learning writes no line: the values of the start of a trip are in the line before it.
  env.m_engine.OnFix(GpsAt(env.m_clock, 0, 0, 90.0, 10.0));
  for (int i = 0; i < 200; ++i)
  {
    env.Drive(1000, 36, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 10.4 * (i + 1), 0, 90.0, 10.4));
  }
  TEST_EQUAL(env.m_engine.GetStatus().m_speedTableRanges, 1, ());
  TEST(lines.Take().empty(), ());

  // The calibration is reset by the user: the line tells what is left.
  env.m_engine.ClearSpeedCalibration();
  auto const written = lines.Take();
  TEST_EQUAL(written.size(), 1, ());
  auto const values = CalibrationValues(written[0]);
  TEST_EQUAL(values.at("car"), "C47D", ());
  TEST(!values.contains("table") && !values.contains("factor") && !values.contains("scale"), (written[0]));
}

UNIT_TEST(NoGps_Cars_LegacyValuesGoToCarOfLearnedAccelerometer)
{
  TestStorage storage;
  // A user from before the cars with the navigation on by default.
  storage.Set(Storage::kBoxAccel, std::string("C47D:1;2;3"));
  storage.Set(Storage::kSpeedTable, std::string("table"));
  storage.Set(Storage::kCarPosition, std::string("place"));
  storage.Set(Storage::kWrongNetworkPoints, std::string("points"));
  CarStorage cars(storage);
  TEST(cars.GetCars().empty(), ());
  TEST_EQUAL(cars.GetCurrentCar(), "", ());
  // Before a box is heard, the values are where they were.
  TEST_EQUAL(cars.Get<std::string>(Storage::kSpeedTable, ""), "table", ());

  // Another box is heard first: it is a new car, the values are of the box the accelerometer was learned with.
  cars.OnBoxHeard("42FD", "0.3.5", 1000);
  TEST_EQUAL(CarIds(cars.GetCars()), std::vector<std::string>({"C47D", "42FD"}), ());
  TEST_EQUAL(cars.GetCurrentCar(), "42FD", ());
  TEST(!cars.GetString(Storage::kSpeedTable), ());
  TEST(!cars.GetString(Storage::kCarPosition), ());
  TEST(storage.Get<bool>(Storage::kInertialEnabled, false), ());
  TEST(!storage.GetString(Storage::kSpeedTable), ());
  TEST_EQUAL(storage.Get<std::string>(Storage::kWrongNetworkPoints, ""), "points", ());
  TEST_EQUAL(cars.GetCars()[1].m_firmware, "0.3.5", ());
  TEST_EQUAL(cars.GetCars()[1].m_lastSeenUnixMs, 1000, ());

  TEST(cars.SelectCar("C47D"), ());
  TEST_EQUAL(cars.Get<std::string>(Storage::kSpeedTable, ""), "table", ());
  TEST_EQUAL(cars.Get<std::string>(Storage::kCarPosition, ""), "place", ());
  TEST_EQUAL(cars.Get<std::string>(Storage::kBoxAccel, ""), "C47D:1;2;3", ());
  TEST(!cars.SelectCar("0000"), ());
  TEST_EQUAL(cars.GetCurrentCar(), "C47D", ());

  // Without the accelerometer learned, the values go to the first box heard.
  TestStorage other;
  other.Set(Storage::kSpeedLag, std::string("lag"));
  CarStorage otherCars(other);
  otherCars.OnBoxHeard("42FD", "0.3.5", 1000);
  TEST_EQUAL(CarIds(otherCars.GetCars()), std::vector<std::string>({"42FD"}), ());
  TEST_EQUAL(otherCars.Get<std::string>(Storage::kSpeedLag, ""), "lag", ());
}

UNIT_TEST(NoGps_Cars_AuthKeyBelongsToTheCar)
{
  TestStorage storage;
  CarStorage cars(storage);
  cars.OnBoxHeard("C47D", "0.5.0", 1000);
  cars.OnBoxHeard("42FD", "0.5.0", 2000);
  std::string const key = "000102030405060708090a0b0c0d0e0f";
  cars.SetCarValue("C47D", CarStorage::kCarAuthKey, key);
  TEST_EQUAL(cars.GetCarValue("C47D", CarStorage::kCarAuthKey), key, ());
  TEST(!cars.GetCarValue("42FD", CarStorage::kCarAuthKey), ());
  // The key is not one of the values the car keeps on the box or moves to the first car.
  TEST(!cars.GetString(CarStorage::kCarAuthKey), ());
  for (auto const value : CarStorage::kValuesOnBox)
    TEST_NOT_EQUAL(value, CarStorage::kCarAuthKey, ());
  // The box of a forgotten car may still keep the key: it stays, unconfirmed, so that box is taken when the car is
  // added again.
  cars.ForgetCar("C47D");
  TEST_EQUAL(cars.GetCarValue("C47D", CarStorage::kCarAuthKey).value_or(""), CarStorage::kAuthKeyUnconfirmed + key, ());
  cars.ForgetCar("42FD");
  TEST(!cars.GetCarValue("42FD", CarStorage::kCarAuthKey), ());
}

UNIT_TEST(NoGps_Cars_ForgetRemovesOnlyThatCar)
{
  TestStorage storage;
  storage.Set(Storage::kInertialEnabled, true);
  CarStorage cars(storage);
  cars.OnBoxHeard("C47D", "0.3.5", 1000);
  cars.Set(Storage::kSpeedTable, std::string("first"));
  cars.OnBoxHeard("42FD", "0.3.5", 3000);
  cars.Set(Storage::kSpeedTable, std::string("second"));
  cars.OnBoxHeard("1234", "0.3.5", 2000);
  cars.Set(Storage::kSpeedTable, std::string("third"));
  // An identifier that is not of a box is not a car.
  cars.OnBoxHeard("C4.7D", "0.3.5", 4000);
  TEST_EQUAL(CarIds(cars.GetCars()), std::vector<std::string>({"C47D", "42FD", "1234"}), ());

  cars.RenameCar("C47D", " My\ncar ");
  TEST_EQUAL(cars.GetCars()[0].m_name, "My car", ());
  // An empty name keeps the previous one.
  cars.RenameCar("C47D", "");
  TEST_EQUAL(cars.GetCars()[0].m_name, "My car", ());
  cars.RenameCar("C47D", " \n ");
  TEST_EQUAL(cars.GetCars()[0].m_name, "My car", ());
  cars.RenameCar("C47D", "Kia");
  cars.SetCarValue("C47D", CarStorage::kCarRecoveryCode, "123456");

  // The current car is forgotten: the one heard the last time is the current one.
  cars.ForgetCar("1234");
  TEST_EQUAL(CarIds(cars.GetCars()), std::vector<std::string>({"C47D", "42FD"}), ());
  TEST_EQUAL(cars.GetCurrentCar(), "42FD", ());
  TEST_EQUAL(cars.Get<std::string>(Storage::kSpeedTable, ""), "second", ());
  TEST(!storage.GetString(CarStorage::GetCarKey("1234", Storage::kSpeedTable)), ());
  TEST(!storage.GetString(CarStorage::GetCarKey("1234", "NoGpsFirmware")), ());

  // Another car: the current one stays.
  cars.ForgetCar("C47D");
  TEST_EQUAL(CarIds(cars.GetCars()), std::vector<std::string>({"42FD"}), ());
  TEST_EQUAL(cars.GetCurrentCar(), "42FD", ());
  TEST(!storage.GetString(CarStorage::GetCarKey("C47D", "NoGpsName")), ());
  TEST(!storage.GetString(CarStorage::GetCarKey("C47D", CarStorage::kCarRecoveryCode)), ());

  // The last car: the values have no car, and a box heard again is a new car.
  cars.ForgetCar("42FD");
  TEST(cars.GetCars().empty(), ());
  TEST_EQUAL(cars.GetCurrentCar(), "", ());
  TEST(!cars.GetString(Storage::kSpeedTable), ());
  cars.OnBoxHeard("C47D", "0.3.5", 5000);
  TEST(!cars.GetString(Storage::kSpeedTable), ());
}

UNIT_TEST(NoGps_MaxCars)
{
  TestStorage storage;
  storage.Set(Storage::kInertialEnabled, true);
  CarStorage cars(storage);
  for (auto const id : {"C47D", "42FD", "1234", "ABCD"})
    cars.OnBoxHeard(id, "0.3.5", 1000);
  TEST_EQUAL(cars.GetCars().size(), CarStorage::kMaxCars, ());

  // The 5th box is not a car: the current car stays.
  cars.OnBoxHeard("5678", "0.3.5", 2000);
  TEST_EQUAL(CarIds(cars.GetCars()), std::vector<std::string>({"C47D", "42FD", "1234", "ABCD"}), ());
  TEST_EQUAL(cars.GetCurrentCar(), "ABCD", ());
  // A box of a car is still heard.
  cars.OnBoxHeard("C47D", "0.3.6", 3000);
  TEST_EQUAL(cars.GetCurrentCar(), "C47D", ());
  TEST_EQUAL(cars.GetCars()[0].m_firmware, "0.3.6", ());

  // Cars over the limit, kept from before it, stay.
  storage.Set(Storage::kCars, std::string("C47D,42FD,1234,ABCD,5678"));
  TEST_EQUAL(cars.GetCars().size(), 5, ());
  cars.OnBoxHeard("5678", "0.3.5", 4000);
  TEST_EQUAL(cars.GetCurrentCar(), "5678", ());
  cars.OnBoxHeard("9ABC", "0.3.5", 5000);
  TEST_EQUAL(cars.GetCars().size(), 5, ());
  cars.ForgetCar("5678");
  TEST_EQUAL(cars.GetCars().size(), CarStorage::kMaxCars, ());
}

UNIT_TEST(NoGps_Engine_KeepsCalibrationForEachCar)
{
  // The roads have told the speedometer is 5% low at 30-40 km/h, before the cars.
  SpeedTable rough;
  rough.OnDistance(36, 1000, 1050);
  Env env(true /* inertial */, nullptr,
          [&rough](TestStorage & storage) { storage.Set(Storage::kRoughSpeedTable, rough.Serialize()); });
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "", ());
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());

  // The first box heard takes them.
  HearBox(env, "C47D");
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "C47D", ());
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());
  TEST(!env.m_storage.GetString(Storage::kRoughSpeedTable), ());

  // A new box is another car: it learns from zero.
  HearBox(env, "42FD");
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "42FD", ());
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 0, ());
  TEST_EQUAL(CarIds(env.m_engine.GetCars()), std::vector<std::string>({"C47D", "42FD"}), ());
  // Cleared in this car only.
  env.m_engine.ClearSpeedCalibration();
  HearBox(env, "C47D");
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());

  // The user chooses the other car: its values at once, the platform looks for its box.
  env.m_engine.SelectCar("42FD");
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "42FD", ());
  TEST_EQUAL(env.m_engine.GetStatus().m_roughSpeedTableRanges, 0, ());
  TEST(env.m_delegate.m_esp32BleOpen, ());

  // After a restart the car heard the last time is the current one until a box tells.
  HearBox(env, "C47D");
  Env after(true /* inertial */, nullptr, SavedBy(env));
  TEST_EQUAL(after.m_engine.GetStatus().m_carId, "C47D", ());
  TEST_EQUAL(after.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());

  // Forgotten, the car is gone with its values. Without cars the box is not looked for.
  after.m_engine.ForgetCar("C47D");
  TEST_EQUAL(after.m_engine.GetStatus().m_carId, "42FD", ());
  TEST_EQUAL(after.m_engine.GetStatus().m_roughSpeedTableRanges, 0, ());
  TEST(after.m_engine.GetStatus().m_inertialEnabled, ());
  after.m_engine.ForgetCar("42FD");
  TEST(after.m_engine.GetCars().empty(), ());
  TEST(!after.m_engine.GetStatus().m_inertialEnabled, ());
  TEST(!after.m_delegate.m_esp32BleOpen, ());
}

UNIT_TEST(NoGps_Engine_CarOfBoxIsShownWhereItWasLeft)
{
  Env env(true /* inertial */);
  HearBox(env, "C47D");
  MarkCar(env, 50);
  env.Drive(2000, 0, 0);
  // The user walks to the other car with the phone: the mark set by the user stays.
  HearBox(env, "42FD");
  TestAlmostEqualAbs(East(env.Last().m_position), 50, 0.5);
  TEST(env.m_engine.PlaceMarkByTap(At(150, 3)), ());
  env.Drive(2000, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 150, 0.5);
  env.m_engine.Stop();

  // The app starts in the car left the last time, at its place. The box of the other car connects: it is there.
  Env after(true /* inertial */, nullptr, SavedBy(env));
  after.Drive(500, 0, 0);
  TestAlmostEqualAbs(East(after.Last().m_position), 150, 0.5);
  HearBox(after, "C47D");
  TestAlmostEqualAbs(East(after.Last().m_position), 50, 0.5);
  after.m_engine.SelectCar("42FD");
  after.Drive(500, 0, 0);
  TestAlmostEqualAbs(East(after.Last().m_position), 150, 0.5);

  // The car has driven from its place: it is where it has driven to, whatever box tells.
  HearBox(after, "42FD");
  after.Drive(3000, 36, 0);
  double const drivenTo = East(after.Last().m_position);
  TEST_GREATER(drivenTo, 160, ());
  HearBox(after, "C47D");
  // The speed of the car comes late: it rolls on a bit.
  TestAlmostEqualAbs(East(after.Last().m_position), drivenTo, 3);

  // A new box has no place: the car stays where it is shown.
  Env fresh(true /* inertial */, nullptr, SavedBy(env));
  fresh.Drive(500, 0, 0);
  HearBox(fresh, "1234");
  TestAlmostEqualAbs(East(fresh.Last().m_position), 150, 0.5);
}

UNIT_TEST(NoGps_Engine_ParkedCarsAreOtherCarsWithPlace)
{
  Env env(true /* inertial */);
  int changes = 0;
  env.m_engine.SetParkedCarsListener([&changes] { ++changes; });
  HearBox(env, "C47D");
  MarkCar(env, 50);
  env.Drive(2000, 0, 0);
  // The current car is where the position is.
  TEST(env.m_engine.GetParkedCars().empty(), ());
  // The first car has become the current one.
  TEST_EQUAL(changes, 1, ());
  changes = 0;

  // The user walks to the other car with the phone and marks it.
  HearBox(env, "42FD");
  TEST_EQUAL(changes, 1, ());
  auto parked = env.m_engine.GetParkedCars();
  TEST_EQUAL(parked.size(), 1, ());
  TEST_EQUAL(parked[0].m_id, "C47D", ());
  TestAlmostEqualAbs(East(*parked[0].m_parkedAt), 50, 0.5);
  env.Drive(2000, 0, 0);

  env.m_engine.RenameCar("C47D", "Van");
  TEST_EQUAL(changes, 2, ());
  TEST_EQUAL(env.m_engine.GetParkedCars()[0].m_name, "Van", ());

  // The mark the other car got has stayed where the user marked the first one: the other car is there.
  env.m_engine.SelectCar("C47D");
  TEST_EQUAL(changes, 3, ());
  parked = env.m_engine.GetParkedCars();
  TEST_EQUAL(parked.size(), 1, ());
  TEST_EQUAL(parked[0].m_id, "42FD", ());
  TestAlmostEqualAbs(East(*parked[0].m_parkedAt), 50, 0.5);

  env.m_engine.ForgetCar("42FD");
  TEST_EQUAL(changes, 4, ());
  TEST(env.m_engine.GetParkedCars().empty(), ());
}

UNIT_TEST(NoGps_Engine_PotholeIsWhereTheMarkHitsIt)
{
  Env env(true /* inertial */);
  int changes = 0;
  env.m_engine.SetPotholesListener([&changes] { ++changes; });
  MarkCar(env, 50);
  env.Drive(2000, 36, 0);
  env.Jolt(36, 12);
  double const hitAt = East(env.Last().m_position);
  // The front and the rear axle.
  env.Drive(200, 36, 0);
  env.Jolt(36, 8);
  TEST(env.m_engine.GetPotholes().empty(), ());
  env.Drive(1000, 36, 0);
  TEST_EQUAL(changes, 1, ());
  auto const & potholes = env.m_engine.GetPotholes();
  TEST_EQUAL(potholes.size(), 1, ());
  TestAlmostEqualAbs(East(potholes[0].m_place), hitAt, 0.5);
  TEST_EQUAL(potholes[0].m_pct, 31, ());
  TEST_EQUAL(potholes[0].m_hits, 1, ());

  // A standing car feels a door slam.
  env.Drive(3000, 0, 0);
  env.Jolt(0, 12);
  env.Drive(1500, 0, 0);
  TEST_EQUAL(env.m_engine.GetPotholes().size(), 1, ());
}

UNIT_TEST(NoGps_Engine_PotholeTakesTheConvertedSpeed)
{
  // The box of this car tells 7 where the car drives 11 km/h: a hit of a driving car, over PotholeDetector::kMinKmh.
  SpeedUnit mph;
  for (int i = 0; i < 60; ++i)
    mph.OnSample(62, 100 / 3.6, 1, 0);
  TEST_EQUAL(mph.Get(), SpeedUnit::kMph, ());
  Env env(true /* inertial */, nullptr,
          [&mph](TestStorage & storage) { storage.Set(Storage::kSpeedUnit, mph.Serialize()); });
  MarkCar(env, 50);
  env.Drive(2000, 7, 0);
  env.Jolt(7, 12);
  env.Drive(1500, 7, 0);
  TEST_EQUAL(env.m_engine.GetPotholes().size(), 1, ());
}

UNIT_TEST(NoGps_Engine_NoPotholeWhileRoadIsLost)
{
  Env env(true /* inertial */);
  MarkCar(env, 50);
  env.Drive(12'000, 36, -5);
  env.Drive(5000, 36, 0);
  TEST(env.m_engine.GetStatus().m_roadLost, ());
  env.Jolt(36, 12);
  env.Drive(1500, 36, 0);
  TEST(env.m_engine.GetPotholes().empty(), ());
}

UNIT_TEST(NoGps_Engine_CarDrivenIsLeftWhereItIsShown)
{
  Env env(true /* inertial */);
  HearBox(env, "C47D");
  HearBox(env, "42FD");
  env.m_engine.SelectCar("C47D");
  MarkCar(env, 50);
  env.Drive(5000, 36, 0);
  double const shownAt = East(env.Last().m_position);
  TEST_GREATER(shownAt, 80, ());
  // While it drives, its place is saved seldom.
  env.m_engine.SelectCar("42FD");
  auto const parked = env.m_engine.GetParkedCars();
  TEST_EQUAL(parked.size(), 1, ());
  TEST_EQUAL(parked[0].m_id, "C47D", ());
  TestAlmostEqualAbs(East(*parked[0].m_parkedAt), shownAt, 1);
}

/// The box of a firmware that keeps the values of its car: it answers the phone connected to it.
class CarBox
{
public:
  /// The box connects and tells about itself, the phone reads the values of the car.
  void Connect(Env & env, std::string const & id = "C47D")
  {
    env.ConnectBox();
    m_answered = env.m_delegate.m_esp32BleSent.size();
    env.m_engine.OnEsp32BleBytes(
        BoxLine("NGI,1,0.4.1,2026-11-15T10:00,esp32s3,s3zero," + id + ",4096,2031616,ota_0,VALID,BLE OTA CAR,3"));
    Answer(env);
    env.Drive(1000, 0, 0);
    Answer(env);
  }

  /// Answers the commands about the car the phone has sent since the last time.
  void Answer(Env & env)
  {
    auto const & sent = env.m_delegate.m_esp32BleSent;
    // The replies make the phone send more.
    while (m_answered < sent.size())
    {
      auto const fields = esp32::Parse(sent[m_answered++]);
      if (!fields || fields->size() < 4)
        continue;
      std::string reply;
      if ((*fields)[2] == "CAR_GET")
      {
        auto const it = m_values.find((*fields)[3]);
        reply = it == m_values.end() ? "OK" : "OK," + it->second;
      }
      else if ((*fields)[2] == "CAR_SET" && fields->size() == 5)
      {
        reply = m_busy ? "ERR,BUSY" : "OK";
        if (!m_busy)
        {
          m_written.push_back((*fields)[3]);
          if ((*fields)[4].empty())
            m_values.erase((*fields)[3]);
          else
            m_values[(*fields)[3]] = (*fields)[4];
        }
      }
      else
      {
        continue;
      }
      env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*fields)[1] + "," + reply));
    }
  }

  std::map<std::string, std::string> m_values;
  // The keys written, in their order.
  std::vector<std::string> m_written;
  // Another phone keeps the box.
  bool m_busy = false;

private:
  size_t m_answered = 0;
};

UNIT_TEST(NoGps_BoxCarValues_PhonesOfCarShareItsValues)
{
  CarBox box;
  // The roads have told the speedometer is 5% low at 30-40 km/h, before the box kept the values.
  SpeedTable rough;
  rough.OnDistance(36, 1000, 1050);
  Env first(true /* inertial */, nullptr,
            [&rough](TestStorage & storage) { storage.Set(Storage::kRoughSpeedTable, rough.Serialize()); });
  box.Connect(first);
  // The box had nothing: the phone gives it what it has.
  auto const roughOnBox = BoxCarValues::Encode(Storage::kRoughSpeedTable, rough.Serialize());
  TEST_EQUAL(box.m_values["spd_rough_lo"], roughOnBox[0].second, ());
  TEST_EQUAL(box.m_values["spd_rough_hi"], roughOnBox[1].second, ());
  first.m_engine.RenameCar("C47D", "Ауді, моя");
  box.Answer(first);
  TEST_EQUAL(box.m_values["car_name"], BoxCarValues::Encode(CarStorage::kCarName, "Ауді, моя")[0].second, ());
  // Where the car is left goes to the box at once when the navigation stops.
  MarkCar(first, 50);
  TEST(!box.m_values.contains("car_pos"), ());
  first.m_engine.Stop();
  box.Answer(first);
  TEST(box.m_values.contains("car_pos"), ());

  // Another phone in the car takes all of it. It has not shown the car anywhere: the car is where it was left.
  Env second(true /* inertial */);
  size_t const written = box.m_written.size();
  box.Connect(second);
  TEST_EQUAL(box.m_written.size(), written, ());
  TEST_EQUAL(second.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());
  TEST_EQUAL(second.m_engine.GetCars()[0].m_name, "Ауді, моя", ());
  TestAlmostEqualAbs(East(second.Last().m_position), 50, 0.5);

  // The second phone clears the calibration, the first one takes it at its next connection.
  second.m_engine.ClearSpeedCalibration();
  box.Answer(second);
  Env firstAgain(true /* inertial */, nullptr, SavedBy(first));
  TEST_EQUAL(firstAgain.m_engine.GetStatus().m_roughSpeedTableRanges, 1, ());
  box.Connect(firstAgain);
  TEST_EQUAL(firstAgain.m_engine.GetStatus().m_roughSpeedTableRanges, 0, ());
  TEST_EQUAL(firstAgain.m_engine.GetCars()[0].m_name, "Ауді, моя", ());
}

UNIT_TEST(NoGps_BoxCarValues_UnitOfCarSpeedGoesWithTheTables)
{
  // The phone has learned the box of the car tells mph, and the tables with the speed converted from it.
  SpeedUnit unit;
  for (int i = 0; i < 60; ++i)
    unit.OnSample(62, 100 / 3.6, 1, 0);
  TEST_EQUAL(unit.Get(), SpeedUnit::kMph, ());
  SpeedTable table;
  table.OnDistance(100, 400, 400);
  CarBox box;
  Env first(true /* inertial */, nullptr, [&unit, &table](TestStorage & storage)
  {
    storage.Set(Storage::kSpeedUnit, unit.Serialize());
    storage.Set(Storage::kSpeedTable, table.Serialize());
  });
  box.Connect(first);
  TEST_EQUAL(box.m_values["spd_unit"], BoxCarValues::Encode(Storage::kSpeedUnit, unit.Serialize())[0].second, ());

  // Another phone takes the unit with them: the tables are of no use with the raw speed.
  Env second(true /* inertial */);
  box.Connect(second);
  TEST_EQUAL(second.m_engine.GetStatus().m_speedTableRanges, 1, ());
  second.Drive(1000, 62, 0);
  TEST_EQUAL(TripField(second, "speed"), "100", ());
}

UNIT_TEST(NoGps_BoxCarValues_ValueChangedByPhoneIsWritten)
{
  CarBox box;
  Env env(true /* inertial */);
  box.Connect(env);
  env.m_engine.RenameCar("C47D", "Kia");
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_name"], "Kia", ());

  // The box is out of reach while the user renames the car: it gets the name at the next connection.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.m_engine.RenameCar("C47D", "Lada");
  box.Connect(env);
  TEST_EQUAL(box.m_values["car_name"], "Lada", ());

  // The link drops before the box answers: the box has the name, the phone doesn't know it.
  env.m_engine.RenameCar("C47D", "Kia");
  env.m_engine.OnEsp32BleState(BleState::Searching);
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_name"], "Kia", ());
  // Another phone has renamed the car since: its name is newer.
  box.m_values["car_name"] = "Opel";
  box.Connect(env);
  TEST_EQUAL(env.m_engine.GetCars()[0].m_name, "Opel", ());
  TEST_EQUAL(box.m_values["car_name"], "Opel", ());

  // The box has lost its values: the phone gives it its own.
  box.m_values.clear();
  box.Connect(env);
  TEST_EQUAL(box.m_values["car_name"], "Opel", ());

  // Another phone has erased the name, the box keeps the other values: the phone takes the empty name.
  box.m_values["spd_factor"] = "1.05";
  box.Connect(env);
  TEST_EQUAL(box.m_values["spd_factor"], "1.05", ());
  box.m_values.erase("car_name");
  box.Connect(env);
  TEST_EQUAL(env.m_engine.GetCars()[0].m_name, "", ());
  TEST(!box.m_values.contains("car_name"), ());
  // A calibration erased by another phone is taken too, while a half of a table is not an erase.
  env.m_engine.RenameCar("C47D", "Opel");
  box.Answer(env);
  box.m_values.erase("spd_factor");
  box.m_values["spd_table_lo"] = "1";
  box.Connect(env);
  TEST(!box.m_values.contains("spd_factor"), ());
  box.m_values.erase("spd_table_lo");
  // A name the phone has never seen on the box is written.
  env.m_engine.RenameCar("C47D", "Opel");
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_name"], "Opel", ());

  // A name given by the user to the box of another car waits for that box.
  box.Connect(env, "42FD");
  env.m_engine.RenameCar("C47D", "Kia");
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_name"], "Opel", ());
}

// The id and the argument of the last |command| the application has sent, empty if it has sent none.
std::pair<std::string, std::string> LastCommand(Env const & env, std::string const & command)
{
  auto const & sent = env.m_delegate.m_esp32BleSent;
  for (auto it = sent.rbegin(); it != sent.rend(); ++it)
  {
    auto const fields = esp32::Parse(*it);
    if (fields && fields->size() > 3 && (*fields)[2] == command)
      return {(*fields)[1], (*fields)[3]};
  }
  return {};
}

UNIT_TEST(NoGps_Engine_BoxProvesItselfWithTheKeyOfItsCar)
{
  std::string const authInfo =
      "NGI,1,0.5.0,2026-11-23T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR PHONES AUTH,5,R1";
  Env env(true /* inertial */);
  CarStorage cars(env.m_storage);
  // The box of a session of the user has to prove itself; the other tests drive the boxes of the recorded days.
  env.m_delegate.m_boxMustProveItself = true;
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.ConnectBox();
  env.m_engine.OnEsp32BleBytes(BoxLine(authInfo));
  // The first session gives the box a key, kept with its car at once in case the reply is lost.
  auto const [setId, key] = LastCommand(env, "AUTH_SET");
  TEST_EQUAL(key.size(), 32, (key));
  TEST_EQUAL(cars.GetCarValue("C47D", CarStorage::kCarAuthKey).value_or(""), CarStorage::kAuthKeyUnconfirmed + key, ());
  // Nothing of the box is taken until it has answered: its car is not there, its lines do not tell the speed.
  env.Drive(1000, 36, 0);
  TEST(cars.GetCars().empty(), ());
  TEST_EQUAL(env.m_engine.GetStatus().m_speedKmh, -1, ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + setId + ",OK"));
  TEST_EQUAL(cars.GetCurrentCar(), "C47D", ());
  TEST_EQUAL(cars.GetCarValue("C47D", CarStorage::kCarAuthKey).value_or(""), key, ());
  env.Drive(1000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_speedKmh, 36, ());

  // The next session proves the box with the key of that car, not of another one.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.ConnectBox();
  env.m_engine.OnEsp32BleBytes(BoxLine(authInfo));
  auto const [authId, nonce] = LastCommand(env, "AUTH");
  TEST_EQUAL(nonce.size(), 16, (nonce));
  // A proof of another key is not one: the box is refused and its lines are dropped until a new link.
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGA," + authId + ",OK," + esp32::AuthProof("ffeeddccbbaa99887766554433221100", nonce)));
  // The user is told, once: nothing else shows why the box does not work.
  auto const refused = [&env]
  {
    auto const & events = env.m_delegate.m_events;
    return std::count(events.begin(), events.end(), Event::BoxRefused);
  };
  TEST_EQUAL(refused(), 1, ());
  env.Drive(2500, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_speedKmh, -1, ());
  TEST_EQUAL(refused(), 1, ());
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.ConnectBox();
  env.m_engine.OnEsp32BleBytes(BoxLine(authInfo));
  auto const [goodId, goodNonce] = LastCommand(env, "AUTH");
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + goodId + ",OK," + esp32::AuthProof(key, goodNonce)));
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "C47D", ());
  env.Drive(1000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_speedKmh, 36, ());
}

UNIT_TEST(NoGps_Engine_BoxOfAnotherIdThanTheLinkIsRefused)
{
  auto const info = [](std::string const & id)
  {
    return "NGI,1,0.5.0,2026-11-23T10:00,esp32s3,s3zero," + id +
           ",4096,2031616,ota_0,VALID,BLE OTA CAR PHONES AUTH,5,R1";
  };
  Env env(true /* inertial */);
  CarStorage cars(env.m_storage);
  env.m_delegate.m_boxMustProveItself = true;
  // The transport has connected the box named NonGPS-C47D: a device under its address that says it is X1 is no
  // first pairing, no key is given to it and no car is added.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.ConnectBox("C47D");
  env.m_engine.OnEsp32BleBytes(BoxLine(info("X1")));
  TEST(LastCommand(env, "AUTH_SET").first.empty(), ());
  TEST(LastCommand(env, "AUTH").first.empty(), ());
  env.Drive(2500, 36, 0);
  TEST(cars.GetCars().empty(), ());
  TEST_EQUAL(env.m_engine.GetStatus().m_speedKmh, -1, ());

  // The box of the name is a first pairing as before.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.ConnectBox("C47D");
  env.m_engine.OnEsp32BleBytes(BoxLine(info("C47D")));
  auto const [setId, key] = LastCommand(env, "AUTH_SET");
  TEST_EQUAL(key.size(), 32, (key));
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + setId + ",OK"));
  TEST_EQUAL(cars.GetCurrentCar(), "C47D", ());

  // A box that tells no name has no id to compare: the proof of its own key is what is left.
  env.m_engine.OnEsp32BleState(BleState::Searching);
  env.ConnectBox();
  auto const setId2 = LastCommand(env, "AUTH_SET").first;
  env.m_engine.OnEsp32BleBytes(BoxLine(info("42FD")));
  TEST_NOT_EQUAL(LastCommand(env, "AUTH_SET").first, setId2, ());
}

UNIT_TEST(NoGps_Engine_ThisPhoneRemovedFromBox)
{
  Env env(true /* inertial */);
  auto const last = [&env] { return *esp32::Parse(env.m_delegate.m_esp32BleSent.back()); };
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.4.2,2026-11-14T21:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR PHONES MULTI,3"));
  env.Drive(1000, 0, 0);
  // The values of the car are read one by one first, the list is asked at once.
  auto const sent = env.m_delegate.m_esp32BleSent;
  auto const list = std::find_if(sent.begin(), sent.end(),
                                 [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
  TEST(list != sent.end(), ());
  auto const listId = (*esp32::Parse(*list))[1];
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + listId + ",OK,BC:D0:74:A9:71:92|Pixel 8|1794685760|1,1"));
  auto status = env.m_engine.GetStatus();
  TEST(status.m_boxHasPhones && status.m_boxPhones && !status.m_boxReadOnly, ());
  TEST_EQUAL(status.m_boxPhones->size(), 1, ());

  env.m_engine.ForgetBoxPhone("BC:D0:74:A9:71:92");
  auto const forget = last();
  TEST_EQUAL(forget[2], "BT_FORGET", ());
  CarStorage cars(env.m_storage);
  cars.SetCarValue("C47D", CarStorage::kCarAuthKey, "00112233445566778899aabbccddeeff");
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + forget[1] + ",OK"));
  TEST(cars.GetCarValue("C47D", CarStorage::kCarAuthKey).value_or("").empty(), ());
  // The platform forgets the car after the box has been read.
  TEST(!env.m_delegate.HasEvent(Event::ThisPhoneRemoved), ());
  env.m_clock.Advance(1);
  TEST(env.m_delegate.HasEvent(Event::ThisPhoneRemoved), ());
}

UNIT_TEST(NoGps_Engine_KeepsRecoveryCodeOfBox)
{
  Env env(true /* inertial */);
  auto const last = [&env] { return *esp32::Parse(env.m_delegate.m_esp32BleSent.back()); };
  TEST(env.m_engine.GetStatus().m_boxRecoveryCode.empty(), ());
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.4.5,2026-11-20T21:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE "
              "OTA CAR PHONES MULTI RECOVERY,3"));
  env.Drive(1000, 0, 0);
  auto const sent = env.m_delegate.m_esp32BleSent;
  auto const list = std::find_if(sent.begin(), sent.end(),
                                 [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
  TEST(list != sent.end(), ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*esp32::Parse(*list))[1] + ",OK,BC:D0:74:A9:71:92|Pixel 8|1|1,1"));
  env.Drive(1000, 0, 0);
  auto const ask = last();
  TEST_EQUAL(ask[2], "BT_RECOVERY", ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + ask[1] + ",OK,123456"));
  TEST_EQUAL(env.m_engine.GetStatus().m_boxRecoveryCode, "123456", ());
}

UNIT_TEST(NoGps_Engine_RecoveryCodeStaysWithTheBoxThatToldIt)
{
  Env env(true /* inertial */);
  auto const last = [&env] { return *esp32::Parse(env.m_delegate.m_esp32BleSent.back()); };
  // The other car of the user, heard before this box.
  HearBox(env, "42FD");
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.4.5,2026-11-20T21:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE "
              "OTA CAR PHONES MULTI RECOVERY,3"));
  env.Drive(1000, 0, 0);
  auto const sent = env.m_delegate.m_esp32BleSent;
  auto const list = std::find_if(sent.begin(), sent.end(),
                                 [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
  TEST(list != sent.end(), ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*esp32::Parse(*list))[1] + ",OK,BC:D0:74:A9:71:92|Pixel 8|1|1,1"));
  env.Drive(1000, 0, 0);
  auto const ask = last();
  TEST_EQUAL(ask[2], "BT_RECOVERY", ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + ask[1] + ",OK,123456"));
  // The code is of this box only: the other car shows none.
  TEST_EQUAL(env.m_engine.GetStatus().m_boxRecoveryCode, "123456", ());
  env.m_engine.SelectCar("42FD");
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "42FD", ());
  TEST(env.m_engine.GetStatus().m_boxRecoveryCode.empty(), ());
  env.m_engine.SelectCar("C47D");
  TEST_EQUAL(env.m_engine.GetStatus().m_boxRecoveryCode, "123456", ());

  // A box over kMaxCars is no car of ours: its code is kept for nobody, least of all for the car shown.
  HearBox(env, "1234");
  HearBox(env, "5678");
  env.m_engine.SelectCar("C47D");
  TEST_EQUAL(env.m_engine.GetCars().size(), CarStorage::kMaxCars, ());
  env.m_engine.OnEsp32BleBytes(
      BoxLine("NGI,1,0.4.5,2026-11-20T21:35,esp32s3,s3zero,E000,4096,2031616,ota_0,VALID,BLE "
              "OTA CAR PHONES MULTI RECOVERY,3"));
  env.Drive(1000, 0, 0);
  auto const second = env.m_delegate.m_esp32BleSent;
  auto const list2 = std::find_if(second.rbegin(), second.rend(),
                                  [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
  TEST(list2 != second.rend(), ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*esp32::Parse(*list2))[1] + ",OK,BC:D0:74:A9:71:92|Pixel 8|1|1,1"));
  env.Drive(1000, 0, 0);
  auto const ask2 = last();
  TEST_EQUAL(ask2[2], "BT_RECOVERY", ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + ask2[1] + ",OK,654321"));
  TEST_EQUAL(env.m_engine.GetStatus().m_carId, "C47D", ());
  TEST_EQUAL(env.m_engine.GetStatus().m_boxRecoveryCode, "123456", ());
}

UNIT_TEST(NoGps_BoxCarValues_PlaceIsWrittenSeldom)
{
  CarBox box;
  Env env(true /* inertial */);
  // The box gets what the phone has at once, then not more often than in 5 minutes.
  box.Connect(env);
  TEST(!box.m_written.empty(), ());
  MarkCar(env, 50);
  box.Answer(env);
  TEST(!box.m_values.contains("car_pos"), ());
  env.Drive(BoxCarValues::kSaveIntervalMs, 0, 0);
  box.Answer(env);
  auto const marked = box.m_values["car_pos"];
  TEST(!marked.empty(), ());

  TEST(env.m_engine.PlaceMarkByTap(At(150, 3)), ());
  env.Drive(2000, 0, 0);
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_pos"], marked, ());
  env.Drive(BoxCarValues::kSaveIntervalMs, 0, 0);
  box.Answer(env);
  auto const moved = box.m_values["car_pos"];
  TEST_NOT_EQUAL(moved, marked, ());

  // The engine stops: the box sleeps in a minute, the place is written at once.
  TEST(env.m_engine.PlaceMarkByTap(At(250, 3)), ());
  env.Drive(2000, 0, 0);
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_pos"], moved, ());
  env.m_engine.OnEsp32BleBytes(BoxLine("NGS,1,0.4.1,ICM20602,500,SLEEP,,0,331,0,OK,0x12,NONE,0,-386,3,OFF,0,12600,,"));
  env.Drive(1000, 0, 0);
  box.Answer(env);
  TEST_NOT_EQUAL(box.m_values["car_pos"], moved, ());
}

UNIT_TEST(NoGps_BoxCarValues_PhoneConnectedSecondDoesNotWrite)
{
  CarBox box;
  box.m_busy = true;
  Env env(true /* inertial */);
  box.Connect(env);
  env.m_engine.RenameCar("C47D", "Kia");
  box.Answer(env);
  TEST(box.m_values.empty(), ());
  // Not until the next connection.
  auto const countSets = [&env]
  {
    return std::count_if(env.m_delegate.m_esp32BleSent.begin(), env.m_delegate.m_esp32BleSent.end(),
                         [](std::string const & line) { return line.find(",CAR_SET,") != std::string::npos; });
  };
  auto const sets = countSets();
  env.m_engine.RenameCar("C47D", "Lada");
  env.Drive(BoxCarValues::kSaveIntervalMs, 0, 0);
  TEST_EQUAL(countSets(), sets, ());

  // The other phone has gone.
  box.m_busy = false;
  box.Connect(env);
  TEST_EQUAL(box.m_values["car_name"], "Lada", ());
}

UNIT_TEST(NoGps_BoxCarValues_PhoneConnectedSecondTakesNewName)
{
  CarBox box;
  box.m_busy = true;
  Env env(true /* inertial */);
  box.Connect(env);
  // The box refuses the name: another phone keeps it.
  env.m_engine.RenameCar("C47D", "Kia");
  box.Answer(env);
  auto const drive = [&](int64_t ms)
  {
    for (int64_t driven = 0; driven < ms; driven += 1000)
    {
      env.Drive(1000, 0, 0);
      box.Answer(env);
    }
  };
  auto const name = [&env] { return env.m_engine.GetCars()[0].m_name; };

  // The first phone renames the car: the box doesn't tell it, this phone reads the name in a minute.
  box.m_values["car_name"] = "Opel";
  drive(BoxCarValues::kReadNameIntervalMs / 2);
  TEST_EQUAL(name(), "Kia", ());
  drive(BoxCarValues::kReadNameIntervalMs);
  TEST_EQUAL(name(), "Opel", ());

  // The phone that changes the box knows its name.
  box.m_busy = false;
  box.Connect(env);
  auto const countGets = [&env]
  {
    return std::count_if(env.m_delegate.m_esp32BleSent.begin(), env.m_delegate.m_esp32BleSent.end(),
                         [](std::string const & line) { return line.find(",CAR_GET,") != std::string::npos; });
  };
  auto const gets = countGets();
  drive(2 * BoxCarValues::kReadNameIntervalMs);
  TEST_EQUAL(countGets(), gets, ());
}

UNIT_TEST(NoGps_BoxCarValues_BoxOverCarLimitIsNotWritten)
{
  Env env(true /* inertial */);
  for (auto const id : {"42FD", "1234", "ABCD"})
    HearBox(env, id);
  CarBox box;
  box.Connect(env);
  env.m_engine.RenameCar("C47D", "Kia");
  box.Answer(env);
  TEST_EQUAL(box.m_values["car_name"], "Kia", ());

  // The 5th box is not a car: it doesn't get the values of the current one.
  CarBox fifth;
  fifth.Connect(env, "5678");
  TEST_EQUAL(env.m_engine.GetCars().size(), CarStorage::kMaxCars, ());
  env.m_engine.RenameCar("C47D", "Lada");
  fifth.Answer(env);
  env.Drive(BoxCarValues::kSaveIntervalMs, 0, 0);
  fifth.Answer(env);
  TEST(fifth.m_written.empty(), (fifth.m_written));
}

UNIT_TEST(NoGps_BoxCarValues_OldFirmwareIsNotAsked)
{
  Env env(true /* inertial */);
  HearBox(env, "C47D");
  env.m_engine.RenameCar("C47D", "Kia");
  MarkCar(env, 50);
  env.m_engine.Stop();
  for (auto const & line : env.m_delegate.m_esp32BleSent)
    TEST_EQUAL(line.find(",CAR_"), std::string::npos, (line));
}

UNIT_TEST(NoGps_BoxCarValues_PlaceMovesCarShownWhereItWasLeft)
{
  CarBox box;
  Env first(true /* inertial */);
  box.Connect(first);
  MarkCar(first, 150);
  first.m_engine.Stop();
  box.Answer(first);

  // Another phone has driven the car and left it elsewhere since.
  Env second(true /* inertial */);
  box.Connect(second);
  TestAlmostEqualAbs(East(second.Last().m_position), 150, 0.5);
  TEST(second.m_engine.PlaceMarkByTap(At(50, 3)), ());
  second.Drive(500, 0, 0);
  second.m_engine.Stop();
  box.Answer(second);

  // The first phone starts where it has left the car, the box tells where the car is.
  Env after(true /* inertial */, nullptr, SavedBy(first));
  after.Drive(500, 0, 0);
  TestAlmostEqualAbs(East(after.Last().m_position), 150, 0.5);
  box.Connect(after);
  TestAlmostEqualAbs(East(after.Last().m_position), 50, 0.5);

  // The user has marked the car before the box connected: the mark stays, it goes to the box.
  Env marked(true /* inertial */, nullptr, SavedBy(first));
  marked.Drive(500, 0, 0);
  TEST(marked.m_engine.PlaceMarkByTap(At(250, 3)), ());
  marked.Drive(500, 0, 0);
  box.Connect(marked);
  TestAlmostEqualAbs(East(marked.Last().m_position), 250, 0.5);
  marked.m_engine.Stop();
  Env markedAfter(true /* inertial */, nullptr, SavedBy(marked));
  markedAfter.Drive(500, 0, 0);
  TestAlmostEqualAbs(East(markedAfter.Last().m_position), 250, 0.5);
  box.Connect(markedAfter);
  TestAlmostEqualAbs(East(markedAfter.Last().m_position), 250, 0.5);
}

UNIT_TEST(NoGps_Engine_OffersFirmwareOfApplication)
{
  auto const count = [](Env const & env, Event event)
  { return std::count(env.m_delegate.m_events.begin(), env.m_delegate.m_events.end(), event); };
  auto const connect = [](Env & env, std::string const & firmware)
  {
    env.m_engine.OnEsp32BleState(BleState::Connected);
    env.m_engine.OnEsp32BleBytes(
        BoxLine("NGI,1," + firmware + ",2026-10-10T07:33,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,WIFI BLE OTA"));
  };
  int reads = 0;
  std::vector<Firmware> const firmwares = {{"0.3.3", "esp32s3", "s3zero", [&reads]
  {
    ++reads;
    return std::string(1000, 'x');
  }}};

  {
    // The box works with another firmware than the application comes with: the user is asked once.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares(firmwares);
    connect(env, "0.3.2");
    // Not at once: the box tells if the car drives in a moment.
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs - Engine::kTripLogIntervalMs);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 0, ());
    env.m_clock.Advance(Engine::kTripLogIntervalMs * 3);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 1, ());
    auto status = env.m_engine.GetStatus();
    TEST_EQUAL(status.m_boxFirmware, "0.3.2", ());
    TEST_EQUAL(status.m_bundledFirmware, "0.3.3", ());
    TEST_EQUAL(status.m_firmwareUpdate, Esp32Update::State::None, ());
    TEST_EQUAL(reads, 0, ());
    // The offer stays pending until the application shows it: the event may come when it can't.
    TEST(status.m_firmwareOfferPending, ());
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs);
    TEST(env.m_engine.GetStatus().m_firmwareOfferPending, ());
    env.m_engine.FirmwareOfferShown();
    TEST(!env.m_engine.GetStatus().m_firmwareOfferPending, ());
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs);
    TEST(!env.m_engine.GetStatus().m_firmwareOfferPending, ());

    env.m_engine.StartFirmwareUpdate();
    TEST_EQUAL(reads, 1, ());
    status = env.m_engine.GetStatus();
    TEST_EQUAL(status.m_firmwareUpdate, Esp32Update::State::Starting, ());
    TEST_EQUAL(status.m_sourceState, SourceState::Updating, ());
    TEST(status.m_bundledFirmware.empty(), ());
    TEST(env.m_delegate.m_esp32BleSent.back().find(",OTA_BEGIN,1000,") != std::string::npos, ());

    env.m_engine.CancelFirmwareUpdate();
    env.m_clock.Advance(Engine::kTripLogIntervalMs);
    TEST_EQUAL(count(env, Event::FirmwareUpdateFailed), 1, ());
    TEST_EQUAL(env.m_engine.GetStatus().m_firmwareUpdateError, "CANCELED", ());
    // Not asked again about the same firmware.
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 1, ());
  }
  {
    // The same firmware: nothing to ask about, but it can be sent again.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares(firmwares);
    connect(env, "0.3.3");
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 0, ());
    TEST_EQUAL(env.m_engine.GetStatus().m_bundledFirmware, "0.3.3", ());
  }
  {
    // Only a build suffix differs: the numbers tell the firmware, the box is not offered the update again.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares(firmwares);
    connect(env, "0.3.3-dirty");
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 0, ());
  }
  {
    // The car drives: the user is asked before the next trip, when the box is connected again.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares(firmwares);
    connect(env, "0.3.2");
    int64_t seq = 0;
    auto const drive = [&](int64_t ms, int speedKmh)
    {
      for (int64_t t = 0; t < ms; t += 20)
      {
        env.m_clock.Advance(20);
        ++seq;
        env.m_engine.OnEsp32BleBytes(BoxDataLine(seq, 100'000 + seq * 20, 0, speedKmh, kCalibratedFlags));
      }
    };
    drive(1500, 36);
    drive(Engine::kFirmwareOfferDelayMs * 2, 0);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 0, ());
    env.m_engine.OnEsp32BleState(BleState::Searching);
    env.m_clock.Advance(Engine::kTripLogIntervalMs);
    connect(env, "0.3.2");
    drive(Engine::kFirmwareOfferDelayMs + Engine::kTripLogIntervalMs * 2, 0);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 1, ());
    TEST(env.m_engine.GetStatus().m_firmwareOfferPending, ());
    // The offer is not kept for a car that drives: the box refuses the update.
    drive(1500, 36);
    TEST(!env.m_engine.GetStatus().m_firmwareOfferPending, ());
  }
  {
    // The box is gone before the application shows the offer: it is made again when the box is back.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares(firmwares);
    connect(env, "0.3.2");
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST(env.m_engine.GetStatus().m_firmwareOfferPending, ());
    env.m_engine.OnEsp32BleState(BleState::Searching);
    env.m_clock.Advance(Engine::kTripLogIntervalMs);
    TEST(!env.m_engine.GetStatus().m_firmwareOfferPending, ());
    connect(env, "0.3.2");
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST(env.m_engine.GetStatus().m_firmwareOfferPending, ());
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 2, ());
  }
  {
    // A box of another kind is not updated.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares({{"0.3.3", "esp32c3", "c3supermini", [] { return std::string(); }}});
    connect(env, "0.3.2");
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 0, ());
    auto const status = env.m_engine.GetStatus();
    TEST_EQUAL(status.m_boxFirmware, "0.3.2", ());
    TEST(status.m_bundledFirmware.empty(), ());
  }
  {
    // The application and its firmware are a pair: the box with a newer firmware is offered the older one of the
    // application.
    Env env(true /* inertial */);
    env.m_engine.SetFirmwares(firmwares);
    connect(env, "0.4.0");
    env.m_clock.Advance(Engine::kFirmwareOfferDelayMs * 2);
    TEST_EQUAL(count(env, Event::FirmwareUpdateAvailable), 1, ());
    TEST_EQUAL(env.m_engine.GetStatus().m_bundledFirmware, "0.3.3", ());
  }
}

/// Drives along a street going east at 72 km/h, the car looks aside of the street by |asideDeg(t)| degrees.
/// \param roads the roads instead of the grid of streets with a crossing every 100 m.
/// \returns how far the calculated position is ahead of the car along the street in the end, nothing if the car
/// was taken off the street.
template <class Aside>
std::optional<double> DriveAside(Aside && asideDeg, Roads * roads, double fromEastM, int seconds)
{
  Env env(true /* inertial */, roads);
  MarkCar(env, fromEastM);
  double constexpr kSpeedMps = 20;
  double eastM = fromEastM;
  double asideWas = 0;
  for (int i = 1; i <= seconds * 50; ++i)
  {
    double const aside = asideDeg(i * 0.02);
    env.Drive(20, 72, (aside - asideWas) / 0.02);
    asideWas = aside;
    eastM += kSpeedMps * 0.02 * std::cos(math::DegToRad(aside));
  }
  // The position is aside of the street by a few meters until it is put back.
  if (env.m_delegate.HasEvent(Event::RoadLost) || std::fabs(North(env.Last().m_position)) > 10)
    return {};
  return East(env.Last().m_position) - eastM;
}

UNIT_TEST(NoGps_Engine_WeavingCarIsNotAheadOfItself)
{
  // The car drives a longer way than the road is when it overtakes or goes around holes. The position goes where
  // the car looks at and is put back to the road every second, so only the way along the road counts.
  auto const straight = [](double) { return 0.0; };
  // An overtaking every 10 s: the car turns by 5 degrees within half a second, goes to the next lane for 1.5 s,
  // straightens, and comes back the same way 3 s later. 3 m longer than 2 km of the road.
  auto const overtaking = [](double t)
  {
    auto const change = [](double s)
    {
      if (s < 0 || s >= 2.5)
        return 0.0;
      return 5.0 * std::min({s / 0.5, 1.0, (2.5 - s) / 0.5});
    };
    double const s = std::fmod(t, 10.0);
    return change(s) - change(s - 5.5);
  };
  // A snake: 1.8 m to each side every 80 m, 10 m longer than 2 km of the road. A wild one: 2.5 m to each side
  // every 60 m, 34 m longer.
  auto const snake = [](double t) { return 8 * std::sin(2 * math::pi * t / 4); };
  auto const wildSnake = [](double t) { return 15 * std::sin(2 * math::pi * t / 3); };

  // 2 km of a road without crossings, and 900 m of the street with them.
  PieceRoads road({{-3000, 0, 3000, 0}}, {});
  for (Roads * roads : {static_cast<Roads *>(&road), static_cast<Roads *>(nullptr)})
  {
    double const from = roads ? -2500 : -450;
    int const seconds = roads ? 100 : 45;
    auto const base = DriveAside(straight, roads, from, seconds);
    auto const overtakes = DriveAside(overtaking, roads, from, seconds);
    auto const snakes = DriveAside(snake, roads, from, seconds);
    auto const wildSnakes = DriveAside(wildSnake, roads, from, seconds);
    TEST(base && overtakes && snakes && wildSnakes, (roads != nullptr));
    LOG(LWARNING, (roads ? "A road without crossings, 2 km." : "A street with a crossing every 100 m, 900 m.",
                   "Ahead of the car: straight", *base, "m, overtaking", *overtakes, "m, a snake", *snakes,
                   "m, a wild snake", *wildSnakes, "m"));
    TEST_LESS(std::fabs(*overtakes - *base), 1, ());
    TEST_LESS(std::fabs(*snakes - *base), 1, ());
    TEST_LESS(std::fabs(*wildSnakes - *base), 1, ());
  }
}

UNIT_TEST(NoGps_Engine_GpsIsBackAfterRoadIsLost)
{
  Env env(true /* inertial */);
  MarkCar(env, -400);
  // The heading goes wrong slowly, slower than a turn: the car leaves the road, the calculation stops.
  env.Drive(12'000, 36, -5);
  env.Drive(5000, 36, 0);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST(env.m_engine.IsManualMode(), ());
  // GPS works again, far from where the calculation has stopped: there is nothing to compare it with, it
  // is trusted after it has worked for long enough.
  for (int i = 0; i <= GpsReturnDetector::kMinStreakMs / 1000 + 1; ++i)
  {
    env.Drive(1000, 36, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 10 * i, 300, 90.0, 10.0));
  }
  TEST(!env.m_engine.IsManualMode(), ());
  TEST(env.m_delegate.HasEvent(Event::GpsBack), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());
}

UNIT_TEST(NoGps_Engine_TripLineHasPlatformPositions)
{
  Env env(true /* inertial */);
  TEST(env.m_engine.GetTripLine().find(" gps=") == std::string::npos, ());

  env.m_clock.Advance(1000);
  env.m_engine.OnFix(GpsAt(env.m_clock, 100, 0, 90.0, 10.0, 4));
  env.m_clock.Advance(250);
  char expected[128];
  std::snprintf(expected, sizeof(expected), " gps=%.6f,%.6f/4.0/36.0/90.0/0.25/- ", At(100, 0).m_lat, At(100, 0).m_lon);
  std::string line = env.m_engine.GetTripLine();
  TEST(line.find(expected) != std::string::npos, (line));

  // The position GPS is ignored with, e.g. to test the inertial navigation, is written too: the shown position is
  // compared with it. This one has no speed and no bearing.
  env.m_engine.SetGpsDisabled(true);
  env.m_clock.Advance(1000);
  env.m_engine.OnFix(GpsAt(env.m_clock, 200, 0));
  std::snprintf(expected, sizeof(expected), " gps=%.6f,%.6f/5.0/-/-/0.00/- ", At(200, 0).m_lat, At(200, 0).m_lon);
  line = env.m_engine.GetTripLine();
  TEST(line.find(expected) != std::string::npos, (line));

  // The satellites mixed with Wi-Fi and cell towers, the only position of iOS, are written apart.
  TEST(line.find(" fused=") == std::string::npos, (line));
  auto fused = GpsAt(env.m_clock, 300, 0, 90.0, 10.0, 8);
  fused.m_provider = Provider::Fused;
  env.m_engine.OnFix(fused);
  std::snprintf(expected, sizeof(expected), " fused=%.6f,%.6f/8.0/36.0/90.0/0.00/- ", At(300, 0).m_lat,
                At(300, 0).m_lon);
  line = env.m_engine.GetTripLine();
  TEST(line.find(expected) != std::string::npos, (line));
  TEST(line.find(" gps=") != std::string::npos, (line));

  // An old position tells nothing about the car now.
  env.m_clock.Advance(Engine::kGpsStatusMaxAgeMs + 1000);
  line = env.m_engine.GetTripLine();
  TEST(line.find(" gps=") == std::string::npos && line.find(" fused=") == std::string::npos, (line));
}

UNIT_TEST(NoGps_Engine_TripLineHasCompass)
{
  Env env(true /* inertial */);
  TEST(env.m_engine.GetTripLine().find(" cmp=") == std::string::npos, ());

  env.m_engine.OnCompass(271.4, 15);
  env.m_clock.Advance(250);
  TEST_EQUAL(TripField(env, "cmp"), "271/15/0.25", ());

  // An old heading tells nothing about the car now.
  env.m_clock.Advance(Engine::kGpsStatusMaxAgeMs);
  TEST(env.m_engine.GetTripLine().find(" cmp=") == std::string::npos, ());
}

UNIT_TEST(NoGps_Engine_TripLineTellsWhyCarIsNotOnRoad)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  env.Drive(3000, 9, 0);
  std::string line = env.m_engine.GetTripLine();
  TEST(line.find(" rdiff=0 snapwhy=ROAD ") != std::string::npos, (line));
  TEST(line.find(" speed=9 sage=0 ") != std::string::npos, (line));
  TEST(line.find(" turning=0 odo=7 offm=0 offv=0 cand=- ") != std::string::npos, (line));

  // The car turns right by 40 degrees: the street goes another way than it looks.
  env.Drive(1000, 9, 40);
  TEST(env.m_engine.GetTripLine().find(" turning=1 ") != std::string::npos, (env.m_engine.GetTripLine()));
  env.Drive(2500, 9, 0);
  line = env.m_engine.GetTripLine();
  TEST(line.find(" rdiff=40 snapwhy=ANGLE ") != std::string::npos, (line));
  TEST(line.find(" turning=0 odo=16 offm=4 offv=9 cand=- ") != std::string::npos, (line));

  // And to the south: no street goes that way.
  env.Drive(1000, 9, 50);
  env.Drive(1500, 9, 0);
  line = env.m_engine.GetTripLine();
  TEST(line.find(" rdiff=- snapwhy=NOROAD ") != std::string::npos, (line));
}

/// The car marked on the street going east leaves it to the right at a walking speed and drives 24 m into a yard.
void DriveIntoYard(Env & env)
{
  MarkCar(env, 0);
  env.Drive(2000, 9, 0);
  env.Drive(1000, 9, 90);
  env.Drive(9000, 9, 0);
}

UNIT_TEST(NoGps_Engine_ManeuveringCarIsFollowedApart)
{
  // A street going east, and a street 40 m to the south of it going the same way.
  PieceRoads roads({{-300, 0, 300, 0}, {-300, -40, 600, -40}}, {});
  for (bool navigating : {true, false})
  {
    Env env(true /* inertial */, &roads);
    env.m_map.m_navigating = navigating;
    DriveIntoYard(env);
    TEST(FollowedApart(env), (navigating, env.m_engine.GetTripLine()));
    TEST(!env.m_engine.GetStatus().m_roadLost, (navigating));
    TEST(!env.m_delegate.HasEvent(Event::RoadLost), (navigating));
    // The mark follows the car into the yard, with a route too: the user sees that the car has left the road.
    TestAlmostEqualAbs(North(env.Last().m_position), -24, 3);
    TestAlmostEqualAbs(East(env.Last().m_position), 7, 3);
    TestAlmostEqualAbs(*env.Last().m_bearingDeg, 180, 1);
    // The map does not draw it on the route or on a road.
    TEST(env.m_map.m_followedApart, (navigating));

    // The engine stopped, e.g. real GPS is back: the map matches its positions again.
    {
      env.m_engine.Stop();
      TEST(!env.m_map.m_followedApart, (navigating));
      env.m_engine.Start();
    }

    // The car turns left and drives east, the other street is 15 m to the right of it. It is not the street of
    // the car at once.
    env.Drive(1000, 9, -90);
    env.Drive(3000, 9, 0);
    TEST(FollowedApart(env), (navigating));
    // The car has driven along it for 15 m: it is on it, looking along it.
    env.Drive(6000, 9, 0);
    TEST(!FollowedApart(env), (navigating));
    TestAlmostEqualAbs(North(env.Last().m_position), -40, 0.5);
    TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 0.5);
    TEST(!env.m_map.m_followedApart, (navigating));
    double const east = East(env.Last().m_position);
    TEST_GREATER(east, 20, ());
    env.Drive(4000, 9, 0);
    TestAlmostEqualAbs(North(env.Last().m_position), -40, 0.5);
    TestAlmostEqualAbs(East(env.Last().m_position), east + 10, 3);
    TEST(!env.m_delegate.HasEvent(Event::RoadLost), (navigating));
    TEST(env.m_engine.GetTripLine().find(" self=1") == std::string::npos, (env.m_engine.GetTripLine()));
  }
}

UNIT_TEST(NoGps_Engine_CarFollowedApartWaitsForUser)
{
  // The street ends 20 m to the east of the car, there are no other roads.
  PieceRoads roads({{-300, 0, 20, 0}}, {});
  Env env(true /* inertial */, &roads);
  env.m_map.m_navigating = true;
  DriveIntoYard(env);
  TEST(FollowedApart(env), ());
  // A car maneuvering off the roads is not lost.
  TEST(!env.m_engine.GetStatus().m_roadLost, ());

  // The car turns east and drives fast where the map has no roads: nobody maneuvers so, but there is no road
  // to put the car on. The mark follows the car, the user is told.
  env.Drive(1000, 9, -90);
  env.Drive(8000, 36, 0);
  TEST(FollowedApart(env), ());
  TEST(env.m_engine.GetStatus().m_roadLost, ());
  TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  TEST_GREATER(East(env.Last().m_position), 80, ());
  TEST_LESS(North(env.Last().m_position), -10, ());

  // The mark of the user ends it.
  TEST(env.m_engine.PlaceMarkByTap(At(-100, 2)), ());
  TEST(!env.m_engine.GetStatus().m_roadLost, ());
  TEST(!FollowedApart(env), ());
}

UNIT_TEST(NoGps_Engine_MarkOfUserEndsFollowingApart)
{
  PieceRoads roads({{-300, 0, 300, 0}}, {});
  Env env(true /* inertial */, &roads);
  env.m_map.m_navigating = true;
  DriveIntoYard(env);
  TEST(FollowedApart(env), ());
  TEST_LESS(North(env.Last().m_position), -10, ());

  // The car is where the user tells, not where it has maneuvered to by the calculation.
  TEST(env.m_engine.PlaceMarkByTap(At(100, 2)), ());
  TEST(!FollowedApart(env), ());
  env.Drive(2000, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), 100, 0.5);
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
}

UNIT_TEST(NoGps_Engine_CarInYardDoesNotRebuildRoute)
{
  // The street of the route goes east, the car maneuvers in a yard 30 m or 60 m to the south of it for a minute.
  PieceRoads roads({{-300, 0, 300, 0}}, {});
  for (int yardM : {30, 60})
  {
    Env env(true /* inertial */, &roads);
    env.m_map.m_navigating = true;
    MarkCar(env, 0);
    env.Drive(2000, 9, 0);
    env.Drive(1000, 9, 90);
    env.Drive(std::lround((yardM - 3) / 2.5 * 1000), 9, 0);
    TEST(FollowedApart(env), (yardM, env.m_engine.GetTripLine()));
    int const rebuilds = env.m_map.m_rebuilds;
    int const lefts = env.m_map.m_routeLefts;
    for (int i = 0; i < 6; ++i)
    {
      env.Drive(4000, 9, 0);
      env.Drive(1000, 0, 0);
      env.Drive(4000, 9, 0);
      env.Drive(1000, 0, 0);
      // Back and forth along the yard.
      env.Drive(1000, 9, 180);
    }
    // The engine itself neither rebuilds nor leaves the route every second.
    TEST(FollowedApart(env), (yardM));
    TEST_EQUAL(env.m_map.m_rebuilds, rebuilds, (yardM));
    TEST_EQUAL(env.m_map.m_routeLefts, lefts, (yardM));
    // The mark is in the yard. The core takes a car nearer to the route than 50 m or its accuracy for one on the
    // route, and rebuilds the route once it is farther: not for the yard at 30 m, once for the one at 60 m.
    TestAlmostEqualAbs(North(env.Last().m_position), -yardM, 5);
    TEST_LESS(env.Last().m_accuracyM, 50, (yardM));
  }
}

UNIT_TEST(NoGps_Engine_FastCarComesBackToRoadFarAside)
{
  // A street going east that ends 20 m ahead of the car, and a street 55 m to the south of it going the same way.
  PieceRoads roads({{-300, 0, 20, 0}, {-300, -55, 900, -55}}, {});
  Env env(true /* inertial */, &roads);
  env.m_map.m_navigating = true;
  DriveIntoYard(env);
  TEST(FollowedApart(env), ());
  // The car turns east and drives 30 m from the other street, too far to be put on it while it maneuvers.
  env.Drive(1000, 9, -90);
  env.Drive(8000, 9, 0);
  TEST(FollowedApart(env), ());
  // It drives fast for 3 s: nobody maneuvers so, it is on the street going its way.
  env.Drive(3500, 36, 0);
  TEST(!FollowedApart(env), ());
  env.Drive(1000, 36, 0);
  TestAlmostEqualAbs(North(env.Last().m_position), -55, 0.5);
  TestAlmostEqualAbs(*env.Last().m_bearingDeg, 90, 0.5);
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_ManeuveringCarIsNotThrownToRoadAside)
{
  // A street going east and a street going south from it at 30 m. The map doesn't tell that they cross: the turn
  // of the car is not moved to the crossing.
  PieceRoads roads({{-300, 0, 600, 0}, {30, 0, 30, -600}}, {});
  for (int speedKmh : {9, 36})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    // The car turns right 12 m before the other street or more. The calculated position is ahead of what the test
    // counts by the lag of the car speed.
    double const speedMps = speedKmh / 3.6;
    env.Drive(std::llround((15 - speedMps * 0.64) / speedMps * 1000), speedKmh, 0);
    env.Drive(1000, speedKmh, 90);
    env.Drive(3000, speedKmh, 0);
    TestAlmostEqualAbs(*env.Last().m_bearingDeg, 180, 3);
    if (speedKmh == 9)
    {
      // A maneuvering car is not on that street yet: next to a yard such a street is behind the houses.
      TEST_GREATER(East(env.Last().m_position), 14, ());
      TEST_LESS(East(env.Last().m_position), 19.5, ());
      TEST(!FollowedApart(env), ());
      // It has driven along the street for 15 m: it is put on it, and was not followed apart meanwhile.
      env.Drive(2000, speedKmh, 0);
      TEST(!FollowedApart(env), ());
      env.Drive(4000, speedKmh, 0);
    }
    // A car driving along a road is thrown to it at once.
    TestAlmostEqualAbs(East(env.Last().m_position), 30, 0.5);
    TestAlmostEqualAbs(*env.Last().m_bearingDeg, 180, 1);
    TEST(!FollowedApart(env), (speedKmh));
    TEST(!env.m_delegate.HasEvent(Event::RoadLost), (speedKmh));
  }
}

/// A car with the sensor box: it speeds up, brakes and turns as the test tells, backwards too. The box reports the
/// speed of the car 1.2 s late and without a sign.
class BoxCar
{
public:
  /// \param accelerometer the box has one, it looks forward with its first horizontal axis.
  BoxCar(Env & env, double eastM, bool accelerometer)
    : m_env(env)
    , m_accelerometer(accelerometer)
    , m_east(eastM)
    , m_speeds(60, 0.0)
  {}

  /// \param accelerationMps2 along the car, negative to brake or to speed up backwards.
  void Drive(double seconds, double accelerationMps2, double yawRateDegS)
  {
    for (int i = 0; i < std::lround(seconds * 50); ++i)
    {
      m_speed += accelerationMps2 * 0.02;
      m_headingDeg += yawRateDegS * 0.02;
      m_yawMdeg += yawRateDegS * 20;
      m_east += m_speed * 0.02 * std::sin(math::DegToRad(m_headingDeg));
      m_north += m_speed * 0.02 * std::cos(math::DegToRad(m_headingDeg));
      m_speeds.push_back(std::fabs(m_speed));
      // The box sends the last speed it has heard, and how long ago.
      if (m_speedUnheard)
      {
        m_speedAgeMs += 20;
      }
      else
      {
        m_reportedKmh = std::max(m_minReportedKmh, static_cast<int>(std::lround(m_speeds.front() * 3.6)));
        m_speedAgeMs = 0;
      }
      m_speeds.pop_front();

      m_env.m_clock.Advance(20);
      m_boxTimeMs += 20;
      char body[160];
      int const length =
          std::snprintf(body, sizeof(body), "NGD,1,%lld,%lld,%lld,0,0,%d,%d,%X", static_cast<long long>(++m_seq),
                        static_cast<long long>(m_boxTimeMs), static_cast<long long>(std::llround(m_yawMdeg)),
                        m_reportedKmh, m_speedAgeMs, kCalibratedFlags);
      // A little of the gravity is left in the other axes.
      if (m_accelerometer)
        std::snprintf(body + length, sizeof(body) - length, ",%d,50,-60,100",
                      static_cast<int>(std::lround((m_accelSign * accelerationMps2 + m_slopeMps2) * 1000)));
      m_env.m_engine.OnEsp32BleBytes(BoxLine(body));
    }
  }

  /// The car speeds up and brakes four times, 900 m along its way, and stands: the box learns where its
  /// accelerometer looks.
  void SpeedUpAndBrake()
  {
    for (int i = 0; i < 4; ++i)
    {
      Drive(10, 1.5, 0);
      Drive(5, 0, 0);
      Drive(10, -1.5, 0);
      Drive(5, 0, 0);
    }
  }

  double East() const { return m_east; }
  double Speed() const { return m_speed; }
  double North() const { return m_north; }

  // The gravity the accelerometer feels along the car on a slope.
  double m_slopeMps2 = 0;
  // The car reports at least this speed, e.g. 1 km/h while it changes the gear.
  int m_minReportedKmh = 0;
  // -1: the box is put in turned around.
  double m_accelSign = 1;
  // The box doesn't hear the car speed, e.g. while the engine is off.
  bool m_speedUnheard = false;

private:
  Env & m_env;
  bool const m_accelerometer;
  double m_east;
  double m_north = 0;
  double m_headingDeg = 90;
  // Negative while the car drives backwards.
  double m_speed = 0;
  // The speeds of the car of the last 1.2 s.
  std::deque<double> m_speeds;
  int m_reportedKmh = 0;
  int m_speedAgeMs = 0;
  int64_t m_seq = 1000;
  int64_t m_boxTimeMs = 200'000;
  double m_yawMdeg = 0;
};

UNIT_TEST(NoGps_Engine_AccelerometerTellsCarInYardDrivesBack)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  for (bool accelerometer : {true, false})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, -450);
    BoxCar car(env, -450, accelerometer);
    car.SpeedUpAndBrake();
    TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 5);

    // It turns right into a yard at a walking speed, drives 20 m and stops there.
    car.Drive(2.5, 1, 0);
    car.Drive(1, 0, 90);
    car.Drive(8, 0, 0);
    car.Drive(2.5, -1, 0);
    car.Drive(4, 0, 0);
    TEST(FollowedApart(env), (accelerometer));
    TestAlmostEqualAbs(North(env.Last().m_position), car.North(), 4);
    double const stoppedNorth = North(env.Last().m_position);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));

    // It drives 12 m backwards. The speed of the car tells the same as if it drove forward.
    car.Drive(2, -1, 0);
    car.Drive(2, 0, 0);
    TEST_EQUAL(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, accelerometer,
               (env.m_engine.GetTripLine()));
    car.Drive(2, 0, 0);
    car.Drive(2, 1, 0);
    car.Drive(3, 0, 0);
    TEST(FollowedApart(env), (accelerometer));
    if (accelerometer)
    {
      TestAlmostEqualAbs(North(env.Last().m_position), stoppedNorth + 12, 3);
      TestAlmostEqualAbs(North(env.Last().m_position), car.North(), 4);
    }
    else
    {
      TestAlmostEqualAbs(North(env.Last().m_position), stoppedNorth - 12, 3);
    }

    // And forward again, 12 m more than it has driven back.
    car.Drive(2, 1, 0);
    car.Drive(10, 0, 0);
    car.Drive(2, -1, 0);
    car.Drive(3, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
    if (accelerometer)
      TestAlmostEqualAbs(North(env.Last().m_position), car.North(), 4);
  }
}

// The car marked on the street going east drives at 30 km/h along it.
void DriveAt30(BoxCar & car)
{
  car.Drive(25.0 / 3, 1, 0);
  car.Drive(3, 0, 0);
}

UNIT_TEST(NoGps_Engine_CarBrakingIntoGasStationIsFollowedApart)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  // It brakes and turns right into a gas station: after it has left the street it reports the speed it drove the
  // street at, then the speed it brakes with, rising by 1 km/h for a moment or not. It stops 22-27 m off the street.
  for (bool rises : {false, true})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    BoxCar car(env, 0, false /* accelerometer */);
    DriveAt30(car);
    if (rises)
    {
      car.Drive(1, -0.5, 0);
      car.Drive(1, -0.5, 90);
      car.Drive(0.5, -0.5, 0);
      car.Drive(0.7, 0.4, 0);
      car.Drive(4.91, -1.5, 0);
    }
    else
    {
      car.Drive(1, -1, 0);
      car.Drive(1, -1, 90);
      car.Drive(6.3, -1, 0);
    }
    car.Drive(60, 0, 0);
    TEST(FollowedApart(env), (rises, env.m_engine.GetTripLine()));
    // While it brakes it is followed apart by its speed.
    TEST_LESS_OR_EQUAL(std::stod(TripField(env, "offv")), 20, (rises));
    // It drives on after refuelling: it maneuvers, its road is not lost.
    car.Drive(2, 1, 0);
    car.Drive(7, 0, 0);
    TEST(FollowedApart(env), (rises, env.m_engine.GetTripLine()));
    TEST(!env.m_engine.GetStatus().m_roadLost, (rises));
    TEST(!env.m_delegate.HasEvent(Event::RoadLost), (rises));
  }
}

UNIT_TEST(NoGps_Engine_CarLeavingRoadFastIsNotFollowedApart)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  // It turns right off the street at 30 km/h and drives on without braking, or brakes for 2 s and speeds up to
  // 30 km/h again.
  for (bool brakes : {false, true})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, 0);
    BoxCar car(env, 0, false /* accelerometer */);
    DriveAt30(car);
    car.Drive(1, 0, 90);
    if (brakes)
    {
      car.Drive(2, -1, 0);
      car.Drive(2, 1, 0);
    }
    car.Drive(6, 0, 0);
    TEST(!FollowedApart(env), (brakes, env.m_engine.GetTripLine()));
    // The speed it has sped up to counts. Driving on without braking, its speed counts after it has driven 30 m off
    // the roads: its road is lost first.
    if (brakes)
      TEST_GREATER(std::stod(TripField(env, "offv")), 20, ());
    else
      TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  }
}

UNIT_TEST(NoGps_Engine_CarTurningLongOffRoadAfterDrivingFastIsNotFollowedApart)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  BoxCar car(env, 0, false /* accelerometer */);
  car.Drive(25.0 / 3.6, 1, 0);
  car.Drive(3, 0, 0);
  // It leaves the street at 25 km/h without braking, and 2.5 s later turns slowly for 10 s, slowing down to 10 km/h.
  // The speeds it reported before the turn count: on November 7 a car so was followed apart after the turn at the
  // speed it had then.
  car.Drive(1, 0, 45);
  car.Drive(2.5, 0, 0);
  car.Drive(10, -0.4, 15);
  car.Drive(3, 0.3, 0);
  TEST(!FollowedApart(env), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_TurnStartedBeforeCarReportsSpeedIsNotLost)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, 0);
  BoxCar car(env, 0, false /* accelerometer */);
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 90), 0, 1);
  // The car starts and turns right at once, by 90 degrees in 4.5 s. It reports that it moves 1.3 s later: it has
  // turned by 26 degrees by then.
  car.Drive(4.5, 1, 20);
  car.Drive(1.5, 0, 0);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 180), 0, 2);
}

UNIT_TEST(NoGps_Engine_StartBeforeCarSpeedIsHeardIsNotLost)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  for (bool accelerometer : {true, false})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, -450);
    BoxCar car(env, -450, accelerometer);
    car.SpeedUpAndBrake();
    car.Drive(3, 0, 0);
    TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 5);
    double const stoodEast = East(env.Last().m_position) - car.East();

    // The engine is off for 30 s, and the box doesn't hear the car speed. The car starts at once after the engine,
    // and its speed is heard 6 s later only, when it has driven 18 m.
    car.m_speedUnheard = true;
    car.Drive(30, 0, 0);
    car.Drive(6, 1, 0);
    car.m_speedUnheard = false;
    car.Drive(3, 0, 0);
    TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Inertial, ());
    double const behindM = car.East() - East(env.Last().m_position) + stoodEast;
    // Without the accelerometer it has driven the lag at the speed it is heard with, 1.2 s at 4.8 m/s.
    if (accelerometer)
      TestAlmostEqualAbs(behindM, 0, 2);
    else
      TestAlmostEqualAbs(behindM, 18 - 5.8, 2);
  }
}

UNIT_TEST(NoGps_Engine_TurnBeforeCarSpeedIsHeardIsNotLost)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  car.Drive(3, 0, 0);
  // The car speed is not heard. The gyroscope drifts by 0.5 deg/s, the car stands: that is not its turn.
  car.m_speedUnheard = true;
  car.Drive(10, 0, 0.5);
  // The car starts and turns right by 90 degrees in 4.5 s, and its speed is heard after that.
  car.Drive(4.5, 1, 20);
  car.m_speedUnheard = false;
  car.Drive(1.5, 0, 0);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 180), 0, 2);
}

UNIT_TEST(NoGps_Engine_AccelerometerTellsCarOnRoadDrivesBack)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  for (bool accelerometer : {true, false})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, -450);
    BoxCar car(env, -450, accelerometer);
    car.SpeedUpAndBrake();
    TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 5);
    double const stoppedEast = East(env.Last().m_position);

    // It drives 12 m backwards along the street. The speed of the car tells the same as if it drove forward.
    car.Drive(2, -1, 0);
    car.Drive(2, 0, 0);
    TEST_EQUAL(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, accelerometer,
               (env.m_engine.GetTripLine()));
    car.Drive(2, 0, 0);
    car.Drive(2, 1, 0);
    car.Drive(3, 0, 0);
    TestAlmostEqualAbs(East(env.Last().m_position), stoppedEast + (accelerometer ? -12 : 12), 3);
    TestAlmostEqualAbs(North(env.Last().m_position), 0, 1);
    // The car looks where it did.
    TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 90), 0, 3);
    TEST(!FollowedApart(env), (accelerometer));

    // And forward again.
    car.Drive(2, 1, 0);
    car.Drive(10, 0, 0);
    car.Drive(2, -1, 0);
    car.Drive(3, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
    if (accelerometer)
      TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 4);
  }
}

UNIT_TEST(NoGps_Engine_CarBackingIntoSideStreetIsFollowed)
{
  // A street crosses the street going east at 0 m.
  PieceRoads roads({{-2000, 0, 3000, 0}, {0, -500, 0, 500}}, {{0, 0}});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -890);
  BoxCar car(env, -890, true /* accelerometer */);
  // The car stops 10 m after the crossing, the user marks it there.
  car.SpeedUpAndBrake();
  TestAlmostEqualAbs(car.East(), 10, 0.5);
  TEST(env.m_engine.PlaceMarkByTap(At(car.East(), 3)), ());

  // It backs into the side street to the south: 2 m along its street, a quarter of a circle of 8 m, and 2 m along
  // the side street, looking north in the end.
  car.Drive(2, -1, 0);
  car.Drive(6.3, 0, -14.3);
  car.Drive(2, 1, 0);
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(car.East(), 0, 0.5);
  TestAlmostEqualAbs(car.North(), -10, 0.5);
  TestAlmostEqualAbs(East(env.Last().m_position), 0, 1);
  TestAlmostEqualAbs(North(env.Last().m_position), car.North(), 4);
  TestAlmostEqualAbs(AngleDiff(*env.Last().m_bearingDeg, 0), 0, 5);
  // A car rotating that way driving forward turns left at the crossing: this one is not moved as if it did.
  TEST(env.m_engine.GetTripLine().find(" turn=NaN") != std::string::npos, (env.m_engine.GetTripLine()));

  // And drives forward across the crossing.
  car.Drive(2, 1, 0);
  car.Drive(8, 0, 0);
  car.Drive(2, -1, 0);
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(car.North(), 10, 0.5);
  TestAlmostEqualAbs(East(env.Last().m_position), 0, 1);
  TestAlmostEqualAbs(North(env.Last().m_position), car.North(), 4);
  TEST(!FollowedApart(env), ());
  TEST(!env.m_delegate.HasEvent(Event::RoadLost), ());
}

UNIT_TEST(NoGps_Engine_CarDrivingFastDoesNotDriveBack)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  double const stoppedEast = East(env.Last().m_position);

  // The street goes down from where the car stood: the car starts forward, the accelerometer feels a start backward.
  car.m_slopeMps2 = -2.5;
  car.Drive(3, 1, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  TEST_LESS(East(env.Last().m_position), stoppedEast, ());

  // Nobody drives 15 km/h backwards: the car is where it would be if it was known to drive forward.
  car.m_slopeMps2 = 0;
  car.Drive(3, 1, 0);
  car.Drive(5, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 5);
}

UNIT_TEST(NoGps_Engine_BoxTurnedAroundDoesNotDriveEveryStartBack)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The box is put in turned by 180 degrees: its accelerometer feels every start forward as a start backward.
  car.m_accelSign = -1;
  int back = 0;
  for (int i = 0; i < 4; ++i)
  {
    car.Drive(3, 1, 0);
    if (env.m_engine.GetTripLine().find(" back=1") != std::string::npos)
      ++back;
    // Faster than anybody drives backwards, it speeds up and brakes: the accelerometer is compared with the car.
    car.Drive(5, 1, 0);
    car.Drive(8, 0, 0);
    for (int j = 0; j < 2; ++j)
    {
      car.Drive(3, 1, 0);
      car.Drive(3, -1, 0);
    }
    car.Drive(8, -1, 0);
    car.Drive(3, 0, 0);
  }
  // Only the first start, before the accelerometer is found not to follow the car.
  TEST_LESS_OR_EQUAL(back, 1, ());
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 15);
}

UNIT_TEST(NoGps_Engine_BoxCalibrationKeepsAccelerometer)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  env.m_engine.Calibrate();
  // The same box: a reverse right after the calibration is told backward.
  car.Drive(2, -1, 0);
  car.Drive(2, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_Engine_BoxCalibrationTurnedBoxIsLearnedAnew)
{
  // The trip line tells "boxacc=<correlation>/-" while the box accelerometer is not used.
  auto const accelUsed = [](Env & env)
  {
    std::string const line = env.m_engine.GetTripLine();
    auto const at = line.find(" boxacc=");
    TEST(at != std::string::npos, (line));
    return line[line.find('/', at) + 1] != '-';
  };
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  TEST(accelUsed(env), ());

  // The box is put in turned around and calibrated: the direction learned before is kept, the check of the
  // accelerometer against the car forgets it while driving, and it is learned the right way.
  env.m_engine.Calibrate();
  TEST(accelUsed(env), ());
  car.m_accelSign = -1;
  car.Drive(3, 0, 0);
  car.SpeedUpAndBrake();
  car.SpeedUpAndBrake();
  TEST(accelUsed(env), ());
  double const stoppedEast = East(env.Last().m_position);
  car.Drive(2, -1, 0);
  car.Drive(2, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  car.Drive(2, 0, 0);
  car.Drive(2, 1, 0);
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), stoppedEast - 12, 3);
}

UNIT_TEST(NoGps_Engine_InertialDrivingBackIsNotShownBetweenGpsPositions)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  env.m_engine.SetManualMode(false);

  // The street goes down from where the car stood: the car starts forward, the accelerometer feels a start backward.
  // GPS tells the way the car goes.
  car.m_slopeMps2 = -2.5;
  car.Drive(3, 1, 0);
  car.m_slopeMps2 = 0;
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  auto gps = GpsAt(env.m_clock, car.East(), 0, 90.0, 3.0);
  gps.m_bearingAccuracyDeg = 5;
  env.m_engine.OnFix(gps);
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());

  // The inertial navigation would move the mark back between GPS positions.
  size_t const shown = env.m_delegate.m_positions.size();
  car.Drive(0.6, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  TEST_EQUAL(env.m_delegate.m_positions.size(), shown, ());
}

UNIT_TEST(NoGps_Engine_CarStartingWithJerkBackDrivesForward)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  double const stoppedEast = East(env.Last().m_position);

  // The car creeps forward, and its first jerk is felt as a start backward.
  car.m_slopeMps2 = -2.5;
  car.Drive(0.3, 1, 0);
  car.m_slopeMps2 = 0;
  car.Drive(1.6, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));

  // It speeds up to 12 km/h, slower than a car that is known to drive forward by its speed. The accelerometer feels
  // the speed the car reports, growing forward.
  car.Drive(3, 1, 0);
  car.Drive(2, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  TEST_GREATER(East(env.Last().m_position), stoppedEast + 10, ());
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarCrawlingBackAfterSmallRollIsFollowed)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  for (double pullAfterSec : {0.5, 2.0})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, -450);
    BoxCar car(env, -450, true /* accelerometer */);
    car.SpeedUpAndBrake();

    // Shifted into reverse, the car rolls forward by 2 cm and reports 1 km/h at once, as on November 13 at 19:24:36.
    car.m_minReportedKmh = 1;
    car.Drive(0.2, 0.5, 0);
    car.Drive(0.2, -0.5, 0);
    car.Drive(pullAfterSec - 0.4, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (pullAfterSec, env.m_engine.GetTripLine()));
    // The brake is released later: it backs at 4 km/h, which it reports the lag late.
    car.Drive(2.2, -0.5, 0);
    car.Drive(0.6, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (pullAfterSec, env.m_engine.GetTripLine()));
    car.m_minReportedKmh = 0;
    car.Drive(3, 0, 0);
    car.Drive(2.2, 0.5, 0);
    car.Drive(3, 0, 0);
    TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 2);
  }
}

UNIT_TEST(NoGps_Engine_CarSpeedingUpDownRampIsNotTurnedBack)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car starts forward to 8 km/h and drives down a ramp: the accelerometer feels a pull backward as strong as
  // the speed of the car. It reports more than a crawl by then: the speed of the lag ago is compared.
  car.Drive(1.5, 1.5, 0);
  car.m_slopeMps2 = -3;
  for (int i = 0; i < 30; ++i)
  {
    car.Drive(0.1, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (i, env.m_engine.GetTripLine()));
  }
  car.m_slopeMps2 = 0;
  car.Drive(5, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarCrawlingForwardStaysForward)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car creeps forward at 1 km/h, which it reports at once, onto a gentle slope down that is felt as a pull
  // backward, and speeds up.
  car.m_minReportedKmh = 1;
  car.Drive(1, 0.3, 0);
  car.m_slopeMps2 = -0.15;
  for (int i = 0; i < 40; ++i)
  {
    car.Drive(0.1, i < 30 ? 0 : 0.5, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (i, env.m_engine.GetTripLine()));
  }
  car.m_slopeMps2 = 0;
  car.m_minReportedKmh = 0;
  car.Drive(5, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarStartingClearlyForwardAndBrakingStaysForward)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car jerks forward to 1 m/s and brakes to a crawl at once, the box pitching forward as it brakes, as on
  // October 19 at 07:55:51: the start was felt clearly forward.
  car.m_minReportedKmh = 1;
  car.Drive(0.5, 2, 0);
  car.Drive(0.5, -1.8, 0);
  car.m_slopeMps2 = -1.5;
  for (int i = 0; i < 30; ++i)
  {
    car.Drive(0.1, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (i, env.m_engine.GetTripLine()));
  }
  car.m_slopeMps2 = 0;
  car.m_minReportedKmh = 0;
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

// The car creeps backward from a stand with a start too weak to tell its way, speeds up to |topAccel| * 5 s and brakes.
// The stop pulls it forward, as on November 15 at 11:23:37.
static void CreepBackAndBrake(BoxCar & car, double topAccel)
{
  car.m_minReportedKmh = 1;
  car.Drive(4, -0.05, 0);
  car.Drive(1, 0, 0);
  car.Drive(5, topAccel, 0);
  car.Drive(2, 0, 0);
  car.m_minReportedKmh = 0;
  car.Drive(-car.Speed() / 1.0, 1, 0);
  car.Drive(3, 0, 0);
}

UNIT_TEST(NoGps_Engine_StopPullTurnsSegmentStartedWeakly)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  double const startEast = car.East();

  CreepBackAndBrake(car, -0.2);
  TEST_LESS(car.East(), startEast - 5, ());
  // The start was told forward, the stop tells that the car has backed.
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_StopPullKeepsFastSegment)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  double const startEast = car.East();

  // 12 km/h is faster than a segment that is checked by its stop.
  CreepBackAndBrake(car, -0.65);
  TEST_LESS(car.East(), startEast - 5, ());
  TEST_GREATER(East(env.Last().m_position), startEast, ());
}

UNIT_TEST(NoGps_Engine_StopPullKeepsClearForwardStart)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car starts clearly forward to 5 km/h and brakes over a curb that pulls it the other way.
  car.Drive(1.5, 1, 0);
  car.Drive(2, 0, 0);
  car.m_slopeMps2 = 2.5;
  car.Drive(1.5, -1, 0);
  car.m_slopeMps2 = 0;
  car.Drive(3, 0, 0);
  // The pull moves the mark ahead a little. A segment turned would put it 10 m behind.
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 6);
}

UNIT_TEST(NoGps_Engine_StopPullChangesNothingWithoutAccelerometer)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, false /* accelerometer */);
  car.SpeedUpAndBrake();
  double const startEast = East(env.Last().m_position);

  CreepBackAndBrake(car, -0.2);
  TEST_GREATER(East(env.Last().m_position), startEast, ());
  // Without the check the segment is not turned: the mark stays far ahead of the car that has backed.
  TEST_GREATER(East(env.Last().m_position), car.East() + 5, ());
}

UNIT_TEST(NoGps_Engine_CarCrawlingAfterShortStopStaysForward)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car drives 6 m and stops for 1.5 s, too short to feel it standing: the stand before is taken.
  car.Drive(2, 1, 0);
  car.Drive(1, 0, 0);
  car.Drive(2, -1, 0);
  car.Drive(1.5, 0, 0);
  // It crawls forward at 1 km/h onto a slope down that the stand before didn't have, as on October 15 at 09:47:12.
  car.m_minReportedKmh = 1;
  car.Drive(0.6, 0.5, 0);
  car.m_slopeMps2 = -0.6;
  for (int i = 0; i < 34; ++i)
  {
    car.Drive(0.1, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (i, env.m_engine.GetTripLine()));
  }
  car.m_slopeMps2 = 0;
  car.m_minReportedKmh = 0;
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarCrawlingAfterSlowMomentStaysForward)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car drives forward at 5 km/h, slows down to 1 km/h for 2 s without a stop and speeds up to 3 km/h.
  car.Drive(1.4, 1, 0);
  car.Drive(3, 0, 0);
  car.m_minReportedKmh = 1;
  car.Drive(1.4, -1, 0);
  car.Drive(2, 0, 0);
  car.Drive(1, 0.5, 0);
  car.Drive(2, 0, 0);
  // 3 s after it sped up it drives onto a slope down felt as a pull backward: a rise after 1 km/h only ends driving
  // backwards.
  car.m_slopeMps2 = -1.5;
  for (int i = 0; i < 20; ++i)
  {
    car.Drive(0.1, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (i, env.m_engine.GetTripLine()));
  }
  car.m_slopeMps2 = 0;
  car.m_minReportedKmh = 0;
  car.Drive(5, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarDrivingBackAfterShortStopIsFollowed)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car parks: 6 m forward, a stop of a second, which is too short to feel what the accelerometer feels
  // standing, and 8 m backward.
  car.Drive(2, 1, 0);
  car.Drive(1, 0, 0);
  car.Drive(2, -1, 0);
  car.Drive(1, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  car.Drive(2, -1, 0);
  car.Drive(2, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  car.Drive(2, 1, 0);
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarDrivingBackAfterStopReportedLateIsFollowed)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car drives 56 m and stops for 1.4 s: the stand before is too far to take what was felt there. The car reports
  // 0 for as long, but the lag later: it has stood for sure from the lag before that.
  car.Drive(4, 1, 0);
  car.Drive(10, 0, 0);
  car.Drive(4, -1, 0);
  car.Drive(1.4, 0, 0);
  double const stoppedEast = car.East();
  // And backward, as on October 18 at 21:23:31.
  car.Drive(2, -1, 0);
  car.Drive(2, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  car.Drive(2, 1, 0);
  car.Drive(3, 0, 0);
  TestAlmostEqualAbs(car.East(), stoppedEast - 8, 0.5);
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_CarChangingGearAt1KmhIsFollowed)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car drives 6 m backward at 5 km/h.
  car.Drive(1.4, -1, 0);
  car.Drive(3.6, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  // It changes the gear, and the speed it reports doesn't reach 0, as on October 18 at 21:23:40.
  car.m_minReportedKmh = 1;
  car.Drive(2.8, 1, 0);
  car.m_minReportedKmh = 0;
  // Forward at 5 km/h for 10 m.
  car.Drive(7, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);

  // It stops for 3 s and drives backward at 5 km/h again, then slower, at 1 km/h for 2 s, and faster again: it still
  // drives backward.
  car.Drive(1.4, -1, 0);
  car.Drive(3, 0, 0);
  car.Drive(1.4, -1, 0);
  car.Drive(3, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  car.Drive(1, 1.1, 0);
  car.Drive(2, 0, 0);
  car.Drive(1, -1.1, 0);
  car.Drive(3, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);

  // It stops for 3 s and drives forward at 5 km/h, then slower, at 1 km/h for 2 s on a slope the accelerometer feels
  // as driving backwards, and faster again: it still drives forward, a slow moment only ends driving backwards.
  car.Drive(1.4, 1, 0);
  car.Drive(3, 0, 0);
  car.Drive(1.4, 1, 0);
  car.Drive(3, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  car.Drive(1, -1.1, 0);
  car.m_slopeMps2 = -1;
  car.Drive(2, 0, 0);
  car.Drive(1, 1.1, 0);
  car.Drive(3, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  TestAlmostEqualAbs(East(env.Last().m_position), car.East(), 3);
}

UNIT_TEST(NoGps_Engine_SpeedTableIsNotLearnedWhileCarDrivesBack)
{
  PieceRoads roads({{-3000, 0, 3000, 0}}, {});
  for (bool back : {false, true})
  {
    Env env(true /* inertial */, &roads);
    MarkCar(env, -450);
    BoxCar car(env, -450, true /* accelerometer */);
    car.SpeedUpAndBrake();
    if (back)
    {
      // Backs at 7 km/h, long enough to measure a range, GPS tells the speed every second.
      car.Drive(2, -1, 0);
      car.Drive(1, 0, 0);
      TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
    }
    else
    {
      car.Drive(2, 1, 0);
    }
    double const sign = back ? -1 : 1;
    for (int i = 0; i < 300; ++i)
    {
      car.Drive(1, 0, 0);
      env.m_engine.OnFix(GpsAt(env.m_clock, car.East(), car.North(), 90.0, std::fabs(car.Speed())));
    }
    TEST_EQUAL(sign * car.Speed() > 0, true, ());
    // Driving forward the same way is learned.
    TEST_EQUAL(env.m_engine.GetStatus().m_speedTableRanges > 0, !back,
               (back, env.m_engine.GetStatus().m_speedTableRanges));
  }
}

UNIT_TEST(NoGps_Engine_SpeedScaleIsNotMeasuredOnMetersDrivenBack)
{
  PieceRoads roads({{-3000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();
  // The first correction starts the distance the scale is measured on from zero.
  TEST_GREATER(env.m_engine.ShiftPosition(2), 0, ());
  double const scale = env.m_engine.GetStatus().m_speedScale;

  // 280 m forward, under kMinDistanceM, and 4 times 12 m back, which pass it only when they are counted.
  car.Drive(10, 1, 0);
  car.Drive(18, 0, 0);
  car.Drive(10, -1, 0);
  car.Drive(2, 0, 0);
  for (int i = 0; i < 4; ++i)
  {
    car.Drive(2, -1, 0);
    car.Drive(2, 0, 0);
    TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (i, env.m_engine.GetTripLine()));
    car.Drive(2, 0, 0);
    car.Drive(2, 1, 0);
    car.Drive(3, 0, 0);
  }
  TEST_GREATER(env.m_engine.ShiftPosition(30), 0, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_speedScale, scale, ());
}

UNIT_TEST(NoGps_Engine_AccelerometerIsNotLearnedFromManeuvers)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, true /* accelerometer */);
  car.SpeedUpAndBrake();

  // The car backs down a slope that begins where it stood: the accelerometer feels a start forward.
  car.m_slopeMps2 = 3;
  car.Drive(2, -1, 0);
  TEST(env.m_engine.GetTripLine().find(" back=0") != std::string::npos, (env.m_engine.GetTripLine()));
  // It speeds up and brakes for a minute at 4-11 km/h, driving backwards: its speed grows while the accelerometer
  // feels it braking.
  car.Drive(1, -1, 0);
  for (int i = 0; i < 15; ++i)
  {
    car.Drive(2, 1, 0);
    car.Drive(2, -1, 0);
  }
  car.Drive(3, 1, 0);
  car.Drive(5, 0, 0);

  // The accelerometer still knows where the car looks: the next start backward is told.
  car.Drive(2, -1, 0);
  car.Drive(2, 0, 0);
  TEST(env.m_engine.GetTripLine().find(" back=1") != std::string::npos, (env.m_engine.GetTripLine()));
}

namespace
{
/// GPS is lost while navigating and the user turns it off: the manual mode at the car.
void LoseGpsAndTurnItOff(Env & env)
{
  env.m_map.m_navigating = true;
  env.DriveGps(10, 0, 10);
  env.m_clock.Advance(Engine::kGpsLostMs + 1500);
  TEST(env.m_engine.IsManualMode(), ());
  env.m_engine.SetGpsDisabled(true);
}

void DriveStandingGps(Env & env, int seconds, double northM)
{
  for (int i = 0; i < seconds; ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 90, northM, {}, 0.0));
  }
}
}  // namespace

UNIT_TEST(NoGps_Engine_GpsTurnedOnAfterAgreeingIsTrustedAtOnce)
{
  Env env(false /* inertial */);
  LoseGpsAndTurnItOff(env);
  // GPS agrees with the mark while the user ignores it: nothing follows it.
  DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 5, 0);
  TEST(env.m_engine.IsManualMode(), ());
  TEST(!env.m_delegate.HasEvent(Event::GpsBack), ());

  env.m_engine.SetGpsDisabled(false);
  DriveStandingGps(env, 1, 0);
  TEST(!env.m_engine.IsManualMode(), ());
  TEST(env.m_delegate.HasEvent(Event::GpsBack), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());
}

UNIT_TEST(NoGps_Engine_GpsTurnedOnAfterFarFromMarkIsCheckedAgain)
{
  Env env(false /* inertial */);
  LoseGpsAndTurnItOff(env);
  // GPS is far from the mark while ignored: the mark may have moved 50 m/s since it was set, 5 km is out of reach.
  DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 5, 5000);
  env.m_engine.SetGpsDisabled(false);
  DriveStandingGps(env, 1, 5000);
  TEST(env.m_engine.IsManualMode(), ());
  // It never agreed with the mark: the streak after it is turned on does not trust it.
  DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 2, 5000);
  TEST(env.m_engine.IsManualMode(), ());
  TEST(!env.m_delegate.HasEvent(Event::GpsBack), ());
}

UNIT_TEST(NoGps_Engine_GpsTurnedOnAfterGapOrSpoofingIsCheckedAgain)
{
  {
    Env env(false /* inertial */);
    LoseGpsAndTurnItOff(env);
    DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 5, 0);
    // GPS breaks off for longer than the streak allows.
    env.m_clock.Advance(GpsReturnDetector::kMaxGapMs + 1000);
    env.m_engine.SetGpsDisabled(false);
    DriveStandingGps(env, 1, 0);
    TEST(env.m_engine.IsManualMode(), ());
    DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 2, 0);
    TEST(!env.m_engine.IsManualMode(), ());
  }
  {
    Env env(false /* inertial */);
    LoseGpsAndTurnItOff(env);
    DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 5, 0);
    // A jump of a kilometer is untrusted: the streak starts again.
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 90, 1000, {}, 0.0));
    env.m_engine.SetGpsDisabled(false);
    DriveStandingGps(env, 1, 0);
    TEST(env.m_engine.IsManualMode(), ());
    DriveStandingGps(env, GpsReturnDetector::kMinStreakMs / 1000 + 2, 0);
    TEST(!env.m_engine.IsManualMode(), ());
  }
}

UNIT_TEST(NoGps_Engine_ManualModeWhenGpsIsLostWhileNavigating)
{
  Env env(false /* inertial */);
  env.m_map.m_navigating = true;
  env.DriveGps(10, 0, 10);
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());
  TEST(!env.m_engine.IsManualMode(), ());

  // GPS is jammed.
  env.m_clock.Advance(Engine::kGpsLostMs + 1500);
  TEST(env.m_engine.IsManualMode(), ());
  TEST(env.m_delegate.HasEvent(Event::GpsLost), ());
  // The car is where it was shown, on the road.
  TEST_EQUAL(env.Last().m_provider, Provider::Manual, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 90, 1);

  // GPS works again for long enough near the car.
  for (int i = 0; i < 16; ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 90, 0, {}, 0.0));
  }
  TEST(!env.m_engine.IsManualMode(), ());
  TEST(env.m_delegate.HasEvent(Event::GpsBack), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());
}

UNIT_TEST(NoGps_Engine_SeldomAccuratePositionsAreNotGpsBack)
{
  Env env(false /* inertial */);
  env.m_map.m_navigating = true;
  env.DriveGps(10, 0, 10);
  env.m_clock.Advance(Engine::kGpsLostMs + 1500);
  TEST(env.m_engine.IsManualMode(), ());

  // The fused provider repeats the Wi-Fi positions as accurate ones now and then, sometimes twice.
  auto const fused = [&env]
  {
    auto fix = GpsAt(env.m_clock, 90, 0, {}, 0.0, 3);
    fix.m_provider = Provider::Fused;
    return fix;
  };
  for (int i = 0; i < 5; ++i)
  {
    env.m_clock.Advance(6000);
    env.m_engine.OnFix(fused());
    env.m_engine.OnFix(fused());
  }
  TEST(!env.m_engine.GetStatus().m_workingGpsAccuracyM, ());
  TEST(env.m_engine.IsManualMode(), ());

  // GPS gives a position every second.
  for (int i = 0; i < 2; ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 90, 0, {}, 0.0));
  }
  auto const accuracyM = env.m_engine.GetStatus().m_workingGpsAccuracyM;
  TEST(accuracyM, ());
  TEST_EQUAL(*accuracyM, 5, ());
}

UNIT_TEST(NoGps_Engine_ManualModeWhenGpsIsSpoofed)
{
  Env env(false /* inertial */);
  env.m_map.m_navigating = true;
  Fix network = GpsAt(env.m_clock, 0, 0, {}, {}, 100);
  network.m_provider = Provider::Network;
  env.m_engine.OnFix(network);
  env.DriveGps(3, 0, 10);
  TEST(!env.m_engine.IsManualMode(), ());

  // GPS is on another continent.
  env.m_clock.Advance(1000);
  Fix spoofed = GpsAt(env.m_clock, 0, 0, 90.0, 10.0);
  spoofed.m_position = {-12.0453, -77.0569};
  env.m_engine.OnFix(spoofed);
  TEST(env.m_engine.GetStatus().m_gpsSpoofed, ());
  TEST(env.m_delegate.HasEvent(Event::GpsSpoofed), ());
  TEST(env.m_engine.IsManualMode(), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Manual, ());
}

UNIT_TEST(NoGps_Engine_ManualModeWhenGpsLeavesRoads)
{
  Env env(false /* inertial */);
  env.m_map.m_navigating = true;
  env.DriveGps(3, 0, 10);
  // A single position between the streets is noise.
  for (int i = 0; i + 1 < Engine::kOffRoadGpsCount; ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 50, 50, 90.0, 10.0));
  }
  TEST(!env.m_engine.IsManualMode(), ());
  env.m_clock.Advance(1000);
  env.m_engine.OnFix(GpsAt(env.m_clock, 50, 50, 90.0, 10.0));
  TEST(env.m_engine.IsManualMode(), ());
  // The car stays on the road where GPS was trusted the last time.
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.5);
}

UNIT_TEST(NoGps_Engine_DisabledGpsIsIgnored)
{
  Env env(false /* inertial */);
  env.m_engine.SetGpsDisabled(true);
  env.DriveGps(3, 0, 10);
  TEST(env.m_delegate.m_positions.empty(), ());
  // The user still sees whether GPS works.
  TEST(env.m_engine.GetStatus().m_workingGpsAccuracyM, ());

  env.m_engine.SetGpsDisabled(false);
  TEST(env.m_engine.GetStatus().m_workingGpsAccuracyM, ());
}

UNIT_TEST(NoGps_Engine_ForgettingTheBoxReturnsGps)
{
  Env env(true /* inertial */);
  env.m_engine.SetGpsDisabled(true);
  env.m_engine.SetInertialNavigationEnabled(false);
  TEST(!env.m_engine.GetStatus().m_gpsDisabled, ());
  env.DriveGps(3, 0, 10);
  TEST(!env.m_delegate.m_positions.empty(), ());
}

UNIT_TEST(NoGps_Engine_SavesSearchedBoxOnceHeard)
{
  Env env(false /* inertial */);
  env.m_engine.SetInertialNavigationEnabled(true);
  TEST(env.m_engine.GetStatus().m_inertialEnabled, ());
  // The app closed now starts without a box.
  TEST(!env.m_storage.IsInertialEnabled(), ());

  env.ConnectBox();
  TEST(!env.m_storage.IsInertialEnabled(), ());
  env.Drive(100, 0, 0);
  TEST(env.m_storage.IsInertialEnabled(), ());
}

UNIT_TEST(NoGps_Engine_BoxSetUpAtMarkDrivesFromIt)
{
  // The car is marked before the box is set up, no GPS comes.
  Env env(false /* inertial */);
  env.m_engine.SetManualMode(true);
  TEST(env.m_engine.PlaceMarkByTap(At(60, 3)), ());

  env.m_engine.SetInertialNavigationEnabled(true);
  env.ConnectBox();
  env.Drive(500, 0, 0);
  env.Drive(3000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Inertial, ());
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 1);
  TEST_GREATER(East(env.Last().m_position), 85, ());
}

UNIT_TEST(NoGps_Engine_SearchedBoxIsForgotten)
{
  Env env(false /* inertial */);
  env.m_engine.SetInertialNavigationEnabled(true);
  env.m_engine.SetInertialNavigationEnabled(false);
  TEST(!env.m_engine.GetStatus().m_inertialEnabled, ());
  env.Drive(100, 0, 0);
  TEST(!env.m_storage.IsInertialEnabled(), ());
}

UNIT_TEST(NoGps_GpsStateGood)
{
  Env env(false /* inertial */);
  env.DriveGps(3, 0, 10);
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Good, ());

  // GPS ignored by the user tells how it works.
  env.m_engine.SetGpsDisabled(true);
  env.DriveGps(3, 30, 10);
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Good, ());
}

UNIT_TEST(NoGps_GpsStateCoarse)
{
  Env env(false /* inertial */);
  env.m_clock.Advance(Engine::kGpsFirstFixMs + 1);
  for (int i = 0; i < 3; ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, i * 10, 0, 90.0, 10.0, Engine::kGpsMaxAccuracyM + 5));
  }
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Coarse, ());

  // Only cell towers and Wi-Fi.
  env.m_clock.Advance(Engine::kGpsLostMs + 1);
  Fix network = GpsAt(env.m_clock, 20, 0, {}, {}, 100);
  network.m_provider = Provider::Network;
  env.m_engine.OnFix(network);
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Coarse, ());
}

UNIT_TEST(NoGps_GpsStateSpoofed)
{
  Env env(false /* inertial */);
  Fix network = GpsAt(env.m_clock, 0, 0, {}, {}, 100);
  network.m_provider = Provider::Network;
  env.m_engine.OnFix(network);
  env.DriveGps(3, 0, 10);

  // GPS is on another continent.
  env.m_clock.Advance(1000);
  Fix spoofed = GpsAt(env.m_clock, 0, 0, 90.0, 10.0);
  spoofed.m_position = {-12.0453, -77.0569};
  env.m_engine.OnFix(spoofed);
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Spoofed, ());
}

UNIT_TEST(NoGps_GpsStateChecking)
{
  {
    // The satellites are searched after the start.
    Env env(false /* inertial */);
    TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Checking, ());
    // The first positions are not accurate yet.
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 0, 0, {}, {}, Engine::kGpsMaxAccuracyM + 5));
    TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Checking, ());
    env.m_clock.Advance(Engine::kGpsFirstFixMs - 1000 + 1);
    TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::None, ());
  }

  Env env(false /* inertial */);
  env.m_map.m_navigating = true;
  Fix network = GpsAt(env.m_clock, 0, 0, {}, {}, 100);
  network.m_provider = Provider::Network;
  env.m_engine.OnFix(network);
  env.DriveGps(3, 0, 10);
  env.m_clock.Advance(1000);
  Fix spoofed = GpsAt(env.m_clock, 0, 0, 90.0, 10.0);
  spoofed.m_position = {-12.0453, -77.0569};
  env.m_engine.OnFix(spoofed);
  TEST(env.m_engine.IsManualMode(), ());

  // GPS is good again where the car stands, but is trusted only after GpsReturnDetector::kMinStreakMs.
  for (int i = 0; i < GpsSpoofingDetector::kConsistentPositionsToRecover + 2; ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 20, 0, {}, 0.0));
  }
  TEST(env.m_engine.IsManualMode(), ());
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Checking, ());

  for (int i = 0; i < 16 && env.m_engine.IsManualMode(); ++i)
  {
    env.m_clock.Advance(1000);
    env.m_engine.OnFix(GpsAt(env.m_clock, 20, 0, {}, 0.0));
  }
  TEST(!env.m_engine.IsManualMode(), ());
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Good, ());
}

UNIT_TEST(NoGps_GpsStateNone)
{
  Env env(false /* inertial */);
  env.DriveGps(3, 0, 10);
  env.m_clock.Advance(Engine::kGpsLostMs - 500);
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::Good, ());
  env.m_clock.Advance(Engine::kGpsFirstFixMs);
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::None, ());

  env.m_engine.Stop();
  TEST_EQUAL(env.m_engine.GetStatus().m_gpsState, GpsState::None, ());
}

UNIT_TEST(NoGps_LastGoodGpsAge)
{
  Env env(false /* inertial */);
  TEST_EQUAL(env.m_engine.GetStatus().m_lastGoodGpsAgeMs, -1, ());
  env.DriveGps(3, 0, 10);
  TEST_EQUAL(env.m_engine.GetStatus().m_lastGoodGpsAgeMs, 0, ());

  // A coarse position is not a good one.
  env.m_clock.Advance(1000);
  env.m_engine.OnFix(GpsAt(env.m_clock, 30, 0, 90.0, 10.0, Engine::kGpsMaxAccuracyM + 5));
  env.m_clock.Advance(Engine::kGpsLostMs);
  TEST_EQUAL(env.m_engine.GetStatus().m_lastGoodGpsAgeMs, Engine::kGpsLostMs + 1000, ());
}

UNIT_TEST(NoGps_Engine_InertialContinuesWhenGpsIsLost)
{
  Env env(true /* inertial */);
  // GPS gives the position and the heading while the box tells the speed.
  for (int i = 0; i < 5; ++i)
  {
    env.Drive(1000, 36, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 10 * i, 0, 90.0, 10.0));
  }
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());
  // GPS is lost: the manual mode is turned on by itself and the car is followed by the inertial navigation.
  env.Drive(Engine::kGpsLostMs + 2000, 36, 0);
  TEST(env.m_engine.IsManualMode(), ());
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Inertial, ());
  TEST_GREATER(East(env.Last().m_position), 90, ());
  TestAlmostEqualAbs(North(env.Last().m_position), 0, 1);
}

// The time of GPS is ahead of the clock of the phone, and a GPS position comes a bit after it is taken.
int64_t constexpr kGpsClockAheadMs = 3000;
int64_t constexpr kGpsDelayMs = 100;

// GPS positions once a second going east along the street at 10 m/s, from 0 m: the car drives by the box too if
// |box|. \returns the last one.
Fix DriveWithGps(Env & env, int seconds, bool box)
{
  Fix gps;
  for (int i = 0; i < seconds; ++i)
  {
    if (box)
      env.Drive(1000, 36, 0);
    else
      env.m_clock.Advance(1000);
    gps = GpsAt(env.m_clock, 10 * i, 0, 90.0, 10.0);
    gps.m_timeMs -= kGpsDelayMs;
    gps.m_unixTimeMs += kGpsClockAheadMs - kGpsDelayMs;
    env.m_engine.OnFix(gps);
  }
  TEST_EQUAL(env.Last().m_provider, gps.m_provider, ());
  return gps;
}

UNIT_TEST(NoGps_Engine_InertialMovesMarkBetweenGpsPositions)
{
  Env env(true /* inertial */);
  Fix const gps = DriveWithGps(env, 3, true /* box */);

  // GPS gives a position once a second, the map would move the mark in jumps: the inertial navigation moves it on
  // from the GPS position since it came every 200 ms, by the clock of GPS.
  int64_t const cameMs = env.m_clock.NowMs();
  size_t const shown = env.m_delegate.m_positions.size();
  env.Drive(1000, 36, 0);
  TEST_EQUAL(env.m_delegate.m_positions.size(), shown + 5, ());
  for (size_t i = shown; i < env.m_delegate.m_positions.size(); ++i)
  {
    auto const & position = env.m_delegate.m_positions[i];
    int64_t const sinceGpsMs = position.m_timeMs - cameMs;
    TEST_EQUAL(position.m_provider, Provider::Inertial, ());
    TestAlmostEqualAbs(position.m_accuracyM,
                       gps.m_accuracyM + DeadReckoning::kAccuracyPerMeter * 10 * sinceGpsMs / 1000.0, 0.01);
    TEST_EQUAL(position.m_unixTimeMs, gps.m_unixTimeMs + sinceGpsMs, ());
    TestAlmostEqualAbs(East(position.m_position), East(gps.m_position) + 10 * sinceGpsMs / 1000.0, 0.5);
    TestAlmostEqualAbs(North(position.m_position), 0, 0.5);
  }
  // The trip log counts them.
  size_t const before = env.m_delegate.m_positions.size();
  for (int i = 0; i < 20 && env.m_delegate.m_positions.size() == before; ++i)
    env.Drive(20, 36, 0);
  TEST_GREATER(env.m_delegate.m_positions.size(), before, ());
  TEST_GREATER(std::stoi(TripField(env, "fill")), 0, ());
  // GPS stays the position of the engine.
  TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Gps, ());
  TEST(!env.m_engine.IsManualMode(), ());

  // The next GPS position puts the mark where it is.
  env.Drive(100, 36, 0);
  env.m_engine.OnFix(GpsAt(env.m_clock, 32, 0, 90.0, 10.0));
  TEST_EQUAL(env.Last().m_provider, Provider::Gps, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 32, 0.1);

  // The bearing of a slow car is noise, the inertial navigation may go another way: GPS alone moves the mark.
  env.Drive(1000, 7, 0);
  env.m_engine.OnFix(GpsAt(env.m_clock, 34, 0, 90.0, 2.0));
  size_t const slow = env.m_delegate.m_positions.size();
  env.Drive(600, 7, 0);
  TEST_EQUAL(env.m_delegate.m_positions.size(), slow, ());
}

UNIT_TEST(NoGps_Engine_PotholeWithGpsIsWhereTheMarkIsShown)
{
  Env env(true /* inertial */);
  DriveWithGps(env, 3, true /* box */);
  // GPS comes once a second: the hole is where the mark is shown between its positions, not at the last one.
  env.Drive(600, 36, 0);
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  env.Jolt(36, 9);
  double const shownAt = East(env.Last().m_position);
  env.Drive(1000, 36, 0);
  TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Gps, ());
  auto const & potholes = env.m_engine.GetPotholes();
  TEST_EQUAL(potholes.size(), 1, ());
  TestAlmostEqualAbs(East(potholes[0].m_place), shownAt, 0.5);
}

UNIT_TEST(NoGps_Engine_InertialMovesMarkUntilGpsIsLost)
{
  for (bool switchedOff : {false, true})
  {
    Env env(true /* inertial */);
    DriveWithGps(env, 3, true /* box */);
    env.Drive(200, 36, 0);
    // GPS is lost, or switched off in the sensors sheet: the mark doesn't stand waiting for the manual mode, and
    // doesn't jump when it comes.
    if (switchedOff)
      env.m_engine.SetGpsDisabled(true);
    double east = East(env.Last().m_position);
    for (int i = 0; i < (Engine::kGpsLostMs + 2000) / 200; ++i)
    {
      env.Drive(200, 36, 0);
      TestAlmostEqualAbs(East(env.Last().m_position) - east, 2, 1);
      east = East(env.Last().m_position);
    }
    TEST(env.m_engine.IsManualMode(), (switchedOff));
    TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Inertial, (switchedOff));
  }
}

UNIT_TEST(NoGps_Engine_GpsAloneIsShownAsItComes)
{
  // Without the inertial navigation the map moves the mark between GPS positions, see extrapolation::Extrapolator.
  Env env(false /* inertial */);
  DriveWithGps(env, 3, false /* box */);
  size_t const shown = env.m_delegate.m_positions.size();
  env.m_clock.Advance(900);
  TEST_EQUAL(env.m_delegate.m_positions.size(), shown, ());
}

UNIT_TEST(NoGps_Engine_CarOffRoadsFollowedOnRouteBetweenGpsPositions)
{
  // GPS pauses while the car turns from its street into a yard: with a route the mark follows the car, as in the
  // manual mode.
  PieceRoads roads({{-300, 0, 300, 0}}, {});
  Env env(true /* inertial */, &roads);
  env.m_map.m_navigating = true;
  for (int i = 0; i < 3; ++i)
  {
    env.Drive(1000, 18, 0);
    env.m_engine.OnFix(GpsAt(env.m_clock, 5 * i, 0, 90.0, 5.0));
  }
  env.Drive(500, 18, 180);
  env.Drive(4300, 18, 0);
  TEST(!env.m_engine.IsManualMode(), ());
  TEST(FollowedApart(env), (env.m_engine.GetTripLine()));
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  TEST_LESS(North(env.Last().m_position), -10, ());
}

UNIT_TEST(NoGps_Engine_SameGpsPositionIsShownOnce)
{
  Env env(true /* inertial */);
  Fix const gps = DriveWithGps(env, 3, true /* box */);
  int64_t const cameMs = env.m_clock.NowMs();
  // Android gives the position again, mixed with the network: a bit more accurate, sometimes a few meters off.
  size_t const shown = env.m_delegate.m_positions.size();
  auto fused = gps;
  fused.m_provider = Provider::Fused;
  fused.m_accuracyM = 4;
  fused.m_position = At(East(gps.m_position) + 5, 0);
  env.m_engine.OnFix(fused);
  TEST_EQUAL(env.m_delegate.m_positions.size(), shown, ());
  // The inertial navigation goes on from the shown GPS position.
  env.Drive(200, 36, 0);
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  TestAlmostEqualAbs(East(env.Last().m_position), East(gps.m_position) + 10 * (env.Last().m_timeMs - cameMs) / 1000.0,
                     0.5);

  env.Drive(800, 36, 0);
  fused = GpsAt(env.m_clock, 30, 0, 90.0, 10.0, 4);
  fused.m_provider = Provider::Fused;
  env.m_engine.OnFix(fused);
  TEST_EQUAL(env.Last().m_provider, Provider::Fused, ());
  TestAlmostEqualAbs(East(env.Last().m_position), 30, 0.1);
}

UNIT_TEST(NoGps_Engine_CopyOfRejectedGpsPositionIsTaken)
{
  Env env(true /* inertial */);
  DriveWithGps(env, 3, true /* box */);
  // The satellites alone put the car between the streets for seconds, their mix with the network keeps it on its
  // street.
  for (int i = 0; i <= Engine::kOffRoadGpsCount; ++i)
  {
    env.Drive(1000, 36, 0);
    auto const satellites = GpsAt(env.m_clock, 30 + 10 * i, 50, 90.0, 10.0);
    env.m_engine.OnFix(satellites);
    auto fused = satellites;
    fused.m_provider = Provider::Fused;
    fused.m_position = At(30 + 10 * i, 0);
    env.m_engine.OnFix(fused);
    TEST_EQUAL(env.Last().m_provider, Provider::Fused, (i));
    TestAlmostEqualAbs(North(env.Last().m_position), 0, 0.1);
  }
  TEST(!env.m_engine.IsManualMode(), ());
}

// The car speeds up to 54 km/h in 10 s, drives 5 s, brakes in 10 s and stands 5 s, again and again, going east
// along the street. The box reports the car speed 1.2 s late. Returns how far the calculated position was from the
// car at most 1.5-3 s after the car started to speed up or to brake, when the box has been learned.
double DriveWithLateSpeed(bool accelerometer)
{
  double constexpr kLagSec = 1.2;
  double constexpr kCycleSec = 30;
  auto const acceleration = [](double timeSec)
  {
    double const t = std::fmod(timeSec, kCycleSec);
    return t < 10 ? 1.5 : t >= 15 && t < 25 ? -1.5 : 0.0;
  };

  Env env(true /* inertial */);
  MarkCar(env, -450);
  int64_t seq = 1000;
  int64_t boxTimeMs = 200'000;
  double speed = 0;
  double east = -450;
  // The speeds of the car of the last seconds.
  std::deque<double> speeds(static_cast<size_t>(kLagSec / 0.02), 0.0);
  double maxError = 0;
  for (int step = 0; step < 4 * kCycleSec * 50; ++step)
  {
    double const t = step * 0.02;
    double const a = acceleration(t);
    east += speed * 0.02 + a * 0.02 * 0.02 / 2;
    speed = std::max(0.0, speed + a * 0.02);
    speeds.push_back(speed);
    int const reportedKmh = static_cast<int>(std::lround(speeds.front() * 3.6));
    speeds.pop_front();

    env.m_clock.Advance(20);
    boxTimeMs += 20;
    char body[160];
    if (accelerometer)
    {
      // The box looks forward with its first horizontal axis, a little of the gravity is left in the others.
      std::snprintf(body, sizeof(body), "NGD,1,%lld,%lld,0,0,0,%d,0,%X,%d,50,-60,100", static_cast<long long>(++seq),
                    static_cast<long long>(boxTimeMs), reportedKmh, kCalibratedFlags, static_cast<int>(a * 1000));
    }
    else
    {
      std::snprintf(body, sizeof(body), "NGD,1,%lld,%lld,0,0,0,%d,0,%X", static_cast<long long>(++seq),
                    static_cast<long long>(boxTimeMs), reportedKmh, kCalibratedFlags);
    }
    size_t const positions = env.m_delegate.m_positions.size();
    env.m_engine.OnEsp32BleBytes(BoxLine(body));
    // The third and the fourth time the car speeds up and brakes.
    double const inCycle = std::fmod(t, kCycleSec);
    bool const changing = (inCycle >= 1.5 && inCycle < 3) || (inCycle >= 16.5 && inCycle < 18);
    if (t >= 2 * kCycleSec && changing && env.m_delegate.m_positions.size() > positions)
      maxError = std::max(maxError, std::fabs(East(env.Last().m_position) - east));
  }
  TEST_EQUAL(env.Last().m_provider, Provider::Inertial, ());
  TEST_EQUAL(env.m_engine.GetStatus().m_source, PositionSource::Inertial, ());
  return maxError;
}

// The ECU of a car that wakes answers 255 km/h, the top of the byte, before it has a speed.
UNIT_TEST(NoGps_Engine_ObdSpeed255AfterWakeDoesNotMoveMark)
{
  PieceRoads roads({{-2000, 0, 3000, 0}}, {});
  Env env(true /* inertial */, &roads);
  MarkCar(env, -450);
  BoxCar car(env, -450, false /* accelerometer */);
  car.Drive(5, 0, 0);
  double const east = East(env.Last().m_position);
  int64_t seq = 5000;
  int64_t boxTimeMs = 400'000;
  // The standing car says 255 for 10 s, then its real speed: 0.
  for (int step = 0; step < 10 * 50; ++step)
  {
    env.m_clock.Advance(20);
    boxTimeMs += 20;
    char body[160];
    std::snprintf(body, sizeof(body), "NGD,1,%lld,%lld,0,0,0,255,0,%X", static_cast<long long>(++seq),
                  static_cast<long long>(boxTimeMs), kCalibratedFlags);
    env.m_engine.OnEsp32BleBytes(BoxLine(body));
  }
  TestAlmostEqualAbs(East(env.Last().m_position), east, 2);
}

UNIT_TEST(NoGps_Engine_ObdSpeed255AfterWakeIsNoPothole)
{
  Env env(true /* inertial */);
  MarkCar(env, 50);
  env.Drive(2000, 0, 0);
  // A door slam while the ECU says 255.
  env.Jolt(255, 12);
  env.Drive(1500, 0, 0);
  TEST(env.m_engine.GetPotholes().empty(), ());
}

UNIT_TEST(NoGps_Engine_BoxAccelerometerTellsSpeedBeforeCar)
{
  // The car reports the new speed late. The distance it has driven meanwhile is added when it does, so the
  // position is right in the end, but it is behind while the car speeds up and ahead while it brakes.
  double const bySpeed = DriveWithLateSpeed(false /* accelerometer */);
  // The accelerometer of the box feels the change at once.
  double const byAccel = DriveWithLateSpeed(true /* accelerometer */);
  LOG(LWARNING, ("The largest error by the car speed", bySpeed, "m, with the accelerometer", byAccel, "m"));
  TEST_GREATER(bySpeed, 0.8, ());
  TEST_LESS(bySpeed, 3, ());
  TEST_LESS(byAccel, bySpeed / 2, ());
}

// The grid of streets with the features of the map: the streets going east are the feature 1, going north 2. The car
// goes the way of the points of a feature going east or north.
class FeatureGridRoads : public GridRoads
{
public:
  static uint32_t constexpr kEastStreet = 1;

  std::optional<RoadPoint> Snap(ms::LatLon const & point, std::optional<double> bearingDeg, double radiusM) override
  {
    auto road = GridRoads::Snap(point, bearingDeg, radiusM);
    if (!road)
      return {};
    road->m_featureId = FeatureID(MwmSet::MwmId(), road->m_bearingDeg == 90 ? kEastStreet : 2);
    road->m_forward = !bearingDeg || std::cos(math::DegToRad(*bearingDeg - road->m_bearingDeg)) >= 0;
    return road;
  }
};

struct SpeedLimitEnv
{
  SpeedLimitEnv() : m_env(false /* inertial */, &m_roads) {}

  int MarkAndGetLimit()
  {
    MarkCar(m_env, 60);
    return m_env.m_engine.GetStatus().m_speedLimitKmh;
  }

  FeatureGridRoads m_roads;
  Env m_env;
};

UNIT_TEST(NoGps_SpeedLimitForward)
{
  SpeedLimitEnv env;
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 50, 30);
  TEST_EQUAL(env.MarkAndGetLimit(), 50, ());
  // The limit of a road in miles per hour is told in kilometers per hour.
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Imperial, 30, routing::kInvalidSpeed);
  env.m_env.m_engine.ShiftPosition(10);
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, 48, ());
}

UNIT_TEST(NoGps_SpeedLimitBackward)
{
  SpeedLimitEnv env;
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 50, 30);
  TEST_EQUAL(env.MarkAndGetLimit(), 50, ());
  env.m_env.m_engine.ReverseDirection();
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, 30, ());
  // A road with one limit has it both ways.
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 40, routing::kInvalidSpeed);
  env.m_env.m_engine.ShiftPosition(10);
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, 40, ());
}

UNIT_TEST(NoGps_SpeedLimitNone)
{
  SpeedLimitEnv env;
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, routing::kNoneMaxSpeed, routing::kInvalidSpeed);
  TEST_EQUAL(env.MarkAndGetLimit(), 0, ());
}

UNIT_TEST(NoGps_SpeedLimitUnknown)
{
  SpeedLimitEnv env;
  // The map has a limit of another road only.
  env.m_env.m_map.m_maxspeeds[2] = routing::Maxspeed(measurement_utils::Units::Metric, 50, routing::kInvalidSpeed);
  TEST_EQUAL(env.MarkAndGetLimit(), -1, ());
  // Without a position there is no limit either.
  NewUser user;
  TEST_EQUAL(user.Start().m_speedLimitKmh, -1, ());
}

UNIT_TEST(NoGps_SpeedLimitWithoutRoad)
{
  SpeedLimitEnv env;
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 50, routing::kInvalidSpeed);
  // GPS between the streets, farther from them than Engine::kSpeedLimitRoadM.
  env.m_env.m_clock.Advance(1000);
  env.m_env.m_engine.OnFix(GpsAt(env.m_env.m_clock, 50, 50, 90.0, 10.0));
  auto status = env.m_env.m_engine.GetStatus();
  TEST_EQUAL(status.m_source, PositionSource::Gps, ());
  TEST_EQUAL(status.m_speedLimitKmh, -1, ());
  // On the street.
  env.m_env.m_clock.Advance(1000);
  env.m_env.m_engine.OnFix(GpsAt(env.m_env.m_clock, 60, 8, 90.0, 10.0));
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, 50, ());
}

UNIT_TEST(NoGps_SpeedLimitWithoutDirection)
{
  SpeedLimitEnv env;
  // A standing car: GPS without a bearing.
  env.m_env.m_clock.Advance(1000);
  env.m_env.m_engine.OnFix(GpsAt(env.m_env.m_clock, 60, 3));
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 50, 30);
  // The two ways have different limits: which one is not known.
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, -1, ());
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 50, routing::kInvalidSpeed);
  env.m_env.m_clock.Advance(1000);
  env.m_env.m_engine.OnFix(GpsAt(env.m_env.m_clock, 61, 3));
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, 50, ());
}

UNIT_TEST(NoGps_SpeedLimitRoadFoundLater)
{
  // The map of the place comes while the car stands there.
  PieceRoads none({}, {});
  SpeedLimitEnv env;
  env.m_env.m_map.m_maxspeeds[FeatureGridRoads::kEastStreet] =
      routing::Maxspeed(measurement_utils::Units::Metric, 50, routing::kInvalidSpeed);
  env.m_env.m_map.m_roads = &none;
  env.m_env.m_clock.Advance(1000);
  env.m_env.m_engine.OnFix(GpsAt(env.m_env.m_clock, 60, 3, 90.0, 10.0));
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, -1, ());
  env.m_env.m_map.m_roads = &env.m_roads;
  TEST_EQUAL(env.m_env.m_engine.GetStatus().m_speedLimitKmh, 50, ());
}

/// Two phones on one box that passes their places on: the first one leads, the second follows. The box sends the same
/// lines to both, and tells each the places the other one has sent.
class TwoPhones
{
public:
  explicit TwoPhones(bool peerAbility = true, bool leaderGpsBox = false)
  {
    std::string const abilities = peerAbility ? "BLE OTA CAR PHONES MULTI PEER" : "BLE OTA CAR PHONES MULTI";
    std::string const info =
        "NGI,1,0.4.3,2026-11-18T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID," + abilities + ",3";
    for (auto * env : {&m_leader, &m_follower})
      env->m_engine.OnEsp32BleBytes(BoxLine(info));
    Drive(1000, 0, 0);
    AnswerList(m_leader, "Pixel 8", "iPhone", true);
    AnswerList(m_follower, "Pixel 8", "iPhone", false);
  }

  /// The box lists its phones, the first one changes it.
  void AnswerList(Env & env, std::string const & first, std::string const & second, bool changesBox)
  {
    auto const & sent = env.m_delegate.m_esp32BleSent;
    auto const list = std::find_if(sent.rbegin(), sent.rend(),
                                   [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
    TEST(list != sent.rend(), ());
    auto const id = (*esp32::Parse(*list))[1];
    // This phone is the one that has asked.
    std::string const phones = "BC:D0:74:A9:71:92|" + first + "|1794685760|" + (changesBox ? "1" : "0") +
                               ";BC:D0:74:A9:71:93|" + second + "|1794685761|" + (changesBox ? "0" : "1");
    env.m_engine.OnEsp32BleBytes(BoxLine("NGA," + id + ",OK," + phones + "," + (changesBox ? "1" : "0")));
  }

  /// The box counts the same for both phones, the places go between them.
  void Drive(int64_t ms, int speedKmh, double yawRateDegS)
  {
    for (int64_t t = 0; t < ms; t += 20)
    {
      m_leader.Drive(20, speedKmh, yawRateDegS);
      m_follower.Drive(20, speedKmh, yawRateDegS);
      Relay();
    }
  }

  /// Passes on what the phones have sent to the box with PEER since the last time.
  void Relay()
  {
    Relay(m_leader, m_follower, m_leaderRelayed);
    Relay(m_follower, m_leader, m_followerRelayed);
  }

  /// What the phone has sent with PEER: the payload.
  static std::vector<std::string> Sent(Env const & env)
  {
    std::vector<std::string> payloads;
    for (auto const & line : env.m_delegate.m_esp32BleSent)
    {
      auto const fields = esp32::Parse(line);
      if (!fields || fields->size() < 4 || (*fields)[2] != "PEER")
        continue;
      std::string payload = (*fields)[3];
      for (size_t i = 4; i < fields->size(); ++i)
        payload += "," + (*fields)[i];
      payloads.push_back(payload);
    }
    return payloads;
  }

  static size_t CountSent(Env const & env, char kind)
  {
    auto const sent = Sent(env);
    return std::count_if(sent.begin(), sent.end(), [kind](auto const & payload) { return payload[0] == kind; });
  }

  Env m_leader{true /* inertial */};
  Env m_follower{true /* inertial */};

private:
  static void Relay(Env & from, Env & to, size_t & done)
  {
    auto const & sent = from.m_delegate.m_esp32BleSent;
    while (done < sent.size())
    {
      auto const fields = esp32::Parse(sent[done++]);
      if (!fields || fields->size() < 4 || (*fields)[2] != "PEER")
        continue;
      std::string line = "NGX,1";
      for (size_t i = 3; i < fields->size(); ++i)
        line += "," + (*fields)[i];
      to.m_engine.OnEsp32BleBytes(BoxLine(line));
    }
  }

  size_t m_leaderRelayed = 0;
  size_t m_followerRelayed = 0;
};

UNIT_TEST(NoGps_Engine_PeerRolesFollowTheBox)
{
  TwoPhones phones;
  auto const leader = phones.m_leader.m_engine.GetStatus();
  TEST_EQUAL(leader.m_peerRole, PeerRole::Leading, ());
  auto const follower = phones.m_follower.m_engine.GetStatus();
  TEST_EQUAL(follower.m_peerRole, PeerRole::Following, ());
  TEST_EQUAL(follower.m_peerName, "Pixel 8", ());
  TEST(leader.m_peerName.empty(), ());

  // The leader leaves: the box tells the follower that it changes the box now, the list has one phone more.
  phones.Drive(Esp32Source::kListIntervalMs, 0, 0);
  phones.m_follower.m_engine.OnEsp32BleBytes(BoxLine("NGE,1,5,100,I,PHONE_LOST,BC:D0:74:A9:71:92"));
  phones.AnswerList(phones.m_follower, "Pixel 8", "iPhone", true);
  TEST_EQUAL(phones.m_follower.m_engine.GetStatus().m_peerRole, PeerRole::Leading, ());
}

UNIT_TEST(NoGps_Engine_PeerNothingWithoutAbility)
{
  // One of the phones is alone, or the box doesn't pass the places on: as before.
  TwoPhones phones(false /* peerAbility */);
  TEST_EQUAL(phones.m_leader.m_engine.GetStatus().m_peerRole, PeerRole::None, ());
  TEST_EQUAL(phones.m_follower.m_engine.GetStatus().m_peerRole, PeerRole::None, ());
  MarkCar(phones.m_leader, 50);
  phones.m_leader.Drive(2 * kPeerSnapshotIntervalMs, 0, 0);
  phones.m_follower.m_engine.PlaceMarkByTap(At(60, 3));
  TEST(TwoPhones::Sent(phones.m_leader).empty(), ());
  TEST(TwoPhones::Sent(phones.m_follower).empty(), ());

  // A phone alone on a box with the ability has nobody to tell.
  Env alone(true /* inertial */);
  alone.m_engine.OnEsp32BleBytes(BoxLine(
      "NGI,1,0.4.3,2026-11-18T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR PHONES MULTI PEER,3"));
  alone.Drive(1000, 0, 0);
  auto const sent = alone.m_delegate.m_esp32BleSent;
  auto const list = std::find_if(sent.begin(), sent.end(),
                                 [](auto const & line) { return line.find(",BT_LIST*") != std::string::npos; });
  TEST(list != sent.end(), ());
  alone.m_engine.OnEsp32BleBytes(BoxLine("NGA," + (*esp32::Parse(*list))[1] + ",OK,BC:D0:74:A9:71:92|Pixel 8|1|1,1"));
  TEST_EQUAL(alone.m_engine.GetStatus().m_peerRole, PeerRole::None, ());
  MarkCar(alone, 50);
  alone.Drive(2 * kPeerSnapshotIntervalMs, 0, 0);
  TEST(TwoPhones::Sent(alone).empty(), ());
}

UNIT_TEST(NoGps_Engine_PeerLeaderTapReachesFollower)
{
  TwoPhones phones;
  phones.m_leader.m_engine.SetManualMode(true);
  phones.Drive(500, 0, 0);
  TEST(phones.m_leader.m_engine.PlaceMarkByTap(At(150, 3)), ());
  phones.Drive(40, 0, 0);

  auto const sent = TwoPhones::Sent(phones.m_leader);
  TEST_EQUAL(sent.size(), 1, ());
  TEST_EQUAL(sent[0][0], 'A', ());
  TEST_EQUAL(sent[0].back(), 'T', ());

  // The follower had no place: the car is where the leader has put it, in the manual mode as after a tap.
  auto & follower = phones.m_follower;
  TEST(follower.m_engine.IsManualMode(), ());
  TestAlmostEqualAbs(East(follower.Last().m_position), 150, 1);
  TestAlmostEqualAbs(North(follower.Last().m_position), 0, 1);
  TEST_EQUAL(follower.Last().m_bearingDeg, 90.0, ());
  // What it has got it doesn't send on.
  TEST(TwoPhones::Sent(follower).empty(), ());
}

UNIT_TEST(NoGps_Engine_PeerAnchorIsCarriedByTheBoxOfTheFollower)
{
  TwoPhones phones;
  phones.m_leader.m_engine.SetManualMode(true);
  phones.Drive(500, 0, 0);
  TEST(phones.m_leader.m_engine.PlaceMarkByTap(At(150, 3)), ());
  // The line of the leader comes to the follower after the car has driven on for 2 s at 36 km/h: 20 m.
  auto & follower = phones.m_follower;
  follower.Drive(2000, 36, 0);
  phones.m_leader.Drive(2000, 36, 0);
  phones.Relay();
  follower.Drive(100, 36, 0);
  // The follower has driven from the place as far as the leader has: 20 m and the 1 m since the line came.
  TestAlmostEqualAbs(East(follower.Last().m_position), 171, 2);
}

UNIT_TEST(NoGps_Engine_PeerSnapshotGivesPlaceToFollowerWithout)
{
  TwoPhones phones;
  // The leader has a place and the follower joins later: it has none until a snapshot comes.
  phones.m_follower.m_engine.Stop();
  MarkCar(phones.m_leader, 200);
  phones.m_leader.Drive(500, 0, 0);
  TEST_EQUAL(TwoPhones::CountSent(phones.m_leader, 'S'), 0, ());
  phones.m_follower.m_engine.Start();
  phones.m_follower.ConnectBox();
  phones.m_follower.m_engine.OnEsp32BleBytes(BoxLine(
      "NGI,1,0.4.3,2026-11-18T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR PHONES MULTI PEER,3"));
  phones.m_follower.Drive(1000, 0, 0);
  phones.AnswerList(phones.m_follower, "Pixel 8", "iPhone", false);
  TEST(!phones.m_follower.m_engine.GetStatus().m_hasInertialPosition, ());
  size_t const before = phones.m_follower.m_delegate.m_positions.size();

  phones.Drive(kPeerSnapshotIntervalMs, 0, 0);
  TEST_GREATER_OR_EQUAL(TwoPhones::CountSent(phones.m_leader, 'S'), 1, ());
  TEST_GREATER(phones.m_follower.m_delegate.m_positions.size(), before, ());
  TestAlmostEqualAbs(East(phones.m_follower.Last().m_position), 200, 1);
}

UNIT_TEST(NoGps_Engine_PeerFollowerTapReachesLeaderAndIsAnswered)
{
  TwoPhones phones;
  auto & leader = phones.m_leader;
  auto & follower = phones.m_follower;
  MarkCar(leader, 150);
  MarkCar(follower, 150);
  phones.Drive(1000, 0, 0);
  size_t const leaderAnchors = TwoPhones::CountSent(leader, 'A');
  size_t const corrections = TwoPhones::CountSent(follower, 'C');

  TEST(follower.m_engine.PlaceMarkByTap(At(350, 3)), ());
  phones.Drive(300, 0, 0);
  // The follower has applied it at once and told the leader.
  TEST_EQUAL(TwoPhones::CountSent(follower, 'C'), corrections + 1, ());
  TestAlmostEqualAbs(East(follower.Last().m_position), 350, 1);
  // The leader has applied it and answered with an anchor.
  TestAlmostEqualAbs(East(leader.Last().m_position), 350, 1);
  TEST_EQUAL(TwoPhones::CountSent(leader, 'A'), leaderAnchors + 1, ());
  // The anchor is not a correction: the follower has not sent another one.
  TEST_EQUAL(TwoPhones::CountSent(follower, 'C'), corrections + 1, ());
  TEST_EQUAL(TwoPhones::CountSent(follower, 'A'), 0, ());
}

UNIT_TEST(NoGps_Engine_PeerReversalAndSwitchReachTheOtherPhone)
{
  TwoPhones phones;
  auto & leader = phones.m_leader;
  auto & follower = phones.m_follower;
  MarkCar(leader, 150);
  phones.Drive(1000, 0, 0);
  TestAlmostEqualAbs(East(follower.Last().m_position), 150, 1);
  TEST_EQUAL(follower.Last().m_bearingDeg, 90.0, ());

  leader.m_engine.ReverseDirection();
  phones.Drive(300, 0, 0);
  TEST_EQUAL(leader.Last().m_bearingDeg, 270.0, ());
  TEST_EQUAL(follower.Last().m_bearingDeg, 270.0, ());

  // The follower turns the car around: the leader does the same.
  follower.m_engine.ReverseDirection();
  phones.Drive(300, 0, 0);
  TEST_EQUAL(follower.Last().m_bearingDeg, 90.0, ());
  TEST_EQUAL(leader.Last().m_bearingDeg, 90.0, ());
  TEST_EQUAL(TwoPhones::CountSent(follower, 'C'), 1, ());
}

UNIT_TEST(NoGps_Engine_PeerFollowerGpsGoesToManualLeaderOnly)
{
  TwoPhones phones;
  auto & leader = phones.m_leader;
  auto & follower = phones.m_follower;
  // The leader trusts GPS: the follower keeps its GPS to itself.
  leader.DriveGps(3, 0, 10);
  follower.DriveGps(3, 0, 10);
  phones.Drive(300, 0, 0);
  TEST(!leader.m_engine.IsManualMode(), ());
  TEST_EQUAL(TwoPhones::CountSent(follower, 'G'), 0, ());
  TEST_GREATER_OR_EQUAL(TwoPhones::CountSent(leader, 'A'), 1, ());

  // The leader is in the manual mode, it tells so.
  leader.m_engine.SetManualMode(true);
  phones.Drive(500, 0, 0);
  TEST(leader.m_engine.PlaceMarkByTap(At(50, 3)), ());
  phones.Drive(300, 0, 0);
  follower.m_clock.Advance(1000);
  follower.m_engine.OnFix(GpsAt(follower.m_clock, 31, 0, 90.0, 10));
  TEST_EQUAL(TwoPhones::CountSent(follower, 'G'), 1, ());
  // A GPS position that is not good is not sent.
  follower.m_clock.Advance(1000);
  follower.m_engine.OnFix(GpsAt(follower.m_clock, 41, 0, 90.0, 10, 80 /* accuracyM */));
  TEST_EQUAL(TwoPhones::CountSent(follower, 'G'), 1, ());
  // The leader takes it as its own GPS: the checks are the same, and it is told that GPS works.
  leader.m_clock.Advance(2000);
  TEST_GREATER_OR_EQUAL(leader.m_engine.GetStatus().m_lastGoodGpsAgeMs, 2000, ());
  phones.Relay();
  TEST_LESS(leader.m_engine.GetStatus().m_lastGoodGpsAgeMs, 1000, ());
  TEST(leader.m_engine.IsManualMode(), ());
}

UNIT_TEST(NoGps_Engine_PeerFollowerKeepsItsGps)
{
  TwoPhones phones;
  auto & leader = phones.m_leader;
  auto & follower = phones.m_follower;
  leader.DriveGps(3, 0, 10);
  follower.DriveGps(5, 0, 10);
  // The snapshot of the leader does not turn the manual mode on for the follower that has GPS.
  phones.Drive(kPeerSnapshotIntervalMs, 36, 0);
  TEST_GREATER_OR_EQUAL(TwoPhones::CountSent(leader, 'S'), 1, ());
  TEST(!follower.m_engine.IsManualMode(), ());
  TEST_EQUAL(TwoPhones::CountSent(follower, 'A') + TwoPhones::CountSent(follower, 'S'), 0, ());
}

UNIT_TEST(NoGps_Engine_TripLineHasRpm)
{
  Env env(true /* inertial */);
  env.ConnectBox();
  env.Drive(2000, 36, 0);
  auto const status = [&env](std::string const & rpm)
  {
    env.m_engine.OnEsp32BleBytes(
        BoxLine("NGS,1,0.2.0,ICM20602,500,OK,,12,331,0,OK,0x12,NONE,38400,-386,9,RUN," + rpm + ",14100,,"));
    env.Drive(1000, 36, 0);
  };
  status("");
  TEST(env.m_engine.GetTripLine().find(" rpm=") == std::string::npos, (env.m_engine.GetTripLine()));
  status("2100");
  TEST_EQUAL(TripField(env, "rpm"), "2100", ());
  // The status without the rpm: it is not kept from the previous one.
  status("");
  TEST(env.m_engine.GetTripLine().find(" rpm=") == std::string::npos, (env.m_engine.GetTripLine()));
}

namespace sprint
{
/// From a standstill the car speed rises evenly by 100 km/h in |to100Sec| up to |topKmh|, stays there 2 s, and the car
/// stops.
void Run(Env & env, double to100Sec, int topKmh)
{
  env.Drive(2000, 0, 0);
  for (int i = 1;; ++i)
  {
    int const kmh = std::min(topKmh, static_cast<int>(std::lround(100 * i / 10.0 / to100Sec)));
    env.Drive(100, kmh, 0);
    if (kmh == topKmh)
      break;
  }
  env.Drive(2000, topKmh, 0);
  env.Drive(3000, 0, 0);
}
}  // namespace sprint

UNIT_TEST(NoGps_Sprint_RecordsKeptForEachCar)
{
  Env env(true /* inertial */);
  HearBox(env, "C47D");
  TEST(env.m_engine.GetSprints().empty(), ());

  // The first result of the car is a record, with nothing before it.
  sprint::Run(env, 9, 105);
  TEST_EQUAL(CountEvents(env, Event::SprintMeasured), 1, ());
  auto status = env.m_engine.GetStatus();
  TEST_EQUAL(status.m_sprintKind, SprintKind::To100, ());
  TestAlmostEqualAbs(status.m_sprintSec, 9, 0.15);
  TEST(status.m_sprintRecord, ());
  TEST_EQUAL(status.m_sprintBestSec, 0, ());

  // Slower: not a record.
  sprint::Run(env, 10, 105);
  TEST_EQUAL(CountEvents(env, Event::SprintMeasured), 2, ());
  status = env.m_engine.GetStatus();
  TestAlmostEqualAbs(status.m_sprintSec, 10, 0.15);
  TEST(!status.m_sprintRecord, ());
  TestAlmostEqualAbs(status.m_sprintBestSec, 9, 0.15);

  sprint::Run(env, 8, 105);
  status = env.m_engine.GetStatus();
  TEST(status.m_sprintRecord, ());
  TestAlmostEqualAbs(status.m_sprintBestSec, 9, 0.15);
  auto sprints = env.m_engine.GetSprints();
  TEST_EQUAL(sprints.size(), 3, ());
  // Newest first.
  TestAlmostEqualAbs(sprints[0].m_sec, 8, 0.15);
  TestAlmostEqualAbs(sprints[2].m_sec, 9, 0.15);
  TEST_GREATER(sprints[0].m_unixTimeMs, sprints[1].m_unixTimeMs, ());
  TEST_LESS(env.m_clock.UnixNowMs() - sprints[0].m_unixTimeMs, 6000, ());

  // Another car has its own.
  HearBox(env, "42FD");
  TEST(env.m_engine.GetSprints().empty(), ());
  sprint::Run(env, 12, 105);
  status = env.m_engine.GetStatus();
  TEST(status.m_sprintRecord, ());
  TEST_EQUAL(status.m_sprintBestSec, 0, ());
  TEST_EQUAL(env.m_engine.GetSprints().size(), 1, ());

  // They are kept after a restart, and not on the box.
  Env after(true /* inertial */, nullptr, SavedBy(env));
  TEST_EQUAL(after.m_engine.GetSprints().size(), 1, ());
  HearBox(after, "C47D");
  sprints = after.m_engine.GetSprints();
  TEST_EQUAL(sprints.size(), 3, ());
  TestAlmostEqualAbs(sprints[0].m_sec, 8, 0.15);
  TEST(std::find(CarStorage::kValuesOnBox.begin(), CarStorage::kValuesOnBox.end(), Storage::kSprints) ==
           CarStorage::kValuesOnBox.end(),
       ());
}

UNIT_TEST(NoGps_Sprints_PerCar)
{
  Env env(true /* inertial */);
  HearBox(env, "C47D");
  sprint::Run(env, 9, 105);
  sprint::Run(env, 8, 105);
  HearBox(env, "42FD");
  sprint::Run(env, 12, 105);

  auto const a = env.m_engine.GetSprints("C47D");
  TEST_EQUAL(a.size(), 2, ());
  TestAlmostEqualAbs(a[0].m_sec, 8, 0.15);
  TestAlmostEqualAbs(a[1].m_sec, 9, 0.15);
  auto const b = env.m_engine.GetSprints("42FD");
  TEST_EQUAL(b.size(), 1, ());
  TestAlmostEqualAbs(b[0].m_sec, 12, 0.15);
  TEST(env.m_engine.GetSprints("0000").empty(), ());

  // The current car's runs are the same as by its id, and the other car keeps its own.
  env.m_engine.SelectCar("C47D");
  TEST_EQUAL(env.m_engine.GetSprints().size(), 2, ());
  TEST_EQUAL(env.m_engine.GetSprints("42FD").size(), 1, ());
}

UNIT_TEST(NoGps_Sprint_SpeedTableApplied)
{
  // The speedometer shows 95 km/h at the real 104.5.
  Env slow(true /* inertial */);
  sprint::Run(slow, 10, 95);
  TEST(!slow.m_delegate.HasEvent(Event::SprintMeasured), ());

  Env env(true /* inertial */, nullptr, [](TestStorage & storage) { storage.Set(Storage::kSpeedScale, 1.1); });
  sprint::Run(env, 10, 95);
  TEST_EQUAL(CountEvents(env, Event::SprintMeasured), 1, ());
  // The real 100 km/h is 91 km/h by the car.
  TestAlmostEqualAbs(env.m_engine.GetStatus().m_sprintSec, 9.1, 0.15);
}

/// Keeps all the messages of the log while it lives and passes them on.
class LoggedLines
{
public:
  LoggedLines()
  {
    s_lines.clear();
    s_saved = base::SetLogMessageFn(&Keep);
  }
  ~LoggedLines() { base::SetLogMessageFn(s_saved); }

  /// \returns the messages that start with the prefix.
  static std::vector<std::string> Starting(std::string const & prefix)
  {
    std::vector<std::string> found;
    for (auto const & line : s_lines)
      if (line.starts_with(prefix))
        found.push_back(line);
    return found;
  }

private:
  static void Keep(base::LogLevel level, base::SrcPoint const & src, std::string const & message)
  {
    s_lines.push_back(message);
    s_saved(level, src, message);
  }

  static inline std::vector<std::string> s_lines;
  static inline base::LogMessageFn s_saved = nullptr;
};

UNIT_TEST(NoGps_LogFormat_MapsVersionIsWrittenAtStartAndAtNewFile)
{
  TestClock clock;
  TestStorage storage;
  TestDelegate delegate;
  TestMap map;
  map.m_mapsVersion = "261101,260714";
  storage.Set(Storage::kInertialEnabled, true);
  Engine engine(delegate, map, storage, clock, clock);
  LoggedLines lines;
  engine.Start();
  auto const prefix = "MAPS ms=" + std::to_string(clock.UnixNowMs()) + " version=261101,260714";
  TEST_EQUAL(LoggedLines::Starting(prefix).size(), 1, ());
  TEST_EQUAL(LoggedLines::Starting("ACTION start ms=" + std::to_string(clock.UnixNowMs())).size(), 1, ());

  clock.Advance(Engine::kTripFileLinkGapMs);
  engine.OnEsp32BleState(BleState::Connected);
  // The new file has its own line, with the time of that moment.
  TEST_EQUAL(LoggedLines::Starting("MAPS ms=" + std::to_string(clock.UnixNowMs()) + " version=261101,260714").size(), 1,
             ());
}

UNIT_TEST(NoGps_LogFormat_SwitchesOfTheUserAreActions)
{
  Env env(true /* inertial */);
  LoggedLines lines;
  env.m_engine.SetGpsDisabled(true);
  auto const gps = LoggedLines::Starting("ACTION gps_off ms=");
  TEST_EQUAL(gps.size(), 1, ());
  TEST(gps[0].find(" disabled=1 by=user ") != std::string::npos, (gps[0]));
  env.m_engine.SetManualMode(true);
  auto const manual = LoggedLines::Starting("ACTION manual ms=");
  TEST_EQUAL(manual.size(), 1, ());
  TEST(manual[0].find(" enabled=1 by=user ") != std::string::npos, (manual[0]));
}

UNIT_TEST(NoGps_LogFormat_TheMarkTellsWhoPlacedIt)
{
  Env env(false /* inertial */);
  LoggedLines lines;
  MarkCar(env, 0);
  auto const tapped = LoggedLines::Starting("ACTION tap ms=");
  TEST_EQUAL(tapped.size(), 1, ());
  TEST(tapped[0].find(" by=tap ") != std::string::npos, (tapped[0]));
  // The manual mode is already on, so no "ACTION manual" line follows: the by= of the mark is the only thing that
  // tells the GPS tap of the road lost panel from a tap of the user on the map.
  TEST(PlaceByGpsFix(env, 60, 3, 4), ());
  auto const marks = LoggedLines::Starting("ACTION tap ms=");
  TEST_EQUAL(marks.size(), 2, ());
  TEST(marks[1].find(" by=gps_mark ") != std::string::npos, (marks[1]));
  TEST_EQUAL(LoggedLines::Starting("ACTION manual ms=").size(), 1, ());
}

UNIT_TEST(NoGps_LogFormat_RuleHasItsNameAndTime)
{
  auto roads = StreetWithSideRoad(90);
  Env env(true /* inertial */, &roads);
  LoggedLines lines;
  TurnLeftSlowly(env, 46);
  TEST(env.m_delegate.HasEvent(Event::RoadLost), ());
  auto const lost = LoggedLines::Starting("RULE road_lost ms=");
  TEST(!lost.empty(), ());
  // The sentence follows the tag, the name and the keys.
  TEST(lost[0].find(" The road is lost after ") != std::string::npos, (lost[0]));
  TEST(env.m_engine.GetTripLine().starts_with("TRIP ms="), (env.m_engine.GetTripLine()));
}

UNIT_TEST(NoGps_LogFormat_ProseLinesHaveTagAndTime)
{
  TestClock clock;
  TestStorage storage;
  TestDelegate delegate;
  TestMap map;
  storage.Set(Storage::kInertialEnabled, true);
  storage.Set(Storage::kLastTrusted, std::string("10.0000000,20.0000000,") + std::to_string(clock.UnixNowMs()));
  Engine engine(delegate, map, storage, clock, clock);
  LoggedLines lines;
  engine.Start();
  auto const ms = " ms=" + std::to_string(clock.UnixNowMs());
  auto const trusted = LoggedLines::Starting("EVENT last_trusted" + ms);
  TEST_EQUAL(trusted.size(), 1, ());
  TEST(trusted[0].find(" Last trusted position = ") != std::string::npos, (trusted[0]));
  TEST_EQUAL(LoggedLines::Starting("EVENT speed_table" + ms).size(), 1, ());
  engine.OnEsp32BleState(BleState::Connected);
  auto const ble = LoggedLines::Starting("ACTION ble_state" + ms);
  TEST_EQUAL(ble.size(), 1, ());
  TEST(ble[0].find(" Bluetooth = ") != std::string::npos, (ble[0]));
}
}  // namespace nogps_engine_tests
