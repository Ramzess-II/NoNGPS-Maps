#include "testing/testing.hpp"

#include "map/map_tests/nogps_test_roads.hpp"

#include "map/nogps/geo.hpp"
#include "map/nogps/peer_sync.hpp"

#include <cmath>
#include <cstdint>

namespace nogps_peer_sync_tests
{
using namespace nogps;
using namespace nogps_test;

// The box counts 50 lines a second.
int64_t constexpr kLineMs = 20;

// The car drives |ms| at |speedMps| turning at |yawRateDegS|, clockwise is positive.
struct Box
{
  void Drive(PeerSync & sync, int64_t ms, double speedMps, double yawRateDegS)
  {
    for (int64_t t = 0; t < ms; t += kLineMs)
    {
      m_nowMs += kLineMs;
      m_distMm += speedMps * kLineMs;
      m_yawMdeg += yawRateDegS * kLineMs;
      sync.OnBoxData(m_nowMs, std::llround(m_distMm), std::llround(m_yawMdeg));
    }
  }

  int64_t m_nowMs = 1'000'000;
  double m_distMm = 0;
  double m_yawMdeg = 0;
};

esp32::Peer At0(int64_t distMm, char kind = 'A', char source = 'T')
{
  esp32::Peer peer;
  peer.m_kind = kind;
  peer.m_distMm = distMm;
  auto const position = At(0, 0);
  peer.m_latE7 = std::lround(position.m_lat * 1e7);
  peer.m_lonE7 = std::lround(position.m_lon * 1e7);
  peer.m_headingCdeg = 9000;
  peer.m_accuracyDm = 50;
  peer.m_source = source;
  return peer;
}

PeerOutPlace Place()
{
  return {At(100, 3), 90.0, 12.0, 'T'};
}

UNIT_TEST(NoGps_PeerSync_AnchorIsCarriedFromItsDistance)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 0, 0);
  auto const d = *sync.GetDistMm();
  // The leader has set the place, the follower hears the line of the box 2 s later: the car has driven 20 m east.
  box.Drive(sync, 2000, 10, 0);
  auto const place = sync.OnReceived(PeerRole::Following, At0(d));
  TEST(place, ());
  TEST_ALMOST_EQUAL_ABS(East(place->m_position), 20.0, 0.1, ());
  TEST_ALMOST_EQUAL_ABS(North(place->m_position), 0.0, 0.1, ());
  TEST_ALMOST_EQUAL_ABS(*place->m_bearingDeg, 90.0, 0.01, ());
  TEST_EQUAL(place->m_source, 'T', ());
  TEST_ALMOST_EQUAL_ABS(place->m_accuracyM, 5.0, 0.01, ());
}

UNIT_TEST(NoGps_PeerSync_AnchorIsCarriedOverATurn)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 0, 0);
  auto const d = *sync.GetDistMm();
  // A quarter of a circle to the right, 10 m of the way: the radius is 20 / pi.
  box.Drive(sync, 2000, 5, 45);
  auto const place = sync.OnReceived(PeerRole::Following, At0(d));
  TEST(place, ());
  double const radius = 10.0 / (M_PI / 2);
  TEST_ALMOST_EQUAL_ABS(East(place->m_position), radius, 0.15, ());
  TEST_ALMOST_EQUAL_ABS(North(place->m_position), -radius, 0.15, ());
  TEST_ALMOST_EQUAL_ABS(*place->m_bearingDeg, 180.0, 0.01, ());
}

UNIT_TEST(NoGps_PeerSync_OldAnchorIsDropped)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 10, 0);
  auto const old = *sync.GetDistMm();
  box.Drive(sync, kPeerHistoryMs - 1000, 10, 0);
  TEST(sync.OnReceived(PeerRole::Following, At0(old)), ());
  box.Drive(sync, 2000, 10, 0);
  TEST(!sync.OnReceived(PeerRole::Following, At0(old)), ());
  // A place from the moment the history has no line for. Standing is not a way: it is the same place.
  PeerSync standing;
  Box stood;
  stood.Drive(standing, 20'000, 0, 0);
  TEST(standing.OnReceived(PeerRole::Following, At0(0)), ());
  // The box restarts and counts from zero: the lines before it are not the history.
  standing.Reset();
  TEST(!standing.GetDistMm(), ());
  TEST(!standing.OnReceived(PeerRole::Following, At0(0)), ());
}

