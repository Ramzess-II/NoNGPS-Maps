#pragma once

#include "geometry/latlon.hpp"

#include <cstdint>
#include <optional>
#include <string>

namespace nogps
{
enum class Provider
{
  // Satellites.
  Gps,
  // Cell towers and Wi-Fi.
  Network,
  // A mix of both, e.g. Google fused or CoreLocation: told apart by the accuracy.
  Fused,
  // Set by the user.
  Manual,
  // Calculated from the car speed and turns.
  Inertial,
};

/// A position from the platform or one to show.
struct Fix
{
  ms::LatLon m_position;
  double m_accuracyM = 0;
  // Clockwise from the north.
  std::optional<double> m_bearingDeg;
  std::optional<double> m_bearingAccuracyDeg;
  std::optional<double> m_speedMps;
  std::optional<double> m_altitudeM;
  std::optional<double> m_altitudeAccuracyM;
  // Monotonic, see Clock::NowMs().
  int64_t m_timeMs = 0;
  int64_t m_unixTimeMs = 0;
  Provider m_provider = Provider::Gps;
};

enum class Event
{
  ManualModeChanged,
  // The manual mode has been left by itself: GPS is trusted again.
  GpsBack,
  // The manual mode has been turned on by itself: GPS is lost or wrong while driving.
  GpsLost,
  GpsSpoofed,
  GpsRestored,
  // The inertial navigation has left the roads: the car is stopped on the road, the user should mark it.
  RoadLost,
  // The gyroscope turns the car the other way than GPS: the inertial navigation would turn it wrong.
  TurnsReversed,
  // The car speed has stopped coming while the car is followed without GPS. Repeated while it lasts.
  MotionSourceStopped,
  // The user has tapped the map in the manual mode where there is no road: the car is always on a road.
  MarkNoRoad,
  // The car drives without GPS, but its turns are not known: the gyroscope is not calibrated or the sensor box
  // has been moved. The position stands still. Repeated while it lasts.
  NotCalibrated,
  // The sensor box works with another firmware than the application comes with, and can take it now: the car
  // stands. Told once for a firmware of a box.
  FirmwareUpdateAvailable,
  // The update of the firmware of the sensor box has ended.
  FirmwareUpdateDone,
  FirmwareUpdateFailed,
  // The sensor box has been powered on: it is new in the car, or it was taken out and may be put in another way.
  // The user should calibrate it on a level place. Told once for a power-on, while the car stands.
  BoxCalibrationAdvised,
  // The box has removed this phone on the request of the user: the platform forgets the car of the box.
  ThisPhoneRemoved,
  // GPS has measured a range of the speed table, see Status::m_speedHintRange and m_speedMilestone. Told once for the
  // ranges measured since the last check, not for the ranges of a table restored or taken from the box.
  SpeedRangeCalibrated,
  // A run from a standing start is timed, see Status::m_sprintKind. Told once for every result.
  SprintMeasured,
  // The box has connected Engine::kTripFileLinkGapMs or more after the link to it has ended: a drive starts. The
  // platform starts a new file of the trip log before it returns, the calibration of the car is logged next.
  TripStarted,
  // The sensor box has not proved itself and is not used until the link is made again: the user may have to forget
  // the car and pair the box again, see Status::m_boxPairAgain. Told once for a refusal.
  BoxRefused,
  // The box has erased everything on the request of the user, see Engine::FactoryResetBox(), and restarts as new: the
  // platform forgets the car of the box. The phone is not paired with it any more.
  BoxReset,
  // The box has not reset itself: it is busy or does not answer, see Status::m_boxResetError.
  BoxResetFailed,
};

/// What the platform does about the ESP32 sensor box over Bluetooth LE, told to Engine::OnEsp32BleState().
enum class BleState
{
  // Bluetooth is not searched: it is not asked for, or the platform has no Bluetooth LE.
  Off,
  // The user has not allowed the app to use Bluetooth.
  NoPermission,
  // Bluetooth is switched off on the phone.
  Disabled,
  Searching,
  // A box is found, but it doesn't know the phone and doesn't accept a new one now: it does for two minutes
  // after it is powered.
  PairingClosed,
  Connecting,
  // The phone asks the user for the code of the box.
  Pairing,
  // Connected and subscribed to the lines of the box.
  Connected,
  // The user has cancelled the code or entered a wrong one: the box is not tried again until the user asks.
  PairingFailed,
  // A paired box connects but sends nothing again and again: it has forgotten the phone. The user should remove the
  // box in the Bluetooth settings and power it again. Not tried again until the user asks. After a few silent
  // connections the platform searches again to see whether the box is back: that connection is Connected, for the
  // HELLO the box waits for, with the bond-lost flag of Engine::OnEsp32BleState() set until the box is heard.
  BondLost,
  // A box is found, but it doesn't know the phone and has phones: a new one is added on one of them, see
  // Engine::StartAddPhone().
  PairingByPhone,
  // A box is found, but it doesn't know the phone and has esp32::kMaxPhones phones: one of them is removed on a
  // paired phone first.
  PairingFull,
  // A box is found that is not of one of the CarStorage::kMaxCars cars of the user: it is not connected, a car is
  // forgotten first.
  CarLimit,
};

std::string DebugPrint(Provider provider);
std::string DebugPrint(Event event);
std::string DebugPrint(BleState state);

/// What the platform does for the navigation without GPS. Everything is called on the GUI thread, and the
/// platform calls the Engine back on it.
class Delegate
{
public:
  virtual ~Delegate() = default;

  /// The accelerometer of the phone, and the gyroscope if |gyroscope|, to Engine::OnAccel() and OnGyro().
  virtual void StartMotionSensors(bool gyroscope) = 0;
  virtual void StopMotionSensors() = 0;

  /// The ELM327 adapter over Bluetooth SPP: Engine::OnElm327Connected() or OnElm327Closed() follows.
  virtual void Elm327Connect(std::string const & address) = 0;
  virtual void Elm327Write(std::string const & data) = 0;
  virtual void Elm327Close() = 0;

  /// The ESP32 sensor box over Bluetooth LE, the only link to it. The platform searches the box by its service,
  /// connects, subscribes to the characteristic with its lines and keeps doing it until closed: the bytes go
  /// to Engine::OnEsp32BleBytes() as they come, every change of the state to Engine::OnEsp32BleState(). The
  /// UUIDs and the pairing are in docs/nogps/esp32-firmware-spec.md, section 17. A platform that hasn't made
  /// it yet doesn't get the box.
  virtual void Esp32BleOpen() {}
  virtual void Esp32BleSend(std::string const & /* line */) {}
  /// A piece of a new firmware for the box: written to its characteristic for them without a response, in the
  /// order of the calls, the lines of Esp32BleSend() go between the pieces. Section 18 of the same document.
  virtual void Esp32BleSendFirmware(std::string const & /* piece */) {}
  virtual void Esp32BleClose() {}
  /// The box has to prove itself before its lines are taken, see Esp32Source. Only a replay of old trips and the tests
  /// turn it off: the boxes of those days could not.
  virtual bool Esp32BoxMustProveItself() { return true; }
  /// The model of the phone, e.g. "Pixel 8": the sensor box shows it in the list of its phones.
  virtual std::string GetPhoneName() { return {}; }

  /// The position to show and to navigate by.
  virtual void OnPosition(Fix const & fix) = 0;
  virtual void OnEvent(Event event) = 0;
};
}  // namespace nogps
