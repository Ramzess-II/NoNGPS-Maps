#include "map/nogps/engine.hpp"

#include "map/nogps/clock.hpp"
#include "map/nogps/geo.hpp"
#include "map/nogps/map_api.hpp"
#include "map/nogps/road_walker.hpp"
#include "map/nogps/storage.hpp"

#include "base/assert.hpp"
#include "base/logging.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iterator>
#include <limits>
#include <utility>

namespace nogps
{
namespace
{
// A GPS position without an accuracy is used anyway: some devices don't tell it.
bool IsAccuracySatisfied(Fix const & fix)
{
  return fix.m_provider == Provider::Gps || fix.m_accuracyM > 0;
}

bool IsBetterThanLast(Fix const & fix, Fix const & last)
{
  // How fast the user may move between the positions to compare their accuracies.
  double constexpr kDefaultSpeedMps = 5;
  if (fix.m_timeMs < last.m_timeMs)
    return false;
  if (last.m_provider == Provider::Gps && last.m_accuracyM == 0)
    return true;
  double const speed = std::max(kDefaultSpeedMps, (fix.m_speedMps.value_or(0) + last.m_speedMps.value_or(0)) / 2);
  double const lastAccuracy = last.m_accuracyM + speed * (fix.m_timeMs - last.m_timeMs) / 1000.0;
  return fix.m_accuracyM < lastAccuracy;
}

std::string FormatSeconds(int64_t ms)
{
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.1f", ms / 1000.0);
  return buf;
}

// "-" is for what the platform doesn't tell.
std::string FormatOptional(std::optional<double> value)
{
  if (!value)
    return "-";
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.1f", *value);
  return buf;
}

// The boxes of a user are few, the oldest one is forgotten.
size_t constexpr kMaxKnownBoxes = 8;

/// Remembers how many times the box was powered on by its own count.
/// \returns true if the box was powered on since it was seen the last time.
bool SaveBoxPowerOns(Storage & storage, std::string const & id, int64_t powerOns)
{
  std::vector<std::pair<std::string, int64_t>> boxes;
  auto const saved = storage.Get<std::string>(Storage::kBoxPowerOns, "");
  for (auto const item : strings::Tokenize(saved, ","))
  {
    auto const colon = item.find(':');
    int64_t count;
    if (colon != std::string_view::npos && strings::to_int(item.substr(colon + 1), count))
      boxes.emplace_back(item.substr(0, colon), count);
  }
  auto const it = std::find_if(boxes.begin(), boxes.end(), [&id](auto const & box) { return box.first == id; });
  // A box not seen before with no power-ons has got its firmware in its place in the car: it has not moved.
  if ((it != boxes.end() ? it->second : 0) == powerOns)
    return false;

  if (it != boxes.end())
    boxes.erase(it);
  boxes.emplace_back(id, powerOns);
  if (boxes.size() > kMaxKnownBoxes)
    boxes.erase(boxes.begin());
  std::string text;
  for (auto const & [boxId, count] : boxes)
    text += (text.empty() ? "" : ",") + boxId + ":" + std::to_string(count);
  storage.Set(Storage::kBoxPowerOns, text);
  return true;
}
}  // namespace

Engine::Engine(Delegate & delegate, MapApi & map, Storage & storage, Clock const & clock, Scheduler & scheduler)
  : m_delegate(delegate)
  , m_map(map)
  , m_cars(storage)
  , m_storage(m_cars)
  , m_clock(clock)
  , m_scheduler(scheduler)
  , m_manualRepeatTimer(scheduler)
  , m_peerTimer(scheduler)
  , m_tripLogTimer(scheduler)
  , m_calibrateTimer(scheduler)
  , m_phoneRemovedTimer(scheduler)
{}

Engine::~Engine() = default;

void Engine::Start()
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  if (m_active)
    return;
  LOG(LINFO, ("Start"));
  m_active = true;
  m_loggedState = {};
  m_tripLoggedMs.reset();
  m_tripEverySecondMs.reset();
  m_startTimeMs = m_clock.NowMs();
  if (m_spoofingDetector.GetPhantomsCount() == 0)
    m_spoofingDetector.DeserializePhantoms(m_storage.Get<std::string>(Storage::kWrongNetworkPoints, ""));
  RestoreTrustedPosition();
  StartInertialNavigation();
  RestoreCarPosition();
  // After the car: GPS ignored before the restart is not trusted anew by its first position either. Once: the choice
  // is kept by the engine after it is stopped in the background.
  if (!m_gpsDisabled && m_storage.Get<bool>(Storage::kGpsDisabled, false))
    SetGpsDisabled(true);
  m_tripLogTimer.Start(0, [this] { LogTrip(); });
  m_peerTimer.Start(kPeerSnapshotIntervalMs, [this] { SharePlaceByTimer(); });
  if (m_manualLocation)
    m_manualRepeatTimer.Start(0, [this] { ApplyManualLocation(); });
}

void Engine::Stop()
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  if (!m_active)
    return;
  LOG(LINFO, ("Stop"));
  SaveCarPosition(true /* now */);
  if (m_inertial)
    m_inertial->Stop();
  m_manualRepeatTimer.Stop();
  m_peerTimer.Stop();
  m_tripLogTimer.Stop();
  CancelCalibrateWhenStill();
  m_active = false;
}

void Engine::OnCompass(double headingDeg, double accuracyDeg)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  m_compass = Compass{headingDeg, accuracyDeg, m_clock.NowMs()};
}

void Engine::OnFix(Fix const & location)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  if (!m_active)
  {
    LOG(LWARNING, ("Not active, ignoring", DebugPrint(location.m_provider), location.m_position));
    return;
  }

  bool const isNetwork = location.m_provider == Provider::Network;
  if (location.m_provider == Provider::Gps)
    m_rawGps = location;
  else if (location.m_provider == Provider::Fused)
    m_rawFused = location;
  bool const wasSpoofed = m_spoofingDetector.IsSpoofed();
  bool trusted = true;
  if (isNetwork)
  {
    auto const phantoms = m_spoofingDetector.SerializePhantoms();
    bool const accepted =
        m_spoofingDetector.OnNetworkPosition(location.m_position, location.m_accuracyM, location.m_timeMs);
    if (phantoms != m_spoofingDetector.SerializePhantoms())
    {
      LOG(LWARNING, ("Wrong network points =", m_spoofingDetector.SerializePhantoms()));
      m_storage.Set(Storage::kWrongNetworkPoints, m_spoofingDetector.SerializePhantoms());
    }
    if (!accepted)
    {
      LOG(LWARNING, ("The network location jumps away, ignoring it =", location.m_position, location.m_accuracyM));
      return;
    }
    m_networkLocation = location;
  }
  else
  {
    trusted = m_spoofingDetector.CheckSatellitePosition(location.m_position, location.m_timeMs, location.m_accuracyM,
                                                        location.m_speedMps, GetCarSpeedMps(),
                                                        location.m_provider == Provider::Gps);
  }

  bool const spoofed = m_spoofingDetector.IsSpoofed();
  if (spoofed != wasSpoofed)
    OnGpsSpoofingChanged(spoofed);
  SaveTrustedPosition();

  if (trusted && !isNetwork && m_inertial && IsInertialNavigationEnabled() && IsSpeedTableGps(location))
    m_inertial->OnSpeedTableGps(location);

  if (m_gpsDisabled && !isNetwork && SourceOf(location) == PositionSource::Gps)
  {
    // Every second: the log of a standing car would fill with it.
    if (IsCarMoving())
      LOG(LDEBUG, ("GPS is disabled, ignoring", location.m_position));
    // The user sees how GPS works though the car does not follow it.
    if (trusted)
      TrackWorkingGps(location);
    return;
  }

  if (!trusted)
  {
    m_gpsReturnDetector.Reset();
    LOG(LWARNING, ("Untrusted location =", location.m_position, location.m_accuracyM));
    return;
  }

  // Android gives a GPS position twice, from the satellites alone and mixed with the network. A copy of the one the
  // inertial navigation has started from would start it anew from its own place, and shown again it would tell the
  // core that the car stands: extrapolation::Extrapolator stops moving the mark until the next position. A copy of a
  // rejected one is checked as any other position.
  if (m_lastTrustedGpsTimeMs && location.m_timeMs == *m_lastTrustedGpsTimeMs &&
      SourceOf(location) == PositionSource::Gps)
  {
    LOG(LDEBUG, ("The same position again", location.m_position));
    return;
  }

  bool const goodGps = TrackWorkingGps(location);
  if (goodGps)
    SharePlace(PeerTrigger::GpsFix, 'G', location);
  if (m_manualMode && goodGps && (m_manualUntilGps || IsGpsBack(location)))
  {
    LOG(LINFO, ("GPS is trusted again, leaving the manual mode, location =", location.m_position));
    // GPS was trusted before the restart of the app: it is found at the start as always, the user is not told.
    bool const told = !m_manualUntilGps;
    SetManualMode(false);
    if (told)
      Notify(Event::GpsBack);
  }
  if (!m_manualMode && goodGps && IsOffRoadWhileDriving(location))
  {
    // The last position on the road is kept, the inertial navigation continues from it.
    if (++m_offRoadGpsCount >= kOffRoadGpsCount)
      EnterManualModeByItself("GPS has left the roads, location = " + DebugPrint(location.m_position));
    else
      LOG(LWARNING, ("GPS is off the roads, location =", location.m_position));
    return;
  }
  m_offRoadGpsCount = 0;
  if (!m_manualMode && goodGps && ContradictsInertial(location))
  {
    EnterManualModeByItself("GPS contradicts the inertial position, location = " + DebugPrint(location.m_position));
    return;
  }
  if (!m_manualMode && goodGps)
  {
    m_lastTrustedGpsMs = m_clock.NowMs();
    m_lastTrustedGpsTimeMs = location.m_timeMs;
    if (m_inertial)
      m_inertial->OnGpsPosition(location);
    SharePlace(PeerTrigger::GpsPlace, 'G', location);
  }

  if (m_manualMode && m_manualForNoPosition && isNetwork && !m_manualLocation)
  {
    LOG(LINFO, ("The network position is back, leaving the manual mode, location =", location.m_position));
    SetManualMode(false);
  }

  if (m_manualMode)
  {
    if (IsCarMoving())
      LOG(LDEBUG, ("Manual mode is on, ignoring", location.m_position));
    return;
  }

  // Cell tower positions jump by hundreds of meters. It is tolerable while the user looks at the map, but
  // while navigating they would throw the car off the route, so only GPS and dead reckoning are used.
  if (isNetwork && m_savedLocation && m_map.IsNavigating())
  {
    LOG(LDEBUG, ("Navigating, ignoring the network location", location.m_position));
    return;
  }

  if (isNetwork && IsInertialActive())
  {
    LOG(LDEBUG, ("Inertial navigation is more accurate than", location.m_position));
    return;
  }

  if (!IsAccuracySatisfied(location))
  {
    LOG(LWARNING, ("Unsatisfied accuracy for", location.m_position));
    return;
  }

  // While GPS is spoofed network positions are the only source, they must not compete with the spoofed ones.
  if (m_savedLocation && !(spoofed && isNetwork) && !m_acceptNextLocation &&
      !IsBetterThanLast(location, *m_savedLocation))
  {
    LOG(LDEBUG, ("The new", location.m_position, "is worse than the last", m_savedLocation->m_position));
    return;
  }

  m_acceptNextLocation = false;
  m_savedLocation = location;
  m_fixShownMs = m_clock.NowMs();

  // While the inertial navigation doesn't work, it starts from the shown position.
  if (m_inertial && !IsInertialActive())
    m_inertial->SetPosition(location.m_position);

  // The core detects that the user left the route only after several moving GPS positions. Check the route at once
  // when the position source changes (e.g. from the manual position, which can be wrong, to GPS or cell towers),
  // and on every network position, as they are rare and often don't change while the user stands still.
  auto const source = SourceOf(location);
  if (source != m_lastPositionSource || source == PositionSource::Network)
    RebuildRouteIfOffRoute(location);
  m_lastPositionSource = source;

  NotifyLocationUpdated();
}

void Engine::OnLastKnownNetworkFix(Fix const & fix)
{
  // The first GPS positions are verified too, a fresh network position may come only several seconds later.
  if (m_networkLocation)
    return;
  LOG(LINFO, ("Last known network location =", fix.m_position, fix.m_accuracyM));
  if (m_spoofingDetector.OnNetworkPosition(fix.m_position, fix.m_accuracyM, fix.m_timeMs))
    m_networkLocation = fix;
}