UNIT_TEST(NoGps_PeerSync_PlaceWithoutHeadingGrowsInaccuracy)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 0, 0);
  auto peer = At0(*sync.GetDistMm());
  peer.m_headingCdeg = -1;
  box.Drive(sync, 1000, 10, 0);
  auto const place = sync.OnReceived(PeerRole::Following, peer);
  TEST(place, ());
  TEST(!place->m_bearingDeg, ());
  TEST_ALMOST_EQUAL_ABS(East(place->m_position), 0.0, 0.01, ());
  TEST_ALMOST_EQUAL_ABS(place->m_accuracyM, 15.0, 0.1, ());
}

UNIT_TEST(NoGps_PeerSync_RolesTakeTheirMessages)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 0, 0);
  auto const d = *sync.GetDistMm();
  // The leader takes the corrections and the GPS of the follower, the follower the anchors and the snapshots.
  for (char kind : {'A', 'S', 'C', 'G'})
  {
    bool const leaderTakes = kind == 'C' || kind == 'G';
    TEST_EQUAL(sync.OnReceived(PeerRole::Leading, At0(d, kind)).has_value(), leaderTakes, (kind));
    TEST_EQUAL(sync.OnReceived(PeerRole::Following, At0(d, kind)).has_value(), !leaderTakes, (kind));
    TEST(!sync.OnReceived(PeerRole::None, At0(d, kind)), (kind));
  }
}

UNIT_TEST(NoGps_PeerSync_LeaderSendsPlaces)
{
  PeerSync sync;
  Box box;
  // Nothing is sent before the box has counted anything.
  TEST(!sync.MakeMessage(PeerRole::Leading, PeerTrigger::PlaceSet, box.m_nowMs, Place()), ());
  box.Drive(sync, 1000, 10, 0);

  auto const anchor = sync.MakeMessage(PeerRole::Leading, PeerTrigger::PlaceSet, box.m_nowMs, Place());
  TEST(anchor, ());
  TEST_EQUAL(anchor->m_kind, 'A', ());
  TEST_EQUAL(anchor->m_distMm, *sync.GetDistMm(), ());
  TEST_EQUAL(anchor->m_headingCdeg, 9000, ());
  TEST_EQUAL(anchor->m_accuracyDm, 120, ());
  TEST_EQUAL(anchor->m_source, 'T', ());
  TEST_EQUAL(anchor->m_latE7, std::lround(At(100, 3).m_lat * 1e7), ());

  // The place set by the user is sent at once, however often.
  TEST(sync.MakeMessage(PeerRole::Leading, PeerTrigger::PlaceSet, box.m_nowMs, Place()), ());
  TEST(sync.MakeMessage(PeerRole::Leading, PeerTrigger::CorrectionTaken, box.m_nowMs, Place()), ());
  // GPS and the snapshots are told once in the interval.
  TEST(!sync.MakeMessage(PeerRole::Leading, PeerTrigger::GpsPlace, box.m_nowMs + 1000, Place()), ());
  TEST(!sync.MakeMessage(PeerRole::Leading, PeerTrigger::Timer, box.m_nowMs + kPeerSnapshotIntervalMs / 2 - 1, Place()),
       ());
  auto const snapshot =
      sync.MakeMessage(PeerRole::Leading, PeerTrigger::Timer, box.m_nowMs + kPeerSnapshotIntervalMs / 2, Place());
  TEST(snapshot, ());
  TEST_EQUAL(snapshot->m_kind, 'S', ());
  auto const gps = sync.MakeMessage(PeerRole::Leading, PeerTrigger::GpsPlace, box.m_nowMs + 2 * kPeerSnapshotIntervalMs,
                                    PeerOutPlace{At(0, 0), {}, 3, 'G'});
  TEST(gps, ());
  TEST_EQUAL(gps->m_kind, 'A', ());
  TEST_EQUAL(gps->m_headingCdeg, -1, ());

  // The leader sends neither corrections nor the GPS of a follower.
  TEST(!sync.MakeMessage(PeerRole::Leading, PeerTrigger::GpsFix, box.m_nowMs, Place()), ());
}

