#include "testing/testing.hpp"

#include "drape_frontend/drape_frontend_tests/visual_params_fixture.hpp"
#include "drape_frontend/my_position_controller.hpp"
#include "drape_frontend/user_event_stream.hpp"
#include "drape_frontend/visual_params.hpp"

#include "platform/location.hpp"

#include "geometry/screenbase.hpp"

#include "base/math.hpp"

#include <optional>

namespace my_position_controller_tests
{
using df::kDoNotChangeZoom;
using df::test_support::VisualParamsFixture;

/// Remembers how the controller has asked to show the map.
class Listener : public df::MyPositionController::Listener
{
public:
  void PositionChanged(m2::PointD const &, bool) override {}
  void ChangeModelView(m2::PointD const &, int zoomLevel, df::TAnimationCreator const &) override
  {
    m_zoomLevel = zoomLevel;
  }
  void ChangeModelView(double, df::TAnimationCreator const &) override {}
  void ChangeModelView(m2::RectD const &, df::TAnimationCreator const &) override {}
  void ChangeModelView(m2::PointD const &, double, m2::PointD const &, int zoomLevel, df::Animation::TAction const &,
                       df::TAnimationCreator const &) override
  {
    m_zoomLevel = zoomLevel;
  }
  void ChangeModelView(double autoScale, m2::PointD const &, double, m2::PointD const &,
                       df::TAnimationCreator const &) override
  {
    m_autoScale = autoScale;
  }

  std::optional<int> m_zoomLevel;
  std::optional<double> m_autoScale;
};

class Map : public df::test_support::VisualParamsFixture
{
public:
  Map()
    : m_controller(df::MyPositionController::Params(location::Follow, 0.0 /* timeInBackground */, df::Hints(),
                                                    false /* isRoutingActive */, true /* isAutozoomEnabled */,
                                                    [](location::EMyPositionMode, bool) {}),
                   nullptr /* notifier */)
  {
    m_controller.SetListener(make_ref(&m_listener));
  }

  static ScreenBase Screen(int zoom)
  {
    ScreenBase screen;
    screen.OnSize(0, 0, 1080, 1920);
    // The middle of the zoom level, not to depend on the rounding.
    screen.SetFromParams(m2::PointD::Zero(), 0.0 /* angle */, df::GetScreenScale(zoom + 0.5));
    return screen;
  }

  void Locate(double accuracyM, double speedMps, double bearingDeg = -1.0)
  {
    location::GpsInfo info;
    info.m_timestamp = ++m_timestamp;
    info.m_horizontalAccuracy = accuracyM;
    info.m_speed = speedMps;
    info.m_bearing = bearingDeg;
    m_controller.OnLocationUpdate(info, m_controller.IsInRouting(), Screen(16));
  }

  /// The user moves the map away, leaves it at |zoom| and presses the button of the position.
  Listener const & MoveAwayAndPress(int zoom)
  {
    m_controller.Scrolled({100.0, 0.0});
    TEST_EQUAL(m_controller.GetCurrentMode(), location::NotFollow, ());
    return Press(zoom);
  }

  Listener const & Press(int zoom)
  {
    m_listener = {};
    m_controller.NextMode(Screen(zoom));
    return m_listener;
  }