void Engine::OnGyro(int64_t timestampNs, double x, double y, double z)
{
  if (m_inertial)
    m_inertial->OnGyro(timestampNs, {x, y, z});
}

void Engine::OnAccel(int64_t timestampNs, double x, double y, double z)
{
  if (m_inertial)
    m_inertial->OnAccel(timestampNs, {x, y, z});
}

void Engine::OnElm327Connected()
{
  if (m_inertial)
    m_inertial->OnElm327Connected();
}

void Engine::OnElm327Bytes(std::string_view data)
{
  if (!m_inertial)
    return;
  m_inertial->OnElm327Bytes(data);
  SaveHeardBox();
}

void Engine::OnElm327Closed(std::string const & reason)
{
  if (m_inertial)
    m_inertial->OnElm327Closed(reason);
}

void Engine::OnEsp32BleBytes(std::string_view bytes)
{
  if (!m_inertial)
    return;
  m_inertial->OnEsp32BleBytes(bytes);
  SaveHeardBox();
}

void Engine::OnEsp32BleState(BleState state)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  if (m_inertial)
    m_inertial->OnEsp32BleState(state);
}

PositionSource Engine::SourceOf(Fix const & fix)
{
  switch (fix.m_provider)
  {
  case Provider::Manual: return PositionSource::Manual;
  case Provider::Inertial: return PositionSource::Inertial;
  case Provider::Gps: return PositionSource::Gps;
  case Provider::Network: return PositionSource::Network;
  case Provider::Fused:
    return fix.m_accuracyM > kFusedSatelliteMaxAccuracyM ? PositionSource::Network : PositionSource::Gps;
  }
  UNREACHABLE();
}

int64_t Engine::AgeMs(Fix const & fix) const
{
  return m_clock.NowMs() - fix.m_timeMs;
}

int64_t Engine::MsSince(std::optional<int64_t> timeMs) const
{
  return timeMs ? m_clock.NowMs() - *timeMs : std::numeric_limits<int64_t>::max();
}

int64_t Engine::GetGpsSilenceMs() const
{
  // Counted from leaving the manual mode at most: GPS was ignored in it.
  return std::min(MsSince(m_lastTrustedGpsMs), MsSince(m_manualLeftMs));
}

GpsState Engine::GetGpsState() const
{
  if (!m_active)
    return GpsState::None;
  if (m_spoofingDetector.IsSpoofed())
    return GpsState::Spoofed;
  if (auto const gps = GetWorkingGps(); gps && AgeMs(*gps) <= kGpsLostMs)
  {
    // GPS ignored by the user is not checked by IsGpsBack(): it is told how GPS works.
    return m_manualMode && !m_gpsDisabled ? GpsState::Checking : GpsState::Good;
  }
  if (MsSince(m_startTimeMs) <= kGpsFirstFixMs)
    return GpsState::Checking;
  auto const fresh = [this](std::optional<Fix> const & fix) { return fix && AgeMs(*fix) <= kGpsLostMs; };
  if (fresh(m_rawGps) || fresh(m_rawFused) || GetWorkingNetwork())
    return GpsState::Coarse;
  return GpsState::None;
}

bool Engine::IsGpsBack(Fix const & gps)
{
  // GPS has worked long enough in the manual mode and agrees with the position known without it.
  std::optional<GpsReturnDetector::Own> own;
  if (m_inertial && m_inertial->IsRoadLost())
  {
    // The inertial navigation has lost the road and stands where it was: the car is not there, and GPS is
    // not to be compared with that place.
  }
  else if (IsInertialActive() && m_savedLocation)
  {
    // The car maneuvering off the roads is not where its mark waits.
    auto const & car = m_inertial->GetOffRoadCar();
    own = GpsReturnDetector::Own{car ? *car : m_savedLocation->m_position, m_savedLocation->m_accuracyM};
  }
  else if (m_manualLocation)
  {
    // The car has driven on since the mark.
    own = GpsReturnDetector::Own{
        m_manualLocation->m_position,
        m_manualLocation->m_accuracyM + GpsReturnDetector::kMaxSpeedMps * MsSince(m_manualSetTimeMs) / 1000.0};
  }
  return m_gpsReturnDetector.OnGpsPosition(gps.m_position, gps.m_accuracyM, gps.m_timeMs, own, gps.m_speedMps,
                                           GetCarSpeedMps(), IsNearRoad(gps));
}

std::optional<double> Engine::GetCarSpeedMps() const
{
  // The same speed the inertial count moves the car with, nothing when the box is silent (kSpeedStaleMs).
  if (!m_inertial || !IsInertialNavigationEnabled() || m_inertial->GetSpeedKmh() < 0)
    return {};
  return m_inertial->GetSpeedKmh() / 3.6 * m_inertial->GetSpeedScale();
}

bool Engine::IsSpeedTableGps(Fix const & gps)
{
  // GPS is good to measure the car speed errors by when it is not spoofed, accurate, has worked without breaks and
  // jumps for a while and is on a road. It is used in the manual mode and when GPS is disabled for tests too.
  if (SourceOf(gps) != PositionSource::Gps || AgeMs(gps) > kGpsFreshMs ||
      gps.m_accuracyM > kSpeedTableGpsMaxAccuracyM || m_spoofingDetector.IsSpoofed())
  {
    return false;
  }
  bool const good =
      m_speedTableGpsDetector.OnGpsPosition(gps.m_position, gps.m_accuracyM, gps.m_timeMs, {} /* own */,
                                            {} /* gpsSpeedMps */, {} /* carSpeedMps */, false /* onRoad */) &&
      IsNearRoad(gps);
  if (good)
    m_speedTableGpsMs = m_clock.NowMs();
  return good;
}

bool Engine::ContradictsInertial(Fix const & gps) const
{
  // GPS jumping away from the inertial position that has followed it is spoofed or broken: a car can't do that. It
  // is noticed at once, long before the spoofing detector notices it.
  if (!m_inertial || !m_inertial->IsReady() || MsSince(m_lastTrustedGpsMs) > kGpsFreshMs)
    return false;
  auto const inertial = m_inertial->GetLocation();
  return inertial && Distance(inertial->m_position, gps.m_position) > kMaxGpsInertialDiffM + gps.m_accuracyM;
}

bool Engine::IsOffRoadWhileDriving(Fix const & gps)
{
  // A car is always on a road, GPS away from the roads while the car drives is led away by a spoofer.
  if (!m_map.IsNavigating() && (!m_inertial || !m_inertial->IsReady()))
    return false;
  // A slow car may be in a yard or a parking lot that is not on the map.
  if (!gps.m_speedMps || *gps.m_speedMps < kOffRoadMinSpeedMps)
    return false;
  return !IsNearRoad(gps);
}

bool Engine::IsNearRoad(Fix const & gps)
{
  // A road going any way: a car turning at a crossing goes aside from both roads for a moment.
  double const radius = kMaxGpsOffRoadM + gps.m_accuracyM;
  auto const road = m_map.GetRoads(false /* matchRoute */).Snap(gps.m_position, {}, radius);
  return road && Distance(gps.m_position, road->m_point) <= radius;
}

void Engine::EnterManualModeByItself(std::string const & reason)
{
  // GPS is lost or wrong while driving: the car is followed by the inertial navigation and the marks of the user. The
  // manual mode is left by itself when GPS is trusted again.
  if (m_manualMode)
    return;
  LOG(LWARNING, ("Entering the manual mode:", reason));
  auto const last = m_savedLocation;
  SetManualMode(true);
  // The car is where it was shown until the user moves it: on the road there, or where GPS has left it if
  // there is no road. The inertial navigation has moved the car on since, it continues from there.
  bool const inertialReady = m_inertial && m_inertial->IsReady();
  // The place is a guess, not a place set by the user: it is not sent as one, the snapshot tells it as manual.
  m_applyingPeer = true;
  bool const marked = last && !inertialReady && SetManualLocation(last->m_position);
  m_applyingPeer = false;
  if (last && !inertialReady && !marked && SourceOf(*last) == PositionSource::Gps)
  {
    Fix location = *last;
    location.m_provider = Provider::Manual;
    location.m_accuracyM = kManualAccuracyM;
    m_manualLocation = location;
    m_manualSetTimeMs = m_clock.NowMs();
    ApplyManualLocation();
  }
  Notify(Event::GpsLost);
}

void Engine::CheckGpsLost()
{
  // There is no GPS while navigating without the inertial navigation, which turns the manual mode on by itself. GPS
  // may have been lost or never found since the start. Without navigation the network position is enough, the
  // manual mode is turned on only when there is none either.
  if (m_manualMode)
    return;
  int64_t const sinceStartMs = m_clock.NowMs() - m_startTimeMs;
  bool const lost =
      m_spoofingDetector.IsSpoofed() ||
      (!m_lastTrustedGpsMs && !m_manualLeftMs ? sinceStartMs > kGpsFirstFixMs : GetGpsSilenceMs() > kGpsLostMs);
  if (!lost)
    return;
  if (m_map.IsNavigating())
  {
    EnterManualModeByItself("No GPS while navigating");
  }
  else if (!GetWorkingNetwork() && sinceStartMs > kGpsFirstFixMs)
  {
    EnterManualModeByItself("No GPS and no network position");
    m_manualForNoPosition = true;
  }
}

void Engine::CheckMotionSourceStopped()
{
  // The car speed has stopped coming while the car is followed without GPS: the position stands still then, and
  // the user would not know why.
  if (!m_inertial || !IsInertialNavigationEnabled())
  {
    m_motionSourceWorked = false;
    return;
  }
  auto const state = m_inertial->GetSourceState();
  if (state == SourceState::Connected)
  {
    m_motionSourceWorked = true;
    m_motionSourceWarnedMs.reset();
    return;
  }
  // The box sleeps with the engine stopped: the car stands, nothing is lost.
  if (state == SourceState::BoxSleeping || state == SourceState::ObdSleeping)
    return;
  if (!m_motionSourceWorked || !m_manualMode || MsSince(m_motionSourceWarnedMs) < kMotionSourceWarningIntervalMs)
    return;
  m_motionSourceWarnedMs = m_clock.NowMs();
  Notify(Event::MotionSourceStopped);
}

void Engine::CheckNotCalibrated()
{
  // The car speed comes, but the gyroscope is not calibrated or the sensor box tells it has been moved: the
  // position set by the user stands still while the car drives, and the user would not know why.
  bool driving = false;
  if (m_inertial && IsInertialNavigationEnabled() && m_manualMode &&
      m_inertial->GetSourceState() == SourceState::Connected && m_inertial->GetSpeedKmh() >= kNotCalibratedSpeedKmh)
  {
    auto const calibration = m_inertial->GetCalibrationState();
    driving = calibration != CalibrationState::Done && calibration != CalibrationState::Calibrating;
  }
  if (!driving)
  {
    m_notCalibratedSinceMs.reset();
    return;
  }
  int64_t const now = m_clock.NowMs();
  if (!m_notCalibratedSinceMs)
    m_notCalibratedSinceMs = now;
  if (now - *m_notCalibratedSinceMs < kNotCalibratedDelayMs ||
      MsSince(m_notCalibratedWarnedMs) < kMotionSourceWarningIntervalMs)
  {
    return;
  }
  m_notCalibratedWarnedMs = now;
  LOG(LWARNING, ("The car drives, the gyroscope is not calibrated:", m_inertial->GetCalibrationState()));
  Notify(Event::NotCalibrated);
}

