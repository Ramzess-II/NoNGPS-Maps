#pragma once

#include "map/nogps/accel_log.hpp"
#include "map/nogps/delegate.hpp"
#include "map/nogps/esp32_protocol.hpp"
#include "map/nogps/esp32_update.hpp"
#include "map/nogps/motion_source.hpp"
#include "map/nogps/peer_sync.hpp"
#include "map/nogps/scheduler.hpp"

#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace nogps
{
class Clock;

/// The NoGPS ESP32 sensor box: it is fixed in the car and sends the car rotation and speed over Bluetooth LE,
/// the phone can be held in hands. The box zeroes its gyroscope by itself on every stop.
class Esp32Source
  : public MotionSource
  , private Esp32Update::Link
{
public:
  // The box sends data while it hears the phone.
  static int64_t constexpr kHelloIntervalMs = 1000;
  // The box sends 50 lines a second, a longer silence means it is lost.
  static int64_t constexpr kLineIntervalMs = 20;
  static int64_t constexpr kDataTimeoutMs = 1000;
  // The rotation of a longer pause of the data is lost: the box may have restarted or slept. A shorter one, e.g. a
  // reconnection of Bluetooth while the car drives, is taken from the totals of the box.
  static int64_t constexpr kMaxBridgedPauseMs = 5000;
  // A box connected again after a parking is awake this long after a silent connection ends: the phone connects
  // again in a few seconds.
  static int64_t constexpr kWakingLinkGapMs = 30'000;
  // The seconds of the accelerometer written to the trip log from before the car has reported that it moves.
  static size_t constexpr kAccelLinesBeforeStart = 3;
  // The shake of the box shown to the user is this many lines long: 3 s of the lines.
  static size_t constexpr kShakeLines = 150;
  // A calibration takes ~3 s on the box.
  static int64_t constexpr kCalibrationTimeoutMs = 10'000;
  // The events missed are asked again not more often than this.
  static int64_t constexpr kEventsRequestIntervalMs = 2000;
  // More than the box keeps in its journal.
  static size_t constexpr kMaxLoggedEvents = 64;
  // The time of the box is 32 bits of milliseconds and wraps around.
  static int64_t constexpr kBoxTimeWrapMs = 1LL << 32;
  // The lines of the box are shorter.
  static size_t constexpr kMaxLineSize = 512;
  // A box that has not told about itself is asked after this many hellos, this many times: an old firmware
  // doesn't know the question.
  static int constexpr kInfoRequestHellos = 3;
  static int constexpr kMaxInfoRequests = 3;
  // The box answers a command at once, a lost reply ends the reading of the values of the car.
  static int64_t constexpr kCarReplyTimeoutMs = 5000;
  // The list of the phones is asked again because of BUSY or an event not more often than this.
  static int64_t constexpr kListIntervalMs = 2000;
  // The box answers AUTH at once: a command without a reply is sent again, this many times in all.
  static int64_t constexpr kAuthReplyTimeoutMs = 2000;
  static int constexpr kMaxAuthSends = 5;

  /// What the box does about a new phone, see StartAddPhone().
  enum class AddPhone
  {
    None,
    // The code is sent to the box.
    Opening,
    // The box takes a new phone with the code until GetAddPhoneMsLeft() ends.
    Open,
    // A new phone has paired.
    Added,
    // No phone has paired in time: the code works no more.
    Expired,
    // The box has kMaxPhones phones: one is to be removed first.
    Full,
    // The box has refused, or the link was lost before it answered.
    Failed,
  };

  /// A start of the box by a power-on: it was plugged into the car.
  struct PowerOn
  {
    // Milliseconds since the Unix epoch.
    int64_t m_unixMs = 0;
    // How long the box has worked since then by its own clock.
    int64_t m_uptimeMs = 0;
  };

  /// How the data lines came during the last second, for the log of a drive.
  struct DataRate
  {
    int m_lines = 0;
    // The longest pause between two lines, or since the last one.
    int64_t m_maxGapMs = 0;
  };

  Esp32Source(Delegate & delegate, Scheduler & scheduler, Clock const & clock, MotionSource::Listener & listener);
  ~Esp32Source() override;

  // MotionSource overrides:
  void Start() override;
  void Stop() override;
  SourceState GetState() const override;
  bool IsCalibrated() const override;
  CalibrationState GetCalibrationState() override;
  int GetCalibrationProgressPercent() const override { return m_calibrationProgress; }
  void Calibrate() override;
  std::string GetDeviceName() const override;
  std::optional<CarInfo> GetCarInfo() const override;

  /// The bytes of the box as they come over Bluetooth: a line may be cut in pieces, a piece may have several lines.
  void OnBleBytes(std::string_view bytes);
  /// `bondLost`: the box is thought to have forgotten the phone, see BleState::BondLost. A link made then, Connected
  /// for the HELLO the box waits for, is a probe: it is not a working link until the box is heard.
  /// `boxId`: the id of the box the transport has connected, the four characters of its name, empty if the box tells
  /// none. Another id in its NGI refuses the box. Taken as it comes, also when the state is the same.
  void OnBleState(BleState state, bool bondLost = false, std::string const & boxId = {});
  BleState GetBleState() const { return m_bleState; }
  bool IsBondLost() const { return m_bondLost; }
  DataRate GetDataRate() const;

  /// \returns when the box was powered on, if this is how it has started and its data come. Nothing after a
  /// restart of another kind: the box has stayed in its place.
  std::optional<PowerOn> GetPowerOn() const;
  /// \returns when the box was calibrated by Calibrate() the last time, nothing if it was not.
  std::optional<int64_t> GetCalibratedMs() const { return m_calibratedMs; }

  /// What the box has told about itself, nothing until it does.
  std::optional<esp32::Info> const & GetInfo() const { return m_info; }
  /// \returns every esp32::BoxValue while connected, with the values of the last status and info lines of this
  /// connection, empty for those not heard yet. Nothing while not connected.
  esp32::BoxValues GetBoxValues() const;
  /// \returns the flags of the last data line of the box, see esp32::kFlag*.
  int GetFlags() const { return m_flags; }
  /// \returns true if the box reports that it has stood still for its 2 s.
  bool IsStill() const { return IsConnected() && (m_flags & esp32::kFlagStill); }
  /// \returns the shake of the box of the last kShakeLines data lines, the oldest first, see esp32::Data::m_shakePct.
  /// Empty while not connected and for a box that doesn't tell it.
  std::vector<int> GetShake() const { return {m_shake.begin(), m_shake.end()}; }
  /// \returns true if the box takes a firmware now: it is connected over Bluetooth and its firmware knows how.
  bool CanUpdate() const;
  void StartUpdate(Firmware const & firmware);
  void CancelUpdate() { m_update.Cancel(); }
  Esp32Update const & GetUpdate() const { return m_update; }

  /// \returns true if the box has proved itself in this connection, or has not to: its lines are taken. Before that
  /// only its answer to AUTH and its info are, see OnUnprovenLine().
  bool IsBoxProven() const { return m_proven; }
  /// \returns true if the box has failed to prove itself: its lines are not taken until the link is made again.
  bool IsBoxRefused() const { return m_authRefused; }

  /// \returns true if the box is connected and keeps the values of its car, see BoxCarValues.
  bool CanStoreCarValues() const;
  /// Reads the values of the car one by one: the listener gets all of them, or nothing if the box refuses one or the
  /// link drops.
  void ReadCarValues(std::vector<std::string> keys);
  bool IsReadingCarValues() const { return m_carRead.has_value(); }
  /// Writes a value of the car, an empty one erases it. The listener gets the reply.
  void WriteCarValue(std::string const & key, std::string const & value);

  /// \returns true if the box is connected and knows its phones. It tells them at the connection.
  bool HasPhones() const;
  /// Asks the box for its phones again.
  void ListPhones();
  void ListPhonesThrottled();
  /// The phones of the box from its last list in this connection.
  std::optional<esp32::Phones> const & GetPhones() const { return m_phones; }
  /// Removes a phone from the box, this one too: the listener is told then.
  void ForgetPhone(std::string const & address);
  /// \returns true if another phone has connected to the box first: the box takes from it the commands that change
  /// the box, this phone gets the data only.
  bool IsReadOnly() const { return HasPhones() && m_readOnly; }
  /// \returns true if the box passes the places of the phones on: it is connected and has the ability.
  bool CanPeer() const;
  /// \returns Leading for the phone that changes the box while the box knows another phone, Following for the phone
  /// that gets the data only, None if the box can't pass the places on or this phone is alone.
  PeerRole GetPeerRole() const;
  /// \returns the name the leader has given the box: the phone that changes it, empty if it has none or this phone
  /// leads.
  std::string GetLeaderName() const;
  /// Sends the place to the other phone if the role of this phone sends it on the trigger, see PeerSync.
  /// \returns true if it is sent.
  bool SendPeer(PeerTrigger trigger, PeerOutPlace const & place);
  /// The leader is in the manual mode: the follower sends its good GPS positions.
  bool IsPeerLeaderManual() const { return m_peer.IsLeaderManual(); }
  /// The distance the box has counted by its last data line.
  std::optional<int64_t> GetDistMm() const { return m_peer.GetDistMm(); }
  /// Makes a new code and lets the box take a new phone with it for esp32::kPairingWindowMs. The code is not kept.
  void StartAddPhone();
  void EndAddPhone() { m_addPhone.reset(); }
  AddPhone GetAddPhoneState() const;
  std::string GetAddPhoneCode() const { return m_addPhone ? m_addPhone->m_code : ""; }
  int64_t GetAddPhoneMsLeft() const;

private:
  /// What the box has told about switching itself off until it is unplugged, see OnEvent() and GetState().
  enum class BatteryLock
  {
    None,
    // BATT_LOCK came over the link that is up now: the box goes on sending data for a second after the event.
    Told,
    // The link that told it is lost. The box heard again over a new one has been plugged back in: switched off, it
    // could not answer.
    LinkLost,
  };

  // Esp32Update::Link overrides:
  int SendUpdateCommand(std::string const & command) override;
  void SendFirmwarePiece(std::string const & piece) override;

  void OnLine(std::string_view text);
  void OnUnprovenLine(esp32::Fields const & fields);
  void OnAuthInfo(esp32::Fields const & fields);
  void SendAuth();
  void OnAuthReply(esp32::Reply const & reply);
  void RefuseBox(std::string const & reason);
  std::string NewAuthHex(size_t bytes) const;
  void ForgetAuth();
  void SendHello();
  void Send(std::string_view command, int id);
  void OnData(esp32::Data const & data);
  void OnEvent(esp32::Event const & event);
  void OnReply(esp32::Reply const & reply);
  void OnPeer(esp32::Peer const & peer);
  void OnInfo(esp32::Info const & info);
  void StoreBoxValues(esp32::Fields const & fields);
  void OnLastEventNumber(int64_t lastNumber);
  void ReadNextCarValue();
  bool OnCarReply(esp32::Reply const & reply);
  void ForgetCarRequests();
  bool OnPhonesReply(esp32::Reply const & reply);
  void ForgetPhoneRequests();
  void RequestLostEvents(int64_t fromNumber);
  void ForgetJournal();
  bool IsConnected() const;
  bool IsSleeping() const;

  Delegate & m_delegate;
  Clock const & m_clock;
  MotionSource::Listener & m_listener;
  Timer m_helloTimer;
  bool m_running = false;
  int m_helloId = 0;

  BleState m_bleState = BleState::Off;
  bool m_bondLost = false;
  std::string m_linkBoxId;
  // The line being received over Bluetooth, from its "$" on.
  std::string m_bleLine;
  // When the data lines of the last second came.
  std::deque<int64_t> m_dataTimesMs;

  // Nothing until the first data line.
  std::optional<int64_t> m_lastDataMs;
  // When the box was last connected over Bluetooth after its last data line: its radio is on, it is not sleeping.
  std::optional<int64_t> m_wakingLinkMs;
  int m_flags = 0;
  std::deque<int> m_shake;
  AccelLog m_accelLog;
  // The lines of the accelerometer while the car reports that it stands.
  std::deque<std::string> m_accelLinesBeforeStart;
  bool m_hasLast = false;
  int64_t m_lastTimeMs = 0;
  int64_t m_lastYawMdeg = 0;
  std::string m_imuName;
  // The state of the ELM327 adapter of the box from its status.
  std::optional<std::string> m_obdState;
  // The box hasn't found its ELM327: while it searches it again, the adapter is still missing.
  bool m_obdAdapterMissing = false;
  // The car hasn't answered (NO_CAR, NO_DATA) since the link was made: the next protocol search changes nothing.
  bool m_carSilent = false;
  // The speed of the last data line, -1 if the car doesn't tell it.
  int m_speedKmh = -1;
  // The engine, its speed and the voltage of the car from the status of the box.
  std::optional<CarInfo> m_carInfo;
  // The box has told that its voltage and the one of ELM327 differ. Kept until they come close again.
  bool m_voltageMismatch = false;
  // The box has told it is off until it is unplugged (BATT_LOCK). Kept over the lost link until the box is heard
  // again: it goes on sending data for a second after the event.
  BatteryLock m_batteryLock = BatteryLock::None;
  // The numbers of the events of the box written to the log.
  std::set<int64_t> m_loggedEvents;
  std::optional<int64_t> m_eventsRequestMs;
  // The journal of the box tells it has started by a power-on.
  bool m_poweredOn = false;
  int m_nextCommandId = 1;
  // The calibration command waiting for its reply, 0 if none.
  int m_calibrationId = 0;
  int64_t m_calibrationStartMs = 0;
  int m_calibrationProgress = 0;
  bool m_calibrationFailed = false;
  // When the link was lost during the calibration: no answer to it comes, the flags of the box in its first data after
  // that tell the result.
  std::optional<int64_t> m_calibrationLinkLostMs;
  std::optional<int64_t> m_calibratedMs;

  // The box proves itself when a connection starts (spec 9.2): it answers AUTH with the proof of the key of its car, or
  // takes a new key with AUTH_SET if the phone has none. Its lines are dropped until then, only its info is kept.
  bool m_mustProve = false;
  bool m_proven = true;
  bool m_authRefused = false;
  // The info of the box heard before the proof: it is taken when the box has proved itself.
  std::optional<esp32::Fields> m_unprovenInfo;
  // The command waiting for its reply, 0 if none.
  int m_authId = 0;
  int m_authSends = 0;
  int64_t m_authSentMs = 0;
  // The car of the box, kept while the connection lasts: the box has given this id in its info, and the proof is of
  // it. Its key is the one that proves the box, or the new one the box is given.
  std::string m_authCar;
  std::string m_authKey;
  std::string m_authNonce;
  bool m_authSetsKey = false;
  // The box may not have the key, see CarStorage::kAuthKeyUnconfirmed: it is given it again when it says it has none.
  bool m_authKeyUnconfirmed = false;

  PeerSync m_peer;
  std::optional<esp32::Info> m_info;
  // Forgotten with the info: another box may connect.
  std::map<esp32::BoxValue, std::string> m_boxValues;
  int m_hellosWithoutInfo = 0;
  Esp32Update m_update;

  struct CarRead
  {
    std::vector<std::string> m_keys;
    std::map<std::string, std::string> m_values;
    // The command waiting for its reply.
    int m_id = 0;
    int64_t m_sentMs = 0;
  };
  std::optional<CarRead> m_carRead;
  // The writes of the values of the car waiting for their replies, by the command: the key and the value.
  std::map<int, std::pair<std::string, std::string>> m_carWrites;

  // The name of the phone for the box, see esp32::PhoneName().
  std::string m_phoneName;
  std::optional<esp32::Phones> m_phones;
  // The list of the phones asked, 0 if none.
  int m_listId = 0;
  int64_t m_listSentMs = -kListIntervalMs;
  struct ForgetRequest
  {
    int m_id = 0;
    std::string m_address;
    bool m_thisPhone = false;
    int64_t m_sentMs = 0;
  };
  std::optional<ForgetRequest> m_forget;
  // The last list says another phone changes the box. Not set without the list or a link.
  bool m_readOnly = false;
  struct AddPhoneRequest
  {
    std::string m_code;
    int m_id = 0;
    int64_t m_sentMs = 0;
    AddPhone m_state = AddPhone::Opening;
    int64_t m_openMs = 0;
    // The last event of the box before the code was sent: the box tells it has opened the window by a newer one,
    // and a phone paired after that is the new one.
    int64_t m_lastEvent = -1;
    int64_t m_openEvent = -1;
  };
  std::optional<AddPhoneRequest> m_addPhone;
};

std::string DebugPrint(Esp32Source::AddPhone state);
}  // namespace nogps