  Listener m_listener;
  df::MyPositionController m_controller;
  double m_timestamp = 0.0;
};

UNIT_CLASS_TEST(Map, MyPositionController_ButtonBringsMapClose)
{
  Locate(15.0 /* accuracyM */, 0.0 /* speedMps */);
  TEST_EQUAL(m_controller.GetCurrentMode(), location::Follow, ());

  // A map left at the scale of a district comes to the scale of the streets.
  TEST_EQUAL(MoveAwayAndPress(13).m_zoomLevel, 16, ());
  TEST_EQUAL(m_controller.GetCurrentMode(), location::Follow, ());
  TEST_EQUAL(MoveAwayAndPress(5).m_zoomLevel, 16, ());
  // A closer map is left as it is.
  TEST_EQUAL(MoveAwayAndPress(16).m_zoomLevel, kDoNotChangeZoom, ());
  TEST_EQUAL(MoveAwayAndPress(18).m_zoomLevel, kDoNotChangeZoom, ());

  // The position is known within 20 km: there is nothing to look at closer than that.
  Locate(20000.0 /* accuracyM */, 0.0 /* speedMps */);
  TEST_EQUAL(MoveAwayAndPress(13).m_zoomLevel, kDoNotChangeZoom, ());
  auto const zoom = MoveAwayAndPress(5).m_zoomLevel;
  TEST(zoom && *zoom > 5 && *zoom < 13, (zoom));
}

UNIT_CLASS_TEST(Map, MyPositionController_ButtonBringsMapCloseInRouting)
{
  Locate(15.0 /* accuracyM */, 0.0 /* speedMps */);
  m_controller.ActivateRouting(17 /* zoomLevel */, true /* enableAutoZoom */, true /* isArrowGlued */);
  TEST_EQUAL(m_listener.m_zoomLevel, 17, ());

  // The car stands, there is no scale by the speed: the map comes to the scale the navigation has started with.
  auto view = MoveAwayAndPress(13);
  TEST_EQUAL(m_controller.GetCurrentMode(), location::FollowAndRotate, ());
  TEST_EQUAL(view.m_zoomLevel, 17, ());
  TEST(!view.m_autoScale, ());
  TEST_EQUAL(MoveAwayAndPress(18).m_zoomLevel, kDoNotChangeZoom, ());

  // The car drives: the scale by the speed at once, not 10 seconds later.
  Locate(15.0 /* accuracyM */, 10.0 /* speedMps */);
  view = MoveAwayAndPress(13);
  TEST_EQUAL(m_controller.GetCurrentMode(), location::FollowAndRotate, ());
  TEST(view.m_autoScale && *view.m_autoScale > 0.0, (view.m_autoScale));
  TEST(!view.m_zoomLevel, ());

  // The next press turns the map to the north and doesn't change the scale.
  view = Press(13);
  TEST_EQUAL(m_controller.GetCurrentMode(), location::Follow, ());
  TEST_EQUAL(view.m_zoomLevel, kDoNotChangeZoom, ());
}

UNIT_CLASS_TEST(Map, MyPositionController_ButtonBringsMapCloseInRoutingWithoutAutoZoom)
{
  Locate(15.0 /* accuracyM */, 10.0 /* speedMps */);
  m_controller.ActivateRouting(16 /* zoomLevel */, false /* enableAutoZoom */, true /* isArrowGlued */);

  auto const view = MoveAwayAndPress(13);
  TEST_EQUAL(view.m_zoomLevel, 16, ());
  TEST(!view.m_autoScale, ());
}

UNIT_CLASS_TEST(Map, MyPositionController_ButtonKeepsChosenFollow)
{
  std::optional<bool> saved;
  df::MyPositionController controller({location::Follow,
                                       0.0 /* timeInBackground */,
                                       {},
                                       false /* isRoutingActive */,
                                       true /* isAutozoomEnabled */,
                                       [](location::EMyPositionMode, bool) {},
                                       false /* preferRotate */,
                                       [&saved](bool prefer) { saved = prefer; }},
                                      nullptr);
  controller.SetListener(make_ref(&m_listener));
  location::GpsInfo info;
  info.m_timestamp = 1.0;
  info.m_horizontalAccuracy = 15.0;
  info.m_bearing = 90.0;
  controller.OnLocationUpdate(info, false /* isNavigable */, Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::Follow, ());

  // Car up is chosen: panning stops the following, the button brings car up back.
  controller.NextMode(Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::FollowAndRotate, ());
  TEST(saved && *saved, ());
  controller.Scrolled({100.0, 0.0});
  TEST_EQUAL(controller.GetCurrentMode(), location::NotFollow, ());
  controller.NextMode(Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::FollowAndRotate, ());

  // A route that ends or is closed goes back to car up, not to north.
  controller.ActivateRouting(17 /* zoomLevel */, true /* enableAutoZoom */, true /* isArrowGlued */);
  controller.DeactivateRouting();
  TEST_EQUAL(controller.GetCurrentMode(), location::FollowAndRotate, ());

  // North up is chosen.
  controller.NextMode(Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::Follow, ());
  TEST(saved && !*saved, ());
  controller.Scrolled({100.0, 0.0});
  controller.NextMode(Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::Follow, ());
  controller.ActivateRouting(17 /* zoomLevel */, true /* enableAutoZoom */, true /* isArrowGlued */);
  controller.DeactivateRouting();
  TEST_EQUAL(controller.GetCurrentMode(), location::Follow, ());
}

UNIT_CLASS_TEST(Map, MyPositionController_ChosenFollowAtStart)
{
  location::GpsInfo info;
  info.m_timestamp = 1.0;
  info.m_horizontalAccuracy = 15.0;

  auto const start = [&](location::EMyPositionMode mode, bool preferRotate, double bearing)
  {
    df::MyPositionController controller({mode,
                                         0.0 /* timeInBackground */,
                                         {},
                                         false /* isRoutingActive */,
                                         true /* isAutozoomEnabled */,
                                         [](location::EMyPositionMode, bool) {},
                                         preferRotate},
                                        nullptr);
    info.m_bearing = bearing;
    controller.OnLocationUpdate(info, false /* isNavigable */, Screen(16));
    return controller.GetCurrentMode();
  };
  TEST_EQUAL(start(location::Follow, true, 90.0), location::FollowAndRotate, ());
  TEST_EQUAL(start(location::Follow, false, 90.0), location::Follow, ());
  // A start that doesn't follow the position stays so.
  TEST_EQUAL(start(location::NotFollow, true, 90.0), location::NotFollow, ());
  // A car up saved by a route that was cut short is the chosen mode outside routing.
  TEST_EQUAL(start(location::FollowAndRotate, false, 90.0), location::Follow, ());
  TEST_EQUAL(start(location::FollowAndRotate, true, 90.0), location::FollowAndRotate, ());
  // Car up without a direction waits for one.
  TEST_EQUAL(start(location::Follow, true, -1.0), location::Follow, ());
  TEST_EQUAL(start(location::FollowAndRotate, true, -1.0), location::Follow, ());
}

UNIT_CLASS_TEST(Map, MyPositionController_CarUpWaitsForDirection)
{
  df::MyPositionController controller({location::NotFollow,
                                       0.0 /* timeInBackground */,
                                       {},
                                       false /* isRoutingActive */,
                                       true /* isAutozoomEnabled */,
                                       [](location::EMyPositionMode, bool) {},
                                       true /* preferRotate */},
                                      nullptr);
  controller.SetListener(make_ref(&m_listener));
  location::GpsInfo info;
  info.m_timestamp = 1.0;
  info.m_horizontalAccuracy = 15.0;
  controller.OnLocationUpdate(info, false /* isNavigable */, Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::NotFollow, ());

  // No direction yet: the map follows north up.
  controller.NextMode(Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::Follow, ());
  // The direction comes: the map turns.
  info.m_timestamp = 2.0;
  info.m_bearing = 90.0;
  controller.OnLocationUpdate(info, false /* isNavigable */, Screen(16));
  TEST_EQUAL(controller.GetCurrentMode(), location::FollowAndRotate, ());
}

UNIT_CLASS_TEST(VisualParamsFixture, StopFollowModesAndFirstFix)
{
  ScreenBase screen;
  screen.OnSize(0, 0, 800, 600);
  screen.SetFromRect(m2::AnyRectD(m2::RectD(-100, -100, 100, 100)));
  location::GpsInfo fix;
  fix.m_latitude = 47;
  fix.m_longitude = 8;
  fix.m_horizontalAccuracy = 5;
  fix.m_bearing = 90;
  fix.m_timestamp = 1;

  for (auto mode : {location::Follow, location::FollowAndRotate, location::NotFollow})
  {
    // A start in car up is kept only when the user's last choice was car up, and it needs a direction.
    df::MyPositionController controller({mode,
                                         0.0 /* timeInBackground */,
                                         {},
                                         false /* isRoutingActive */,
                                         false /* isAutozoomEnabled */,
                                         {},
                                         mode == location::FollowAndRotate},
                                        nullptr);
    controller.OnUpdateScreen(screen);
    controller.OnLocationUpdate(fix, false /* isNavigable */, screen);
    TEST_EQUAL(controller.GetCurrentMode(), mode, ());
    controller.StopLocationFollow();
    TEST_EQUAL(controller.GetCurrentMode(), location::NotFollow, ());
  }

  df::MyPositionController pending({location::Follow,
                                    0.0 /* timeInBackground */,
                                    {},
                                    false /* isRoutingActive */,
                                    false /* isAutozoomEnabled */,
                                    {}},
                                   nullptr);
  pending.OnUpdateScreen(screen);
  TEST_EQUAL(pending.GetCurrentMode(), location::PendingPosition, ());
  pending.StopLocationFollow();
  pending.OnLocationUpdate(fix, false /* isNavigable */, screen);
  TEST_EQUAL(pending.GetCurrentMode(), location::NotFollow, ());
}
UNIT_CLASS_TEST(Map, MyPositionController_CarHeadingIsNotDropped)
{
  // A phone with a compass: the bearing of a moving position is kept for 3 seconds against the compass.
  m_controller.OnCompassUpdate(location::CompassInfo{1.0}, Screen(16));
  Locate(15.0 /* accuracyM */, 10.0 /* speedMps */, 90.0 /* bearingDeg */);
  TEST_ALMOST_EQUAL_ABS(m_controller.GetDirection(), math::DegToRad(90.0), 1e-9, ());
  m_controller.OnCompassUpdate(location::CompassInfo{1.0}, Screen(16));
  TEST_ALMOST_EQUAL_ABS(m_controller.GetDirection(), math::DegToRad(90.0), 1e-9, ());

  // The car direction of the core goes through at once.
  m_controller.OnCompassUpdate(location::CompassInfo{math::DegToRad(276.0), true /* isCarHeading */}, Screen(16));
  TEST_ALMOST_EQUAL_ABS(m_controller.GetDirection(), math::DegToRad(276.0), 1e-9, ());

  // And in the routing with the arrow glued to the route.
  m_controller.ActivateRouting(17 /* zoomLevel */, true /* enableAutoZoom */, true /* isArrowGlued */);
  m_controller.OnCompassUpdate(location::CompassInfo{1.0}, Screen(16));
  TEST_ALMOST_EQUAL_ABS(m_controller.GetDirection(), math::DegToRad(276.0), 1e-9, ());
  m_controller.OnCompassUpdate(location::CompassInfo{math::DegToRad(96.0), true /* isCarHeading */}, Screen(16));
  TEST_ALMOST_EQUAL_ABS(m_controller.GetDirection(), math::DegToRad(96.0), 1e-9, ());
}
}  // namespace my_position_controller_tests