void Engine::UpdateSpeedHint()
{
  if (!m_inertial || !IsInertialNavigationEnabled())
  {
    m_measuredSpeedRanges.reset();
    m_speedHintShown = false;
    m_speedHintSinceMs.reset();
    m_speedHintLeftMs.reset();
    return;
  }
  auto const table = m_inertial->GetGpsSpeedTable();
  std::bitset<SpeedTable::kRanges> measured;
  for (int i = 0; i < SpeedTable::kRanges; ++i)
    measured[i] = table[i].m_scale > 0;
  auto const before = m_measuredSpeedRanges;
  m_measuredSpeedRanges = measured;
  std::optional<int> calibrated;
  if (before)
  {
    for (int i = 0; i < SpeedTable::kRanges; ++i)
      if (measured[i] && !(*before)[i])
        calibrated = i;
  }
  if (calibrated)
  {
    // The first |count| ranges are all measured now and were not before.
    auto const completes = [&](int count)
    {
      bool wasComplete = true;
      for (int i = 0; i < count; ++i)
      {
        if (!measured[i])
          return false;
        wasComplete = wasComplete && (*before)[i];
      }
      return !wasComplete;
    };
    if (completes(SpeedTable::kRanges))
      m_speedMilestone = SpeedMilestone::Full;
    else if (completes(kOutOfTownSpeedRanges))
      m_speedMilestone = SpeedMilestone::OutOfTown;
    else if (completes(kCitySpeedRanges))
      m_speedMilestone = SpeedMilestone::City;
    else
      m_speedMilestone = SpeedMilestone::Range;
    // The bar shows that the range is measured and slides back: it doesn't stay for the measured speed.
    m_speedHintRange = *calibrated;
    m_speedHintShown = false;
    m_speedHintSinceMs.reset();
    m_speedHintLeftMs.reset();
    LOG(LINFO, ("GPS has measured the speed range", *calibrated, "of", measured.count(), m_speedMilestone));
    Notify(Event::SpeedRangeCalibrated);
    return;
  }

  int64_t const now = m_clock.NowMs();
  int const speedKmh = m_inertial->GetSpeedKmh();
  int const range = SpeedTable::Range(std::max(0, speedKmh));
  if (m_inertial->GetSourceState() == SourceState::Connected && speedKmh >= SpeedTable::kMinSpeedKmh &&
      !measured[range])
  {
    m_speedHintLeftMs.reset();
    if (!m_speedHintSinceMs)
      m_speedHintSinceMs = now;
    if (!m_speedHintShown && now - *m_speedHintSinceMs >= kSpeedHintDelayMs)
    {
      LOG(LINFO, ("GPS has not measured the speed range", range));
      m_speedHintShown = true;
    }
    if (m_speedHintShown)
      m_speedHintRange = range;
    return;
  }
  m_speedHintSinceMs.reset();
  if (!m_speedHintShown)
    return;
  if (!m_speedHintLeftMs)
    m_speedHintLeftMs = now;
  if (now - *m_speedHintLeftMs >= kSpeedHintLingerMs)
  {
    m_speedHintShown = false;
    m_speedHintLeftMs.reset();
  }
}

void Engine::CheckFirmwareUpdate()
{
  auto * box = m_inertial && IsInertialNavigationEnabled() ? m_inertial->GetEsp32() : nullptr;
  auto const state = box ? box->GetUpdate().GetState() : Esp32Update::State::None;
  if (state != m_firmwareUpdateState)
  {
    m_firmwareUpdateState = state;
    if (state == Esp32Update::State::Done)
      Notify(Event::FirmwareUpdateDone);
    else if (state == Esp32Update::State::Failed)
      Notify(Event::FirmwareUpdateFailed);
  }

  if (!box || !box->GetInfo())
  {
    m_boxKnownSinceMs.reset();
    m_drivenWithBox = false;
    DropFirmwareOffer();
    return;
  }
  int64_t const now = m_clock.NowMs();
  if (!m_boxKnownSinceMs)
    m_boxKnownSinceMs = now;
  if (m_inertial->GetSpeedKmh() > 0)
    m_drivenWithBox = true;
  // The box refuses an update while the car drives. The application and its firmware are a pair, they are
  // checked together: the firmware of the application is offered to a box with a newer one too.
  auto const * firmware = FindBoxFirmware();
  if (m_drivenWithBox || now - *m_boxKnownSinceMs < kFirmwareOfferDelayMs || !firmware ||
      firmware->m_version == box->GetInfo()->m_firmware)
  {
    DropFirmwareOffer();
    return;
  }
  std::string const offer = box->GetInfo()->m_firmware + " to " + firmware->m_version;
  if (offer == m_offeredFirmware)
    return;
  m_offeredFirmware = offer;
  m_firmwareOfferPending = true;
  LOG(LINFO, ("The firmware of the box can be updated:", offer));
  Notify(Event::FirmwareUpdateAvailable);
}

// An offer nobody has seen is made again when its conditions hold again.
void Engine::DropFirmwareOffer()
{
  if (m_firmwareOfferPending)
    m_offeredFirmware.clear();
  m_firmwareOfferPending = false;
}

void Engine::CheckBoxCalibration()
{
  auto const * box = m_inertial && IsInertialNavigationEnabled() ? m_inertial->GetEsp32() : nullptr;
  if (!box)
  {
    m_boxCalibrationAdvicePending = false;
    return;
  }

  if (auto const calibrated = box->GetCalibratedMs(); calibrated != m_boxCalibratedMs)
  {
    m_boxCalibratedMs = calibrated;
    if (calibrated)
    {
      m_boxCalibrationAdvicePending = false;
      m_storage.Set(Storage::kBoxCalibrationAdvised, false);
    }
  }

  // The box keeps its calibration, but it doesn't know that it was taken out of the car and put in another
  // way: tilted by less than 20 degrees it tells nothing and measures up to 6 % less of every turn.
  auto const & info = box->GetInfo();
  bool poweredOn = false;
  if (info && info->m_powerOns)
  {
    poweredOn = SaveBoxPowerOns(m_storage, info->m_id, *info->m_powerOns);
    if (poweredOn)
      LOG(LINFO, ("The box", info->m_id, "was powered on", *info->m_powerOns, "times, it is to be calibrated"));
  }
  // A box that doesn't count its power-ons: its journal tells how it has started. Not before the box tells
  // about itself, not to ask twice.
  else if (auto const powerOn = box->GetPowerOn(); info && powerOn)
  {
    auto const saved = m_storage.Get<int64_t>(Storage::kBoxPowerOnTime, 0);
    double const tolerance = kSamePowerOnMs + kBoxClockError * powerOn->m_uptimeMs;
    poweredOn = std::fabs(static_cast<double>(powerOn->m_unixMs - saved)) > tolerance;
    if (poweredOn)
    {
      LOG(LINFO, ("The box was powered on", powerOn->m_uptimeMs / 1000, "s ago, it is to be calibrated"));
      m_storage.Set(Storage::kBoxPowerOnTime, powerOn->m_unixMs);
    }
  }
  if (poweredOn)
  {
    m_storage.Set(Storage::kBoxCalibrationAdvised, true);
    m_boxCalibrationAdvicePending = true;
  }

  // The box is calibrated while the car stands.
  if (m_boxCalibrationAdvicePending && m_inertial->GetSpeedKmh() <= 0)
  {
    m_boxCalibrationAdvicePending = false;
    Notify(Event::BoxCalibrationAdvised);
  }
}

void Engine::OnGpsSpoofingChanged(bool spoofed)
{
  LOG(LWARNING, ("GPS spoofed =", spoofed));
  Notify(spoofed ? Event::GpsSpoofed : Event::GpsRestored);
  if (spoofed)
    m_manualUntilGps = false;

  if (spoofed && (m_map.IsNavigating() || (m_inertial && m_inertial->IsReady())))
  {
    EnterManualModeByItself("GPS is spoofed");
    return;
  }

  // Replace the spoofed position with the network one right away instead of waiting for the next update.
  if (spoofed && !m_manualMode && m_networkLocation)
  {
    m_savedLocation = m_networkLocation;
    NotifyLocationUpdated();
  }
}

void Engine::RebuildRouteIfOffRoute(Fix const & location)
{
  // The core knows where the car goes from the GPS track, a position set by hand or calculated has no
  // track, so its direction is passed, otherwise the route can turn the car around.
  auto const source = SourceOf(location);
  bool const hasDirection =
      location.m_bearingDeg && (source == PositionSource::Manual || source == PositionSource::Inertial);
  double const offRouteDistanceM = source == PositionSource::Manual
                                     ? kManualOffRouteDistanceM
                                     : std::max(location.m_accuracyM, kMinOffRouteDistanceM);
  m_map.RebuildRouteIfOffRoute(location, offRouteDistanceM, hasDirection ? location.m_bearingDeg : std::nullopt);
}

void Engine::SaveTrustedPosition()
{
  // After a restart a spoofed position may come first, it is checked against the last trusted one.
  auto const trusted = m_spoofingDetector.GetLastTrusted();
  if (!trusted || trusted->m_timeMs - m_savedTrustedTimeMs < kSaveTrustedIntervalMs)
    return;
  m_savedTrustedTimeMs = trusted->m_timeMs;
  int64_t const unixTimeMs = m_clock.UnixNowMs() - (m_clock.NowMs() - m_savedTrustedTimeMs);
  char buf[96];
  std::snprintf(buf, sizeof(buf), "%.7f,%.7f,%lld", trusted->m_position.m_lat, trusted->m_position.m_lon,
                static_cast<long long>(unixTimeMs));
  m_storage.Set(Storage::kLastTrusted, std::string(buf));
}

void Engine::RestoreTrustedPosition()
{
  auto const saved = m_storage.Get<std::string>(Storage::kLastTrusted, "");
  auto const parts = strings::Tokenize(saved, ",");
  double lat, lon;
  int64_t unixTimeMs;
  if (parts.size() != 3 || !strings::to_double(parts[0], lat) || !strings::to_double(parts[1], lon) ||
      !strings::to_int(parts[2], unixTimeMs))
  {
    if (!saved.empty())
      LOG(LERROR, ("Wrong last trusted position =", saved));
    return;
  }
  int64_t const timeMs = m_clock.NowMs() - (m_clock.UnixNowMs() - unixTimeMs);
  m_spoofingDetector.RestoreTrusted({lat, lon}, timeMs);
  LOG(LINFO, ("Last trusted position =", saved));
}

void Engine::SaveCarPosition(bool now)
{
  // Cell tower positions are hundreds of meters off, the place known before them is kept.
  if (!m_savedLocation || SourceOf(*m_savedLocation) == PositionSource::Network)
    return;
  // The car maneuvering off the roads is not where its mark waits.
  auto position = m_savedLocation->m_position;
  if (m_inertial && IsInertialNavigationEnabled())
    if (auto const & car = m_inertial->GetOffRoadCar())
      position = *car;
  bool const stands = m_carSecondAgo && Distance(position, *m_carSecondAgo) < kCarStandsM;
  m_carSecondAgo = position;

  // GPS absent since the restart is not untrusted.
  bool const gpsUntrusted = m_manualMode && !m_manualUntilGps;
  // The calculated place is not known better on the next trip: a trip ended 5 km after the known place was 115 m off.
  double wayM = 0;
  double accuracyM = DeadReckoning::kBaseAccuracyM;
  if (m_inertial && SourceOf(*m_savedLocation) == PositionSource::Inertial)
  {
    wayM = m_inertial->GetDistanceSinceFix();
    accuracyM = m_savedLocation->m_accuracyM;
  }
  char buf[128];
  std::snprintf(buf, sizeof(buf), "%.7f,%.7f,%s,%d,%.0f,%.0f", position.m_lat, position.m_lon,
                FormatOptional(GetCarBearing()).c_str(), gpsUntrusted ? 1 : 0, wayM, accuracyM);
  if (buf == m_savedCar || (!now && !stands && MsSince(m_carSavedMs) < kSaveCarIntervalMs))
    return;
  m_savedCar = buf;
  m_carSavedMs = m_clock.NowMs();
  m_storage.Set(Storage::kCarPosition, m_savedCar + "," + std::to_string(m_clock.UnixNowMs()));
}

void Engine::RestoreCarPosition(bool otherCar)
{
  // The engine that has worked keeps the car itself, e.g. after the app was in the background.
  if (!otherCar && (m_savedLocation || m_manualMode))
    return;
  auto const saved = m_storage.Get<std::string>(Storage::kCarPosition, "");
  auto const parts = strings::Tokenize(saved, ",");
  double lat, lon, bearing = 0;
  int manual;
  // Saved before the way since the known place was.
  bool const withWay = parts.size() == 7;
  double wayM = 0;
  double accuracyM = DeadReckoning::kBaseAccuracyM;
  int64_t unixTimeMs;
  if ((parts.size() != 5 && !withWay) || !strings::to_double(parts[0], lat) || !strings::to_double(parts[1], lon) ||
      (parts[2] != "-" && !strings::to_double(parts[2], bearing)) || !strings::to_int(parts[3], manual) ||
      (withWay && (!strings::to_double(parts[4], wayM) || !strings::to_double(parts[5], accuracyM))) ||
      !strings::to_int(parts.back(), unixTimeMs))
  {
    if (!saved.empty())
      LOG(LERROR, ("Wrong car position =", saved));
    return;
  }
  LOG(LINFO, ("The car is where it was left =", saved));

  // GPS may be gone since: the car is shown where it was, as if the user has marked it there.
  SetManualMode(true);
  m_manualUntilGps = manual == 0;
  Fix location;
  location.m_provider = Provider::Manual;
  location.m_position = {lat, lon};
  location.m_accuracyM = kManualAccuracyM;
  if (parts[2] != "-")
    location.m_bearingDeg = bearing;
  location.m_timeMs = m_clock.NowMs();
  location.m_unixTimeMs = m_clock.UnixNowMs();
  m_manualLocation = location;
  // The mark is as old as the save. The clock of the phone may have been put back since.
  m_manualSetTimeMs = m_clock.NowMs() - std::max<int64_t>(0, m_clock.UnixNowMs() - unixTimeMs);
  m_lastPositionSource = PositionSource::Manual;
  m_savedCar = saved.substr(0, saved.rfind(','));
  m_parkedAt = location.m_position;
  if (m_inertial)
    StartInertialAtMark(wayM, accuracyM);
}