UNIT_TEST(NoGps_PeerSync_DistanceIsTakenAtTheMomentOfThePlace)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 2000, 10, 0);
  auto place = Place();
  place.m_ageMs = 1000;
  auto const anchor = sync.MakeMessage(PeerRole::Leading, PeerTrigger::PlaceSet, box.m_nowMs, place);
  TEST(anchor, ());
  // 10 m/s: the distance of a second ago is 10 m less than now.
  TEST_ALMOST_EQUAL_ABS(static_cast<double>(*sync.GetDistMm() - anchor->m_distMm), 10'000.0, 200.0, ());
  // A place older than the history is not sent.
  place.m_ageMs = 3000;
  TEST(!sync.MakeMessage(PeerRole::Leading, PeerTrigger::PlaceSet, box.m_nowMs, place), ());
}

UNIT_TEST(NoGps_PeerSync_LeaderManualForgottenOnRoleChange)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 10, 0);
  TEST(sync.OnReceived(PeerRole::Following, At0(*sync.GetDistMm(), 'S', 'M')), ());
  TEST(sync.IsLeaderManual(), ());
  sync.MakeMessage(PeerRole::Leading, PeerTrigger::PlaceSet, box.m_nowMs, Place());
  TEST(!sync.IsLeaderManual(), ());
}

UNIT_TEST(NoGps_PeerSync_FollowerSendsCorrectionsAndGpsOfManualLeader)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 10, 0);
  auto const correction = sync.MakeMessage(PeerRole::Following, PeerTrigger::PlaceSet, box.m_nowMs, Place());
  TEST(correction, ());
  TEST_EQUAL(correction->m_kind, 'C', ());
  // It tells nothing by itself: no anchors, no snapshots.
  TEST(!sync.MakeMessage(PeerRole::Following, PeerTrigger::Timer, box.m_nowMs + 100'000, Place()), ());
  TEST(!sync.MakeMessage(PeerRole::Following, PeerTrigger::GpsPlace, box.m_nowMs + 100'000, Place()), ());
  TEST(!sync.MakeMessage(PeerRole::Following, PeerTrigger::CorrectionTaken, box.m_nowMs, Place()), ());

  // The GPS of the follower is sent while the leader is in the manual mode.
  TEST(!sync.IsLeaderManual(), ());
  TEST(!sync.MakeMessage(PeerRole::Following, PeerTrigger::GpsFix, box.m_nowMs, Place()), ());
  TEST(sync.OnReceived(PeerRole::Following, At0(*sync.GetDistMm(), 'S', 'G')), ());
  TEST(!sync.IsLeaderManual(), ());
  TEST(!sync.MakeMessage(PeerRole::Following, PeerTrigger::GpsFix, box.m_nowMs, Place()), ());
  TEST(sync.OnReceived(PeerRole::Following, At0(*sync.GetDistMm(), 'S', 'M')), ());
  TEST(sync.IsLeaderManual(), ());
  auto const gps = sync.MakeMessage(PeerRole::Following, PeerTrigger::GpsFix, box.m_nowMs, Place());
  TEST(gps, ());
  TEST_EQUAL(gps->m_kind, 'G', ());
  // The leader tells it is back to GPS.
  TEST(sync.OnReceived(PeerRole::Following, At0(*sync.GetDistMm(), 'A', 'G')), ());
  TEST(!sync.MakeMessage(PeerRole::Following, PeerTrigger::GpsFix, box.m_nowMs, Place()), ());
}

UNIT_TEST(NoGps_PeerSync_NoRoleSendsNothing)
{
  PeerSync sync;
  Box box;
  box.Drive(sync, 1000, 10, 0);
  for (auto const trigger : {PeerTrigger::PlaceSet, PeerTrigger::GpsPlace, PeerTrigger::Timer, PeerTrigger::GpsFix,
                             PeerTrigger::CorrectionTaken})
  {
    TEST(!sync.MakeMessage(PeerRole::None, trigger, box.m_nowMs + 100'000, Place()), ());
  }
}
}  // namespace nogps_peer_sync_tests