void Engine::OnCarChanged()
{
  if (m_inertial)
    m_inertial->RestoreCalibration();
  // The table of another car: its ranges are not measured now.
  m_measuredSpeedRanges.reset();
  // The place saved is of the car before: the mark left where it is, the new car gets it too.
  m_savedCar.clear();
  MoveParkedCar();
  OnParkedCarsChanged();
}

void Engine::OnParkedCarsChanged()
{
  if (m_parkedCarsListener)
    m_parkedCarsListener();
}

std::vector<Car> Engine::GetParkedCars() const
{
  auto cars = m_cars.GetCars();
  auto const current = m_cars.GetCurrentCar();
  std::erase_if(cars, [&current](Car const & car) { return car.m_id == current || !car.m_parkedAt; });
  return cars;
}

void Engine::SetPotholesFile(std::string const & path)
{
  m_potholesFile = path;
  m_potholes.Load(path);
  if (m_potholesListener)
    m_potholesListener();
}

std::optional<ms::LatLon> Engine::GetPotholePlace() const
{
  switch (GetPositionSource())
  {
  // GPS comes once a second: the mark is shown between its positions too, see ShowBetweenGpsPositions().
  case PositionSource::Gps: return m_shownPosition;
  case PositionSource::Inertial:
    // The mark waits on the road while the car is elsewhere.
    if (m_inertial->IsRoadLost() || m_inertial->GetOffRoadCar())
      return {};
    return m_shownPosition;
  case PositionSource::None:
  case PositionSource::Network:
  case PositionSource::Manual: return {};
  }
  UNREACHABLE();
}

void Engine::OnJolt(double joltMs2, int speedKmh)
{
  auto const hit = m_potholeDetector.OnSample(m_clock.NowMs(), joltMs2, speedKmh, GetPotholePlace());
  if (!hit)
    return;
  int const pct = PotholeStore::ToPct(hit->m_joltMs2);
  auto const added = m_potholes.Add(hit->m_place, pct, m_clock.UnixNowMs());
  char buf[128];
  std::snprintf(buf, sizeof(buf), "%d %.1f %.6f,%.6f %d %s %d", pct, hit->m_joltMs2, hit->m_place.m_lat,
                hit->m_place.m_lon, hit->m_speedKmh, added.m_merged ? "merged" : "new", added.m_pothole.m_hits);
  LOG(LINFO, ("POTHOLE", buf));
  if (!m_potholesFile.empty() && !m_potholes.Save(m_potholesFile))
    LOG(LWARNING, ("Can't save the potholes to", m_potholesFile));
  if (m_potholesListener)
    m_potholesListener();
}

bool Engine::MoveParkedCar()
{
  // The mark has moved since the start: the car is there, whatever box it has. A phone that shows no car yet, e.g. one
  // that was not in this car, shows it where it was left.
  bool const parked = m_parkedAt && m_manualMode && m_manualLocation && m_manualLocation->m_position == *m_parkedAt;
  if (!parked && (m_savedLocation || m_manualLocation))
    return false;
  // A new car has no place yet: the user marks it.
  if (m_storage.Get<std::string>(Storage::kCarPosition, "").empty())
    return false;
  RestoreCarPosition(true /* otherCar */);
  if (m_active)
    ApplyManualLocation();
  return true;
}

void Engine::OnBoxHeard(std::string const & id, std::string const & firmware)
{
  auto const before = m_cars.GetCurrentCar();
  if (id != before)
  {
    m_inertial->SaveCalibration();
    // The car before is left where it is shown, not where it was saved the last time while it drove.
    SaveCarPosition(true /* now */);
  }
  m_cars.OnBoxHeard(id, firmware, m_clock.UnixNowMs());
  if (m_cars.GetCurrentCar() != before)
  {
    LOG(LINFO, ("The car of the box", id, "was", before.empty() ? "-" : before));
    OnCarChanged();
  }
  if (auto * box = m_inertial->GetEsp32(); box && box->CanStoreCarValues() && id == m_cars.GetCurrentCar())
    m_boxCarValues.OnBoxHeard(*box, id);
  else
    m_boxCarValues.Forget();
}

void Engine::OnBoxCarValues(std::map<std::string, std::string> const & values)
{
  auto * box = m_inertial->GetEsp32();
  CHECK(box, ());
  auto const taken = m_boxCarValues.OnValues(*box, values);
  // The marks of the parked cars show their names.
  if (taken.m_name)
    OnParkedCarsChanged();
  // The user may have chosen another car meanwhile.
  if (m_boxCarValues.GetCarId() != m_cars.GetCurrentCar())
    return;
  if (taken.m_calibration)
  {
    // Measured with another phone.
    m_inertial->RestoreSpeedCalibration();
    m_measuredSpeedRanges.reset();
  }
  // The car shown elsewhere, e.g. marked by the user before the box has connected, is there: its place is newer.
  if (taken.m_position && !MoveParkedCar())
  {
    m_savedCar.clear();
    SaveCarPosition(true /* now */);
  }
}

void Engine::OnBoxCarWritten(std::string const & key, std::string const & value, std::string const & error)
{
  m_boxCarValues.OnWritten(key, value, error);
}

void Engine::OnThisPhoneRemoved()
{
  LOG(LINFO, ("This phone is removed from the box of the car", m_cars.GetCurrentCar()));
  m_phoneRemovedTimer.Start(0, [this] { m_delegate.OnEvent(Event::ThisPhoneRemoved); });
}

std::vector<Sprint> Engine::GetSprints() const
{
  auto sprints = ParseSprints(m_storage.Get<std::string>(Storage::kSprints, ""));
  std::reverse(sprints.begin(), sprints.end());
  return sprints;
}

void Engine::OnSprint(SprintTimer::Result const & result)
{
  Sprint const sprint{result.m_kind, m_clock.UnixNowMs(), std::round(result.m_sec * 100) / 100,
                      static_cast<int>(std::lround(result.m_trapKmh))};
  auto const saved = m_storage.Get<std::string>(Storage::kSprints, "");
  std::optional<double> best;
  for (auto const & before : ParseSprints(saved))
    if (before.m_kind == sprint.m_kind && (!best || before.m_sec < *best))
      best = before.m_sec;
  m_storage.Set(Storage::kSprints, (saved.empty() ? "" : saved + ",") + SerializeSprint(sprint));
  m_lastSprint = sprint;
  m_lastSprintBestSec = best.value_or(0);
  m_lastSprintRecord = !best || sprint.m_sec < *best;
  LOG(LINFO, ("SPRINT", "kind=" + DebugPrint(sprint.m_kind), "sec=" + strings::to_string_dac(sprint.m_sec, 2),
              "trap=" + std::to_string(sprint.m_trapKmh), std::string("record=") + (m_lastSprintRecord ? "1" : "0"),
              "best=" + (best ? strings::to_string_dac(*best, 2) : std::string("-"))));
  Notify(Event::SprintMeasured);
}

void Engine::ListBoxPhones()
{
  if (auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr)
    box->ListPhones();
}

void Engine::ForgetBoxPhone(std::string const & address)
{
  if (auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr)
    box->ForgetPhone(address);
}

void Engine::StartAddPhone()
{
  if (auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr)
    box->StartAddPhone();
}

void Engine::EndAddPhone()
{
  if (auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr)
    box->EndAddPhone();
}

void Engine::OnBoxStopping()
{
  SaveBoxCarValues(true /* now */);
}

void Engine::SaveBoxCarValues(bool now)
{
  auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr;
  // The box sleeps a minute after the engine is stopped: where the car is left is written before.
  auto const car = box ? box->GetCarInfo() : std::nullopt;
  bool const engineStopped = car && car->m_engineRunning == false;
  now = now || (engineStopped && !m_boxEngineStopped);
  m_boxEngineStopped = engineStopped;
  m_boxCarValues.Save(box, now);
}

void Engine::RenameCar(std::string const & id, std::string const & name)
{
  m_cars.RenameCar(id, name);
  SaveBoxCarValues(true /* now */);
  OnParkedCarsChanged();
}

void Engine::SelectCar(std::string const & id)
{
  auto const before = m_cars.GetCurrentCar();
  if (id == before)
    return;
  if (m_inertial)
    m_inertial->SaveCalibration();
  SaveCarPosition(true /* now */);
  if (!m_cars.SelectCar(id))
    return;
  LOG(LINFO, ("The user drives the car", id, "was", before.empty() ? "-" : before));
  OnCarChanged();
  // The box connected is of the car before: the platform looks for the box of this one.
  if (m_inertial && IsInertialNavigationEnabled())
    m_inertial->Start();
}

void Engine::ForgetCar(std::string const & id)
{
  bool const current = id == m_cars.GetCurrentCar();
  // What is learned is saved to the car before it is forgotten, not after.
  if (current && m_inertial)
    m_inertial->Stop();
  m_cars.ForgetCar(id);
  if (!current)
  {
    OnParkedCarsChanged();
    return;
  }
  if (m_cars.GetCars().empty())
  {
    SetInertialNavigationEnabled(false);
    OnParkedCarsChanged();
    return;
  }
  LOG(LINFO, ("The car forgotten, the car now is", m_cars.GetCurrentCar()));
  OnCarChanged();
  if (m_inertial && IsInertialNavigationEnabled())
    m_inertial->Start();
}

void Engine::StartInertialAtMark(double distanceSinceFixM, double accuracyM)
{
  // The car is not put on a road again: it may stand in a yard. Without the heading it looks along its road.
  if (m_manualLocation->m_bearingDeg)
    m_inertial->SetHeading(*m_manualLocation->m_bearingDeg, InertialNavigator::HeadingSource::Road);
  m_inertial->SetPosition(m_manualLocation->m_position, distanceSinceFixM, accuracyM);
}

bool Engine::IsInertialNavigationEnabled() const
{
  return m_boxSearched || m_storage.IsInertialEnabled();
}

void Engine::SetInertialNavigationEnabled(bool enabled)
{
  m_boxSearched = enabled && !m_storage.IsInertialEnabled();
  LOG(LINFO, ("Box set up by the user =", enabled, "searched =", m_boxSearched));
  if (!m_boxSearched)
    m_storage.Set(Storage::kInertialEnabled, enabled);
  if (enabled)
  {
    StartInertialNavigation();
    return;
  }
  if (m_inertial)
    m_inertial->Stop();
  // Nothing else would drive the car, the box was the only source.
  SetGpsDisabled(false);
}

void Engine::SetElm327Address(std::string const & address)
{
  LOG(LINFO, ("address =", address));
  m_storage.Set(Storage::kElm327Address, address);
  if (IsInertialNavigationEnabled() && m_inertial)
    m_inertial->Start();
}

void Engine::SetEsp32Source(bool esp32)
{
  LOG(LINFO, ("esp32 =", esp32));
  m_storage.Set(Storage::kEsp32Source, esp32);
  // The car of the adapter is not known: the car of the box is left.
  OnParkedCarsChanged();
  if (IsInertialNavigationEnabled() && m_inertial)
    m_inertial->Start();
}

void Engine::Calibrate()
{
  if (m_inertial)
    m_inertial->Calibrate();
}

void Engine::CalibrateWhenStill()
{
  auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr;
  if (!box || box->GetBleState() != BleState::Connected || box->IsReadOnly())
    return;
  LOG(LINFO, ("Calibrate when the car stands still"));
  m_calibrationArmed = true;
  m_calibrationFailures = 0;
  // A calibration started from the page is followed, not started again.
  m_calibrationSent = box->GetCalibrationState() == CalibrationState::Calibrating;
  m_calibrateWaitMs = m_clock.NowMs();
  CheckCalibrateWhenStill();
}

void Engine::CancelCalibrateWhenStill()
{
  m_calibrationArmed = false;
  m_calibrateTimer.Stop();
}

std::vector<int> Engine::GetBoxShake() const
{
  auto const * box = m_inertial ? m_inertial->GetEsp32() : nullptr;
  return box ? box->GetShake() : std::vector<int>{};
}

void Engine::CheckCalibrateWhenStill()
{
  if (!m_calibrationArmed)
    return;
  auto * box = m_inertial ? m_inertial->GetEsp32() : nullptr;
  int64_t const now = m_clock.NowMs();
  bool lost = !box || box->GetBleState() != BleState::Connected || box->IsReadOnly();
  if (!lost && m_calibrationSent)
  {
    auto const state = box->GetCalibrationState();
    if (state == CalibrationState::LinkLost)
      lost = true;
    else if (state != CalibrationState::Calibrating)
    {
      m_calibrationSent = false;
      if (state != CalibrationState::FailedMoving)
      {
        LOG(LINFO, ("The calibration of the box has ended:", state));
        CancelCalibrateWhenStill();
        return;
      }
      LOG(LINFO, ("The car has moved during the calibration, wait for it to stand"));
      m_calibrateWaitMs = now;
      ++m_calibrationFailures;
    }
  }
  if (lost || m_calibrationFailures >= kCalibrateWhenStillMaxFailures ||
      (!m_calibrationSent && now - m_calibrateWaitMs >= kCalibrateWhenStillTimeoutMs))
  {
    LOG(LINFO, ("The calibration of the box when still is cancelled, lost =", lost));
    CancelCalibrateWhenStill();
    return;
  }
  if (!m_calibrationSent && box->IsStill())
  {
    m_inertial->Calibrate();
    m_calibrationSent = true;
  }
  m_calibrateTimer.Start(kCalibrateWhenStillIntervalMs, [this] { CheckCalibrateWhenStill(); });
}

void Engine::ClearSpeedCalibration()
{
  if (!m_inertial)
    return;
  m_inertial->ClearSpeedCalibration();
  SaveBoxCarValues(true /* now */);
}

void Engine::SetFirmwares(std::vector<Firmware> firmwares)
{
  m_firmwares = std::move(firmwares);
}

Firmware const * Engine::FindBoxFirmware()
{
  auto * box = m_inertial && IsInertialNavigationEnabled() ? m_inertial->GetEsp32() : nullptr;
  if (!box || !box->CanUpdate())
    return nullptr;
  auto const & info = *box->GetInfo();
  auto const it = std::find_if(m_firmwares.begin(), m_firmwares.end(), [&info](Firmware const & firmware)
  { return firmware.m_chip == info.m_chip && firmware.m_board == info.m_board; });
  return it != m_firmwares.end() ? &*it : nullptr;
}

void Engine::StartFirmwareUpdate()
{
  m_firmwareOfferPending = false;
  if (auto const * firmware = FindBoxFirmware())
    m_inertial->GetEsp32()->StartUpdate(*firmware);
}

void Engine::FirmwareOfferShown()
{
  m_firmwareOfferPending = false;
}

void Engine::CancelFirmwareUpdate()
{
  if (m_inertial && m_inertial->GetEsp32())
    m_inertial->GetEsp32()->CancelUpdate();
}

void Engine::ReverseDirection()
{
  auto const from = m_savedLocation;
  auto const bearing = GetCarBearing();
  if (!from || !bearing)
    return;

  double const reversed = Normalize(*bearing + 180);
  LOG(LINFO, ("Reversed the car to", std::round(reversed)));
  if (m_inertial)
  {
    // The other roads were the car's way, not the other one.
    m_inertial->DropOtherMarks();
    m_inertial->SetHeading(reversed, InertialNavigator::HeadingSource::Road);
  }
  if (m_manualLocation)
    m_manualLocation->m_bearingDeg = reversed;
  // The crossings the position has stopped at are on the other side now.
  std::swap(m_shiftStopForward, m_shiftStopBack);

  Fix location = *from;
  location.m_bearingDeg = reversed;
  location.m_timeMs = m_clock.NowMs();
  location.m_unixTimeMs = m_clock.UnixNowMs();
  m_savedLocation = location;
  // The route goes the other way now.
  RebuildRouteIfOffRoute(location);
  NotifyLocationUpdated();
  SharePlace(PeerTrigger::PlaceSet, 'R', location);
}

void Engine::SwitchMark()
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  LOG(LINFO, ("Switching the mark"));
  // The navigator tells by OnMarkSwitched().
  if (m_inertial)
    m_inertial->SwitchMark();
}

void Engine::OnMarkSwitched()
{
  auto const location = m_inertial->GetLocation();
  if (!location || !IsInertialActive())
    return;
  m_savedLocation = *location;
  if (m_manualLocation)
  {
    m_manualLocation->m_position = location->m_position;
    m_manualLocation->m_bearingDeg = location->m_bearingDeg;
  }
  // The car is on another road now: the route goes from there, as from a mark of the user.
  m_besideRouteSinceMs.reset();
  m_wasOnRouteRoad = true;
  m_map.RebuildRouteIfOffRoute(*location, kManualOffRouteDistanceM, location->m_bearingDeg);
  NotifyLocationUpdated();
  SharePlace(PeerTrigger::PlaceSet, 'W', *location);
}

std::optional<double> Engine::GetCarBearing() const
{
  if (m_inertial && IsInertialNavigationEnabled())
    if (auto const heading = m_inertial->GetHeading())
      return heading;
  if (m_savedLocation && m_savedLocation->m_bearingDeg)
    return m_savedLocation->m_bearingDeg;
  return {};
}

int Engine::GetSpeedLimitKmh()
{
  if (!m_savedLocation)
    return -1;
  auto const & position = m_savedLocation->m_position;
  auto const bearingDeg = GetCarBearing();
  if (m_speedLimit && m_speedLimit->m_position == position && m_speedLimit->m_bearingDeg == bearingDeg)
    return m_speedLimit->m_kmh;

  auto const road = m_map.GetRoads(false /* matchRoute */).Snap(position, bearingDeg, kSpeedLimitRoadM);
  // Not kept: the map of the place may come later.
  if (!road || Distance(position, road->m_point) > kSpeedLimitRoadM)
    return -1;
  int kmh = -1;
  auto const maxspeed = m_map.GetMaxspeed(road->m_featureId);
  // Without a direction the way the car goes along the road is not known.
  if (bearingDeg || !maxspeed.IsBidirectional())
  {
    // Without the time the conditional limit is not taken, it is not shown.
    auto const speed = maxspeed.GetCurrentSpeed(0 /* time */, road->m_forward);
    if (speed.GetSpeed() == routing::kNoneMaxSpeed)
      kmh = 0;
    else if (speed.IsNumeric())
      kmh = speed.GetSpeedKmPH();
  }
  m_speedLimit = SpeedLimit{position, bearingDeg, kmh};
  return kmh;
}

bool Engine::IsCarHeadingShown() const
{
  if (!GetCarBearing())
    return false;
  if (m_manualMode)
    return true;
  return m_inertial && IsInertialNavigationEnabled() && MsSince(m_lastTrustedGpsMs) >= kGpsFreshMs;
}

void Engine::ShowCarHeading()
{
  if (IsCarHeadingShown())
    m_map.ShowCarHeading(*GetCarBearing());
}

void Engine::NotifyLocationUpdated()
{
  CHECK(m_savedLocation, ());
  m_delegate.OnPosition(*m_savedLocation);
  m_shownPosition = m_savedLocation->m_position;
  ShowCarHeading();
}

void Engine::ShowBetweenGpsPositions(Fix const & inertial)
{
  // A shown GPS position the inertial navigation has not started from, e.g. a less accurate one, is not where it
  // continues from: the mark would jump between the two. Without a reliable bearing of GPS the inertial navigation may
  // go another way than GPS, e.g. take a starting car for one driving back, and a slow car jumps little anyway.
  if (!m_savedLocation || SourceOf(*m_savedLocation) != PositionSource::Gps || !m_lastTrustedGpsTimeMs ||
      m_savedLocation->m_timeMs > *m_lastTrustedGpsTimeMs || !InertialNavigator::HasGoodBearing(*m_savedLocation) ||
      m_inertial->IsDrivingBack())
  {
    return;
  }
  Fix location = inertial;
  // As in the manual mode: the mark follows the car maneuvering off the roads.
  if (auto const & car = m_inertial->GetOffRoadCar())
    location.m_position = *car;
  // As accurate as GPS was, less with every meter driven since.
  location.m_accuracyM = m_savedLocation->m_accuracyM +
                         DeadReckoning::kAccuracyPerMeter * Distance(m_savedLocation->m_position, location.m_position);
  location.m_unixTimeMs = UnixTimeAfterGps(location.m_timeMs);
  ++m_positionsBetweenGps;
  m_delegate.OnPosition(location);
  m_shownPosition = location.m_position;
}

int64_t Engine::UnixTimeAfterGps(int64_t timeMs) const
{
  // The GPS position comes a bit after it was taken, and the car is followed from it since it came.
  return m_savedLocation->m_unixTimeMs + (timeMs - m_fixShownMs);
}

void Engine::StartInertialNavigation()
{
  if (!IsInertialNavigationEnabled())
    return;
  if (!m_inertial)
  {
    InertialNavigator::Listener & listener = *this;
    m_inertial = std::make_unique<InertialNavigator>(m_delegate, m_scheduler, m_clock, m_storage,
                                                     m_map.GetRoads(true /* matchRoute */), listener);
    // The box set up while the car stands at a mark drives it from there: the manual mode gives it no GPS position
    // to start from, and the mark would stand still while the car drives.
    if (m_manualMode && m_manualLocation)
      StartInertialAtMark();
  }
  m_inertial->Start();
}

void Engine::SaveHeardBox()
{
  if (!m_boxSearched)
    return;
  auto const state = m_inertial->GetSourceState();
  if (state == SourceState::Disconnected || state == SourceState::Connecting)
    return;
  LOG(LINFO, ("Box heard, saved as set up"));
  m_boxSearched = false;
  m_storage.Set(Storage::kInertialEnabled, true);
}

bool Engine::IsInertialActive() const
{
  return m_inertial && MsSince(m_lastInertialUsedMs) < kInertialActiveMs;
}

void Engine::OnInertialLocation(Fix const & inertial)
{
  if (!m_active)
    return;
  // Trusted GPS is better, the inertial navigation shows the car between its positions only. In the manual mode GPS
  // is ignored, so the inertial navigation is used. The manual mode just left by the user waits for GPS a while,
  // otherwise it would come back before the first GPS position.
  if (!m_manualMode && (MsSince(m_lastTrustedGpsMs) < kGpsFreshMs || GetGpsSilenceMs() < kGpsLostMs))
  {
    ShowBetweenGpsPositions(inertial);
    return;
  }

  // The car is not followed by GPS any more, the user sees it by the manual mode and can mark the car.
  EnterManualModeByItself("GPS is lost, the inertial navigation continues");
  // The car has driven away from where GPS was trusted: GPS is to agree with it now, as after any mark.
  if (inertial.m_speedMps.value_or(0) > 0)
    m_manualUntilGps = false;
  m_lastInertialUsedMs = m_clock.NowMs();
  // The mark follows the car maneuvering off the roads, also on a route: a mark waiting on the road of the route
  // hides that the car has left it. The core rebuilds the route once the car goes away from it farther than
  // 50 m or the accuracy of the position, as for GPS.
  Fix location = inertial;
  if (auto const & car = m_inertial->GetOffRoadCar())
    location.m_position = *car;
  // The mark follows the car: when the inertial navigation stops, e.g. the adapter is disconnected, the car
  // stays where it has been driven to, not at the old mark behind.
  if (m_manualLocation)
  {
    m_manualLocation->m_position = location.m_position;
    if (location.m_bearingDeg)
      m_manualLocation->m_bearingDeg = location.m_bearingDeg;
  }
  m_savedLocation = location;
  if (m_lastPositionSource != PositionSource::Inertial)
    RebuildRouteIfOffRoute(location);
  else
    LeaveRouteIfBesideIt(location);
  m_lastPositionSource = PositionSource::Inertial;
  NotifyLocationUpdated();
}

void Engine::LeaveRouteIfBesideIt(Fix const & inertial)
{
  // The core takes a car for one on the route while it is nearer to the route than its position may be wrong,
  // 50 m and more, and shows it on the route. The mark on a road is wrong along the road and not across it: a
  // car driving along a road beside the route has left the route. On October 13 the car was shown on the route
  // for 26 s where another road goes beside it, 20-40 m apart.
  bool const alongRoad = m_inertial->IsOnRoad() && !m_inertial->IsTurning() && !m_inertial->GetOffRoadCar() &&
                         inertial.m_bearingDeg && inertial.m_speedMps.value_or(0) > 0 && m_map.IsNavigating();
  auto const aside =
      alongRoad ? m_map.GetRouteAside(inertial.m_position, *inertial.m_bearingDeg) : std::optional<double>();
  // A car farther from the route than its position may be wrong is seen leaving the route by the core.
  if (!aside || std::fabs(*aside) <= kBesideRouteM ||
      std::fabs(*aside) > std::max(inertial.m_accuracyM, kMinOffRouteDistanceM))
  {
    m_besideRouteSinceMs.reset();
    if (aside && std::fabs(*aside) <= kOnRouteRoadM)
      m_wasOnRouteRoad = true;
    return;
  }
  if (!m_wasOnRouteRoad)
    return;
  if (!m_besideRouteSinceMs)
    m_besideRouteSinceMs = m_clock.NowMs();
  if (MsSince(m_besideRouteSinceMs) < kBesideRouteMs)
    return;

  LOG(LINFO, ("The car drives along a road", std::round(*aside), "m beside the route, the route is left"));
  m_besideRouteSinceMs.reset();
  m_wasOnRouteRoad = false;
  m_map.LeaveRoute(inertial);
}

void Engine::OnRoadLost()
{
  Notify(Event::RoadLost);
}

void Engine::OnTurnsReversed()
{
  Notify(Event::TurnsReversed);
}

bool Engine::TrackWorkingGps(Fix const & location)
{
  bool const goodGps = SourceOf(location) == PositionSource::Gps && AgeMs(location) <= kGpsMaxAgeMs &&
                       IsAccuracySatisfied(location) && location.m_accuracyM <= kGpsMaxAccuracyM;
  if (goodGps)
  {
    // A position given twice tells nothing about how often they come.
    if (!m_lastGoodGps)
      m_lastGoodGpsGapMs = std::numeric_limits<int64_t>::max();
    else if (location.m_timeMs != m_lastGoodGps->m_timeMs)
      m_lastGoodGpsGapMs = location.m_timeMs - m_lastGoodGps->m_timeMs;
    m_lastGoodGps = location;
  }
  return goodGps;
}

void Engine::SetGpsDisabled(bool disabled)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  LOG(LINFO, ("GPS ignored by the user =", disabled));
  m_gpsDisabled = disabled;
  m_storage.Set(Storage::kGpsDisabled, disabled);
  // GPS ignored by the user is not trusted anew by its first position when it is used again.
  if (disabled)
    m_manualUntilGps = false;
}

void Engine::SetManualMode(bool enabled)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  if (m_manualMode == enabled)
    return;

  LOG(LINFO, ("Manual mode =", enabled));
  m_manualMode = enabled;
  m_manualForNoPosition = false;
  m_manualUntilGps = false;
  if (!enabled)
    m_manualLeftMs = m_clock.NowMs();
  m_manualLocation.reset();
  m_acceptNextLocation = !enabled;
  m_gpsReturnDetector.Reset();
  m_offRoadGpsCount = 0;
  m_manualRepeatTimer.Stop();
  Notify(Event::ManualModeChanged);
}

bool Engine::SetManualLocation(ms::LatLon const & position)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  CHECK(m_manualMode, ("Manual mode is off"));
  auto const road = FindMarkRoad(position, GetCarBearing());
  if (!road)
    return false;
  PutMark(position, *road);
  return true;
}

void Engine::SetMarkByTap(bool armed)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  LOG(LINFO, ("armed =", armed));
  m_markByTap = armed;
}

bool Engine::PlaceMarkByTap(ms::LatLon const & position)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  // Without a road there the next tap still shows where the car is: the user taps the road once more.
  auto const road = FindMarkRoad(position, GetCarBearing());
  if (!road)
  {
    Notify(Event::MarkNoRoad);
    return false;
  }
  // GPS may work: the mark tells that it is wrong, as the manual mode turned on by the user did.
  SetManualMode(true);
  PutMark(position, *road);
  m_markByTap = false;
  return true;
}

bool Engine::PlaceMarkByGps()
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  auto const fail = [](std::string const & why)
  {
    LOG(LINFO, ("GPS can't place the mark:", why));
    return false;
  };
  // An old GPS fix does not hide a fresh fused one: the newer of the two is taken.
  auto const & fix = m_rawGps && m_rawFused ? (m_rawGps->m_timeMs >= m_rawFused->m_timeMs ? m_rawGps : m_rawFused)
                                            : (m_rawGps ? m_rawGps : m_rawFused);
  if (!fix)
    return fail("no fix");
  if (m_gpsDisabled)
    return fail("GPS is turned off");
  if (m_spoofingDetector.IsSpoofed())
    return fail("GPS is spoofed");
  if (AgeMs(*fix) > kGpsMaxAgeMs)
    return fail("the fix is " + std::to_string(AgeMs(*fix)) + " ms old");
  if (fix->m_accuracyM > kGpsMarkMaxAccuracyM)
    return fail("the fix accuracy is " + std::to_string(std::lround(fix->m_accuracyM)) + " m");
  if (!m_savedLocation)
    return fail("no mark");
  double const drivenM = m_inertial ? m_inertial->GetUserNeededDrivenM() : 0;
  double const maxM = drivenM + m_savedLocation->m_accuracyM + fix->m_accuracyM + kGpsMarkMarginM;
  double const awayM = Distance(m_savedLocation->m_position, fix->m_position);
  if (awayM > maxM)
    return fail("the fix is " + std::to_string(std::lround(awayM)) + " m from the mark, up to " +
                std::to_string(std::lround(maxM)) + " m");

  double const radiusM = std::clamp(fix->m_accuracyM, kManualSnapRadiusM, kGpsMarkMaxSnapM);
  auto const road = FindMarkRoad(fix->m_position, GetCarBearing(), radiusM);
  if (!road)
    return fail("no road near the fix");
  SetManualMode(true);
  PutMark(fix->m_position, *road, std::max(kManualAccuracyM, fix->m_accuracyM));
  m_markByTap = false;
  return true;
}

std::optional<RoadPoint> Engine::FindMarkRoad(ms::LatLon const & position, std::optional<double> heading,
                                              double radiusM)
{
  // The car stands on the axis of a road and looks one of its two ways: the way it has looked before, the
  // user turns it around with the reverse button. The gyroscope has followed the turns since.
  // While navigating, the car is on the route and drives the way the route goes.
  std::optional<RoadPoint> road;
  if (m_map.IsNavigating())
    road = m_map.ProjectToRoute(position, radiusM);
  // The car goes against the route: it has turned around, the road is taken the way the car goes.
  if (road && heading && std::fabs(AngleDiff(road->m_bearingDeg, *heading)) > 90)
    road.reset();
  // The route starts from a position off the roads with a piece across to the road, the car stands
  // along the road and not across it.
  if (road && !IsAlongRoad(road->m_point, road->m_bearingDeg))
    road.reset();
  if (!road)
    road = SnapMarkToRoad(position, heading, radiusM, m_savedLocation);
  if (!road)
    LOG(LINFO, ("No road at the tap =", position));
  return road;
}

void Engine::PutMark(ms::LatLon const & position, RoadPoint const & road, double accuracyM)
{
  Fix location;
  location.m_provider = Provider::Manual;
  location.m_position = road.m_point;
  location.m_accuracyM = accuracyM;
  location.m_bearingDeg = road.m_bearingDeg;
  location.m_timeMs = m_clock.NowMs();
  location.m_unixTimeMs = m_clock.UnixNowMs();
  LOG(LINFO, ("tap =", position, "location =", location.m_position, "bearing =", road.m_bearingDeg,
              "heading was =", GetCarBearing()));

  m_manualLocation = location;
  m_manualSetTimeMs = m_clock.NowMs();
  // The user shows that GPS is wrong, even if it was trusted before the restart.
  m_manualUntilGps = false;
  m_lastPositionSource = PositionSource::Manual;
  RebuildRouteIfOffRoute(location);
  // The mark looks along the road whatever the gyroscope has counted. A heading kept 18 degrees aside of the road
  // has drawn the car across it on October 10, and no tap could put it right.
  if (m_inertial)
    m_inertial->SetMarkOnRoad(road.m_point, road.m_bearingDeg);
  ApplyManualLocation();
  SharePlace(PeerTrigger::PlaceSet, 'T', location);
}

Esp32Source * Engine::GetBox()
{
  return m_inertial && IsInertialNavigationEnabled() ? m_inertial->GetEsp32() : nullptr;
}

void Engine::SharePlace(PeerTrigger trigger, char source, Fix const & place)
{
  auto * box = GetBox();
  if (!box || m_applyingPeer)
    return;
  box->SendPeer(trigger, {place.m_position, place.m_bearingDeg, place.m_accuracyM, source, AgeMs(place)});
}

void Engine::SharePlaceByTimer()
{
  m_peerTimer.Start(kPeerSnapshotIntervalMs, [this] { SharePlaceByTimer(); });
  // A cell-tower position is too rough to be taken for the place of the car.
  if (m_savedLocation && AgeMs(*m_savedLocation) <= kPositionStaleMs &&
      SourceOf(*m_savedLocation) != PositionSource::Network)
    SharePlace(PeerTrigger::Timer, m_manualMode ? 'M' : 'G', *m_savedLocation);
}

void Engine::OnPeerPlace(PeerPlace const & place)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  if (!m_active)
    return;
  if (place.m_kind == 'G')
  {
    // The follower's GPS goes through the checks of the own GPS: it may be spoofed too.
    Fix fix;
    fix.m_provider = Provider::Gps;
    fix.m_position = place.m_position;
    fix.m_accuracyM = place.m_accuracyM;
    fix.m_bearingDeg = place.m_bearingDeg;
    fix.m_timeMs = m_clock.NowMs();
    fix.m_unixTimeMs = m_clock.UnixNowMs();
    OnFix(fix);
    return;
  }
  ApplyPeerPlace(place);
}

void Engine::ApplyPeerPlace(PeerPlace const & place)
{
  // A place the user has set is where the car is. The leader tells the rest while the follower has no place of its
  // own or does not take it from GPS, and only when it differs.
  bool const set = place.m_source == 'T' || place.m_source == 'R' || place.m_source == 'W';
  if (!set && m_savedLocation && !m_manualMode)
    return;
  if (!set && m_savedLocation && Distance(m_savedLocation->m_position, place.m_position) <= kPeerMinDiffM)
    return;

  auto const road = FindMarkRoad(place.m_position, place.m_bearingDeg);
  if (!road)
  {
    LOG(LINFO, ("No road at the place of the other phone =", place.m_position));
    return;
  }
  LOG(LINFO, ("The place of the other phone, kind =", place.m_kind, "source =", place.m_source, "=", place.m_position));
  m_applyingPeer = true;
  SetManualMode(true);
  PutMark(place.m_position, *road);
  m_applyingPeer = false;
  // The leader has taken the correction: the follower is told the place it has.
  if (place.m_kind == 'C' && m_manualLocation)
    SharePlace(PeerTrigger::CorrectionTaken, place.m_source, *m_manualLocation);
}

bool Engine::IsAlongRoad(ms::LatLon const & position, double bearingDeg)
{
  // There is a road at the position going the bearing way or the opposite one.
  auto const road = m_map.GetRoads(false /* matchRoute */).Snap(position, bearingDeg, kRoadCheckRadiusM);
  if (!road)
    return false;
  double const diff = std::fabs(AngleDiff(road->m_bearingDeg, bearingDeg));
  return Distance(position, road->m_point) <= kRoadCheckRadiusM && std::min(diff, 180 - diff) <= kMaxAlongRoadDiffDeg;
}

std::optional<RoadPoint> Engine::SnapMarkToRoad(ms::LatLon const & position, std::optional<double> bearingDeg,
                                                double radiusM, std::optional<Fix> const & turnedFrom)
{
  // The axis of the closest road, a main one rather than a driveway branching off it nearly as close. The car looks
  // along it the way closest to the direction of the movement. The direction only tells which way the car looks:
  // for a mark it is the direction before the mark, and preferring a road going that way would take a driveway or a
  // crossing street next to the tapped one. |turnedFrom| is where the car was before, if it may have turned to
  // another road since, e.g. a new mark.
  auto road = m_map.SnapToMainRoad(position, radiusM);
  // Roads are searched in a square, its corners are farther than the radius.
  if (!road || Distance(position, road->m_point) > radiusM)
    return {};

  // Without the direction of the movement the car looks any way, the user turns it around if it is wrong.
  road->m_bearingDeg = Orient(road->m_bearingDeg, bearingDeg);
  // Without the previous position, e.g. right after the start, it is unknown where the car has turned from.
  if (!bearingDeg || !turnedFrom || std::fabs(AngleDiff(road->m_bearingDeg, *bearingDeg)) <= kMaxRoadBearingDiffDeg)
    return road;

  // The road is a crossing one, the car has turned to it. It goes away from where it was, to the left or to the
  // right.
  if (Distance(turnedFrom->m_position, road->m_point) >= kMinTurnDistanceM &&
      std::fabs(AngleDiff(road->m_bearingDeg, Bearing(turnedFrom->m_position, road->m_point))) > 90)
  {
    road->m_bearingDeg = Normalize(road->m_bearingDeg + 180);
  }
  return road;
}

double Engine::ShiftPosition(double distanceM)
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  bool const forward = distanceM > 0;
  auto const from = m_savedLocation;
  if (!from || IsShiftBlocked(forward))
    return 0;

  // The direction of the movement tells which part of the route the car drives along: the route passes
  // the car several times, e.g. the street it has just turned from is still a part of the route.
  auto const movementBearing = GetCarBearing();
  auto shifted = m_map.ShiftAlongRoute(from->m_position, movementBearing, distanceM);
  if (!shifted && movementBearing)
    shifted = RoadWalker::Walk(m_map.GetRoads(false /* matchRoute */), from->m_position, *movementBearing, distanceM);
  if (!shifted)
    return 0;

  // The position has stopped at a crossing: the car can go to another street there, so the position is
  // not moved that way any more until the car really leaves the crossing.
  // Less than this is no movement at all, and the direction of such a move means nothing.
  if (std::fabs(shifted->m_appliedM) < kMinShiftM)
  {
    if (shifted->m_atCrossing)
      BlockShift(forward, from->m_position);
    return 0;
  }

  LOG(LINFO,
      ("Moved the position by", std::round(shifted->m_appliedM), "m, bearing =", std::round(shifted->m_bearingDeg)));
  if (m_inertial)
    m_inertial->OnPositionCorrected(shifted->m_position, shifted->m_bearingDeg, shifted->m_appliedM);

  // The position is set by the user now, so it is as fresh as a manual mark.
  m_manualSetTimeMs = m_clock.NowMs();
  if (m_manualLocation)
  {
    m_manualLocation->m_position = shifted->m_position;
    m_manualLocation->m_bearingDeg = shifted->m_bearingDeg;
  }

  // The position is set by the user now, whatever it came from before.
  Fix location = *from;
  location.m_provider = Provider::Manual;
  location.m_position = shifted->m_position;
  location.m_bearingDeg = shifted->m_bearingDeg;
  location.m_timeMs = m_clock.NowMs();
  location.m_unixTimeMs = m_clock.UnixNowMs();
  m_savedLocation = location;
  m_lastPositionSource = PositionSource::Manual;
  if (shifted->m_atCrossing)
    BlockShift(forward, location.m_position);

  // Moving back returns the car to the passed part of the route, which is cut off, so it is rebuilt.
  RebuildRouteIfOffRoute(location);
  NotifyLocationUpdated();
  return shifted->m_appliedM;
}

void Engine::BlockShift(bool forward, ms::LatLon const & at)
{
  (forward ? m_shiftStopForward : m_shiftStopBack) = at;
}

bool Engine::IsShiftBlocked(bool forward)
{
  auto & stop = forward ? m_shiftStopForward : m_shiftStopBack;
  if (!stop)
    return false;
  if (!m_savedLocation || Distance(*stop, m_savedLocation->m_position) >= kShiftBlockRadiusM)
  {
    stop.reset();
    return false;
  }
  return true;
}

void Engine::ApplyManualLocation()
{
  m_manualRepeatTimer.Stop();
  if (!m_manualLocation)
    return;

  // The inertial navigation moves the car from the manual mark, it must not be moved back.
  if (!IsInertialActive())
  {
    m_manualLocation->m_timeMs = m_clock.NowMs();
    m_manualLocation->m_unixTimeMs = m_clock.UnixNowMs();
    m_savedLocation = m_manualLocation;
    NotifyLocationUpdated();
  }

  if (m_active)
    m_manualRepeatTimer.Start(kManualRepeatIntervalMs, [this] { ApplyManualLocation(); });
}

std::optional<Fix> Engine::GetWorkingGps() const
{
  if (!m_lastGoodGps || m_spoofingDetector.IsSpoofed() || AgeMs(*m_lastGoodGps) > kGpsStatusMaxAgeMs ||
      m_lastGoodGpsGapMs > kGpsStatusMaxGapMs)
  {
    return {};
  }
  return m_lastGoodGps;
}

std::optional<Fix> Engine::GetWorkingNetwork() const
{
  if (!m_networkLocation || AgeMs(*m_networkLocation) > kNetworkStatusMaxAgeMs)
    return {};
  return m_networkLocation;
}

PositionSource Engine::GetPositionSource() const
{
  if (IsInertialActive())
    return PositionSource::Inertial;
  if (m_manualMode)
    return m_manualLocation ? PositionSource::Manual : PositionSource::None;
  if (!m_savedLocation || !m_active || AgeMs(*m_savedLocation) > kPositionStaleMs)
    return PositionSource::None;
  return SourceOf(*m_savedLocation);
}

Status Engine::GetStatus()
{
  CHECK_THREAD_CHECKER(m_threadChecker, ());
  Status status;
  status.m_source = GetPositionSource();
  status.m_accuracyM = m_savedLocation ? m_savedLocation->m_accuracyM : 0;
  status.m_manualMode = m_manualMode;
  status.m_markByTap = m_markByTap;
  status.m_manualAgeMs = MsSince(m_manualSetTimeMs);
  status.m_gpsSpoofed = m_spoofingDetector.IsSpoofed();
  status.m_gpsDisabled = m_gpsDisabled;
  status.m_gpsState = GetGpsState();
  status.m_lastGoodGpsAgeMs = m_lastGoodGps ? AgeMs(*m_lastGoodGps) : -1;
  if (auto const gps = GetWorkingGps())
    status.m_workingGpsAccuracyM = gps->m_accuracyM;
  if (auto const network = GetWorkingNetwork())
    status.m_workingNetworkAccuracyM = network->m_accuracyM;
  // The position is moved by hand only when it does not come from GPS: a GPS one is moved by the car.
  status.m_movedByHand =
      m_manualMode || status.m_source == PositionSource::Inertial || status.m_source == PositionSource::Manual;
  // A position from cell towers is not on a road.
  if (status.m_source != PositionSource::None && status.m_source != PositionSource::Network)
    status.m_speedLimitKmh = GetSpeedLimitKmh();

  status.m_inertialEnabled = IsInertialNavigationEnabled();
  status.m_esp32Source = m_storage.IsEsp32Source();
  status.m_carId = m_cars.GetCurrentCar();
  status.m_elm327Address = m_storage.Get<std::string>(Storage::kElm327Address, "");
  status.m_inertialStarted = status.m_inertialEnabled && m_inertial;
  if (status.m_inertialStarted)
  {
    status.m_sourceState = m_inertial->GetSourceState();
    status.m_bleState = m_inertial->GetBleState();
    status.m_deviceName = m_inertial->GetDeviceName();
    status.m_speedKmh = m_inertial->GetSpeedKmh();
    status.m_carInfo = m_inertial->GetCarInfo();
    status.m_speedScale = m_inertial->GetSpeedScale();
    status.m_speedTableRanges = m_inertial->GetSpeedTableRanges();
    status.m_roughSpeedTableRanges = m_inertial->GetRoughSpeedTableRanges();
    status.m_speedTable = m_inertial->GetSpeedTable();
    status.m_gpsSpeedTable = m_inertial->GetGpsSpeedTable();
    status.m_speedHintShown = m_speedHintShown;
    status.m_speedHintRange = m_speedHintRange;
    status.m_speedHintGps = MsSince(m_speedTableGpsMs) < kSpeedHintGpsMs;
    status.m_speedMilestone = m_speedMilestone;
    status.m_sprintKind = m_lastSprint.m_kind;
    status.m_sprintSec = m_lastSprint.m_sec;
    status.m_sprintTrapKmh = m_lastSprint.m_trapKmh;
    status.m_sprintBestSec = m_lastSprintBestSec;
    status.m_sprintRecord = m_lastSprintRecord;
    status.m_speedLagSec = m_inertial->GetSpeedLag();
    status.m_speedLagMeasured = m_inertial->IsSpeedLagMeasured();
    status.m_calibration = m_inertial->GetCalibrationState();
    status.m_calibrationProgress = m_inertial->GetCalibrationProgressPercent();
    status.m_calibrationArmed = m_calibrationArmed;
    status.m_hasInertialPosition = m_inertial->HasPosition();
    status.m_roadLost = m_inertial->IsUserNeeded();
    status.m_otherMarks = static_cast<int>(m_inertial->GetOtherMarksCount());
    if (auto const * box = m_inertial->GetEsp32())
    {
      if (box->GetInfo())
        status.m_boxFirmware = box->GetInfo()->m_firmware;
      status.m_boxValues = box->GetBoxValues();
      if (auto const * firmware = FindBoxFirmware())
        status.m_bundledFirmware = firmware->m_version;
      status.m_firmwareUpdate = box->GetUpdate().GetState();
      status.m_firmwareUpdateProgress = box->GetUpdate().GetProgressPercent();
      status.m_firmwareUpdateError = box->GetUpdate().GetError();
      status.m_firmwareOfferPending = m_firmwareOfferPending;
      status.m_boxCalibrationAdvised = m_storage.Get<bool>(Storage::kBoxCalibrationAdvised, false);
      status.m_boxHasPhones = box->HasPhones();
      if (box->GetPhones())
        status.m_boxPhones = box->GetPhones()->m_phones;
      status.m_boxReadOnly = box->IsReadOnly();
      status.m_boxStill = box->IsStill();
      status.m_peerRole = box->GetPeerRole();
      status.m_peerName = box->GetLeaderName();
      status.m_addPhone = box->GetAddPhoneState();
      status.m_addPhoneCode = box->GetAddPhoneCode();
      status.m_addPhoneSecondsLeft = static_cast<int>((box->GetAddPhoneMsLeft() + 999) / 1000);
    }
  }
  return status;
}

bool Engine::LogStateChanges()
{
  auto const status = GetStatus();
  std::string box = "NOT_SET_UP";
  if (status.m_inertialEnabled)
    box = status.m_inertialStarted ? DebugPrint(status.m_sourceState) : "STOPPED";
  auto const log = [](char const * what, std::string & last, std::string now)
  {
    if (last == now)
      return false;
    LOG(LINFO, (what, last.empty() ? "?" : last, "->", now));
    last = std::move(now);
    return true;
  };
  bool changed = log("Position source", m_loggedState.m_source, DebugPrint(status.m_source));
  // Not a change: GPS of a phone at home comes and goes with the network positions, 300 times a day.
  log("GPS signal", m_loggedState.m_gps, DebugPrint(status.m_gpsState));
  changed = log("Box state", m_loggedState.m_box, box) || changed;
  changed = log("Box Bluetooth", m_loggedState.m_ble, DebugPrint(status.m_bleState)) || changed;
  log("Peer role", m_loggedState.m_peer, DebugPrint(status.m_peerRole));
  return changed;
}

void Engine::LogTrip()
{
  m_tripLogTimer.Stop();
  if (!m_active)
    return;

  CheckGpsLost();
  CheckMotionSourceStopped();
  CheckNotCalibrated();
  UpdateSpeedHint();
  CheckFirmwareUpdate();
  CheckBoxCalibration();
  bool const changed = LogStateChanges();
  SaveCarPosition(false /* now */);
  SaveBoxCarValues(false /* now */);
  m_boxCarValues.ReadName(m_inertial ? m_inertial->GetEsp32() : nullptr);
  int64_t const now = m_clock.NowMs();
  if (changed || IsCarMoving())
    m_tripEverySecondMs = now;
  if (!m_tripLoggedMs || (m_tripEverySecondMs && now - *m_tripEverySecondMs < kTripLogStandTailMs) ||
      now - *m_tripLoggedMs >= kTripLogStandIntervalMs)
  {
    LOG(LINFO, (GetTripLine()));
    m_tripLoggedMs = now;
  }
  m_positionsBetweenGps = 0;

  m_tripLogTimer.Start(kTripLogIntervalMs, [this] { LogTrip(); });
}

bool Engine::IsCarMoving() const
{
  if (m_inertial && IsInertialNavigationEnabled() && m_inertial->GetSpeedKmh() > 0)
    return true;
  auto const moves = [this](std::optional<Fix> const & fix)
  { return fix && AgeMs(*fix) <= kGpsMaxAgeMs && fix->m_speedMps && *fix->m_speedMps * 3.6 >= kTripLogMovingGpsKmh; };
  return moves(m_rawGps) || moves(m_rawFused);
}

std::string Engine::GetTripLine()
{
  std::string line = "TRIP src=" + DebugPrint(GetPositionSource());
  char buf[256];
  if (m_savedLocation)
  {
    std::snprintf(buf, sizeof(buf), " pos=%.6f,%.6f acc=%.0f", m_savedLocation->m_position.m_lat,
                  m_savedLocation->m_position.m_lon, m_savedLocation->m_accuracyM);
    line += buf;
    if (m_savedLocation->m_bearingDeg)
      line += " bear=" + std::to_string(std::lround(*m_savedLocation->m_bearingDeg));
    line += " age=" + FormatSeconds(AgeMs(*m_savedLocation));
  }
  // The positions of the platform, used or not: latitude,longitude/accuracy in meters/speed in km/h/bearing/age
  // in seconds/accuracy of the bearing in degrees. The age tells where the car was at the moment of the line: the
  // two are not written together. The accuracy of the bearing tells if a slow car has taken its heading from it:
  // a trip is driven again with it.
  auto const addRaw = [&](char const * name, std::optional<Fix> const & fix)
  {
    if (!fix || AgeMs(*fix) > kGpsStatusMaxAgeMs)
      return;
    auto const speedKmh = fix->m_speedMps ? std::optional<double>(*fix->m_speedMps * 3.6) : std::nullopt;
    std::snprintf(buf, sizeof(buf), " %s=%.6f,%.6f/%.1f/%s/%s/%.2f/%s", name, fix->m_position.m_lat,
                  fix->m_position.m_lon, fix->m_accuracyM, FormatOptional(speedKmh).c_str(),
                  FormatOptional(fix->m_bearingDeg).c_str(), AgeMs(*fix) / 1000.0,
                  FormatOptional(fix->m_bearingAccuracyDeg).c_str());
    line += buf;
  };
  addRaw("gps", m_rawGps);
  addRaw("fused", m_rawFused);
  // The compass of the phone: heading/accuracy in degrees/age in seconds. Compared with the bearing of GPS, it tells
  // how far the compass errs in a car and how the phone is turned in its holder.
  if (m_compass && MsSince(m_compass->m_timeMs) <= kGpsStatusMaxAgeMs)
  {
    std::snprintf(buf, sizeof(buf), " cmp=%.0f/%.0f/%.2f", m_compass->m_headingDeg, m_compass->m_accuracyDeg,
                  MsSince(m_compass->m_timeMs) / 1000.0);
    line += buf;
  }
  line += " gpsAge=" + (m_lastTrustedGpsMs ? FormatSeconds(MsSince(m_lastTrustedGpsMs)) : "-");
  // The positions shown between GPS positions since the previous line: the mark drives smoothly with 4-5 a second.
  line += " fill=" + std::to_string(m_positionsBetweenGps);
  line += std::string(" spoofed=") + (m_spoofingDetector.IsSpoofed() ? "1" : "0");
  line += " gpsst=" + DebugPrint(GetGpsState());
  bool const navigating = m_map.IsNavigating();
  line += std::string(" nav=") + (navigating ? "1" : "0");
  // The route left tells if the route follows the car: the passed part is cut off by it.
  if (navigating)
    if (auto const left = m_map.GetDistanceLeft(); !left.empty())
      line += " left=" + left;
  // How far aside the route is: the core shows a car driving along a road beside the route on the route.
  if (navigating && m_savedLocation && m_savedLocation->m_bearingDeg)
    if (auto const aside = m_map.GetRouteAside(m_savedLocation->m_position, *m_savedLocation->m_bearingDeg))
      line += " rte=" + std::to_string(std::lround(*aside));
  if (m_networkLocation)
  {
    std::snprintf(buf, sizeof(buf), " net=%.5f,%.5f acc=%.0f age=%s", m_networkLocation->m_position.m_lat,
                  m_networkLocation->m_position.m_lon, m_networkLocation->m_accuracyM,
                  FormatSeconds(AgeMs(*m_networkLocation)).c_str());
    line += buf;
  }
  if (m_manualLocation)
    line += " markAge=" + FormatSeconds(MsSince(m_manualSetTimeMs));
  if (m_inertial && IsInertialNavigationEnabled())
  {
    line += " obd=" + DebugPrint(m_inertial->GetSourceState()) + " speed=" + std::to_string(m_inertial->GetSpeedKmh());
    // How old the speed is, milliseconds: the car is asked for it a few times a second.
    line += " sage=" + std::to_string(m_inertial->GetSpeedAgeMs());
    // The ESP32 box: what Bluetooth does, and how its data came during the last second: the lines and the
    // longest pause between them in milliseconds. "BLE" is from the time the box had Wi-Fi too.
    if (auto const rate = m_inertial->GetEsp32DataRate())
    {
      line += " link=BLE/" + DebugPrint(m_inertial->GetBleState());
      line += " box=" + std::to_string(rate->m_lines) + "/" + std::to_string(rate->m_maxGapMs);
      // The firmware of the box and its update with the percent sent.
      auto const * box = m_inertial->GetEsp32();
      // The flags of its last data line: the car stands by the box, its sensors and calibrations are fine.
      std::snprintf(buf, sizeof(buf), " bf=%X", box->GetFlags());
      line += buf;
      if (box->GetInfo())
        line += " fw=" + box->GetInfo()->m_firmware;
      // The engine speed from the last status of the box, to compare with the car speed: the box doesn't ask the car
      // for it while the car moves, so it is there only if the box does.
      if (auto const car = box->GetCarInfo(); car && car->m_rpm >= 0)
        line += " rpm=" + std::to_string(car->m_rpm);
      if (auto const & update = box->GetUpdate(); update.GetState() != Esp32Update::State::None)
        line += " ota=" + DebugPrint(update.GetState()) + "/" + std::to_string(update.GetProgressPercent());
    }
    std::snprintf(buf, sizeof(buf), " scale=%.3f table=%d factor=%.3f rough=%d lag=%.2f%s", m_inertial->GetSpeedScale(),
                  m_inertial->GetSpeedTableRanges(), m_inertial->GetSpeedFactor(),
                  m_inertial->GetRoughSpeedTableRanges(), m_inertial->GetSpeedLag(),
                  m_inertial->IsSpeedLagMeasured() ? "" : "/DEFAULT");
    line += buf;
    // The accelerometers against the car speed: how well each follows it, and how far ahead of the car speed
    // alone the box one has put the position and the phone one would, "-" if it doesn't follow the car.
    std::snprintf(buf, sizeof(buf), " boxacc=%.2f/", m_inertial->GetBoxAccelCorrelation());
    line += buf;
    if (m_inertial->IsBoxAccelUsed())
      std::snprintf(buf, sizeof(buf), "%+.1f", m_inertial->GetAccelAheadM());
    else
      std::snprintf(buf, sizeof(buf), "-");
    line += buf;
    std::snprintf(buf, sizeof(buf), " phoneacc=%.2f/", m_inertial->GetPhoneAccelCorrelation());
    line += buf;
    if (auto const phoneAhead = m_inertial->GetPhoneAccelAheadM())
      std::snprintf(buf, sizeof(buf), "%+.1f", *phoneAhead);
    else
      std::snprintf(buf, sizeof(buf), "-");
    line += buf;
    line += " gyro=" + DebugPrint(m_inertial->GetCalibrationState());
    auto const turn = m_inertial->GetLastTurnShiftM();
    line += " turn=" + (turn ? std::to_string(std::lround(*turn)) : std::string("NaN"));
    auto const heading = m_inertial->GetHeading();
    line += " hdg=" + (heading ? std::to_string(std::lround(*heading)) : std::string("-"));
    line += "/" + DebugPrint(m_inertial->GetHeadingSource());
    line += std::string(" road=") + (m_inertial->IsOnRoad() ? "1" : "0");
    line += std::string(" lost=") + (m_inertial->IsRoadLost() ? "1" : "0");
    // The car drives backwards by the accelerometer of the box.
    line += std::string(" back=") + (m_inertial->IsDrivingBack() ? "1" : "0");
    // A turn is being followed to its crossing, all the car has driven, how far and how fast at most it has
    // driven off the roads, and how far along the road a maneuvering car is to be put on.
    std::snprintf(buf, sizeof(buf), " turning=%d odo=%.0f offm=%.0f offv=%.0f", m_inertial->IsTurning() ? 1 : 0,
                  m_inertial->GetPathM(), m_inertial->GetOffRoadM(), m_inertial->GetOffRoadMaxSpeedMps() * 3.6);
    line += buf;
    auto const candidate = m_inertial->GetRoadCandidateM();
    line += " cand=" + (candidate ? std::to_string(std::lround(*candidate)) : std::string("-"));
    // The car followed apart off the roads, where it is by the calculation.
    if (auto const & car = m_inertial->GetOffRoadCar())
    {
      std::snprintf(buf, sizeof(buf), " self=1 car=%.6f,%.6f", car->m_lat, car->m_lon);
      line += buf;
    }
    // The other roads the car may be on after a turn that fitted several, where it is on them.
    if (auto const others = m_inertial->GetOtherMarkPositions(); !others.empty())
    {
      line += " marks=" + std::to_string(others.size() + 1) + " others=";
      for (size_t i = 0; i < others.size(); ++i)
      {
        std::snprintf(buf, sizeof(buf), "%s%.6f,%.6f", i == 0 ? "" : ";", others[i].m_lat, others[i].m_lon);
        line += buf;
      }
    }
    auto const snap = m_inertial->GetLastSnapShiftM();
    if (snap)
      std::snprintf(buf, sizeof(buf), " snap=%.1f", *snap);
    else
      std::snprintf(buf, sizeof(buf), " snap=NaN");
    line += buf;
    // How much to the right of the road found by the last look for it the car looks, and what the look has ended
    // with. While the car is followed apart, the road is looked for next to it.
    auto const roadDiff = m_inertial->GetLastSnapBearingDiffDeg();
    line += " rdiff=" + (roadDiff ? std::to_string(std::lround(*roadDiff)) : std::string("-"));
    line += " snapwhy=" + DebugPrint(m_inertial->GetLastSnapResult());
    // How far the car has driven while the mark waits for it where its road has gone away, the mark is ahead.
    auto const waited = m_inertial->GetWaitedAheadM();
    line += " wait=" + (waited ? std::to_string(std::lround(*waited)) : std::string("-"));
    // The car is off the roads next to a roundabout, where it is not lost.
    std::snprintf(buf, sizeof(buf), " fix=%.0f ready=%d ring=%d", m_inertial->GetDistanceSinceFix(),
                  m_inertial->IsReady() ? 1 : 0, m_inertial->IsAtRoundabout() ? 1 : 0);
    line += buf;
  }
  return line;
}

void Engine::Notify(Event event)
{
  m_delegate.OnEvent(event);
}

std::string DebugPrint(PositionSource source)
{
  switch (source)
  {
  case PositionSource::None: return "NONE";
  case PositionSource::Gps: return "GPS";
  case PositionSource::Network: return "NETWORK";
  case PositionSource::Manual: return "MANUAL";
  case PositionSource::Inertial: return "INERTIAL";
  }
  UNREACHABLE();
}

std::string DebugPrint(GpsState state)
{
  switch (state)
  {
  case GpsState::None: return "NONE";
  case GpsState::Coarse: return "COARSE";
  case GpsState::Spoofed: return "SPOOFED";
  case GpsState::Checking: return "CHECKING";
  case GpsState::Good: return "GOOD";
  }
  UNREACHABLE();
}

std::string DebugPrint(SpeedMilestone milestone)
{
  switch (milestone)
  {
  case SpeedMilestone::Range: return "RANGE";
  case SpeedMilestone::City: return "CITY";
  case SpeedMilestone::OutOfTown: return "OUT_OF_TOWN";
  case SpeedMilestone::Full: return "FULL";
  }
  UNREACHABLE();
}
}  // namespace nogps
