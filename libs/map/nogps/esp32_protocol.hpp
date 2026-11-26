#pragma once

#include "map/nogps/motion_source.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace nogps
{
/// Lines of the NoGPS ESP32 sensor box protocol, version 1: "$NGD,...*CRC\r\n". The checksum is
/// CRC-16/CCITT-FALSE of the bytes between '$' and '*'. See docs/nogps/esp32-firmware-spec.md.
namespace esp32
{
int constexpr kVersion = 1;

// Bits of the data flags.
int constexpr kFlagImuOk = 1;
int constexpr kFlagBiasOk = 1 << 1;
int constexpr kFlagUpOk = 1 << 2;
int constexpr kFlagFwdOk = 1 << 3;
int constexpr kFlagObdOk = 1 << 4;
int constexpr kFlagStill = 1 << 5;
int constexpr kFlagCalibrating = 1 << 6;
int constexpr kFlagMountMoved = 1 << 7;
int constexpr kFlagReverse = 1 << 8;
int constexpr kFlagObdAbsent = 1 << 9;
int constexpr kFlagError = 1 << 10;
// The box tells about a wrong voltage divider from the same difference.
int constexpr kMaxVoltageDiffPercent = 10;
// The accuracy of a place of the other phone, in decimeters: the sender clamps it to 100 km.
int constexpr kMaxPeerAccuracyDm = 1'000'000;

using Fields = std::vector<std::string>;

/// A data line: the totals since the box has started, so a lost line loses nothing.
struct Data
{
  int64_t m_seq = 0;
  int64_t m_timeMs = 0;
  // Clockwise, thousandths of a degree.
  int64_t m_yawMdeg = 0;
  int64_t m_rateMdps = 0;
  int64_t m_distMm = 0;
  // -1 if the car doesn't tell it.
  int m_speedKmh = -1;
  int m_speedAgeMs = 0;
  int m_flags = 0;
  // The acceleration of the box during the line, m/s²: along two horizontal axes and up without the gravity,
  // and the largest deviation of the vertical one. Not sent by older boxes and before the calibration.
  bool m_hasAccel = false;
  double m_accelH1 = 0;
  double m_accelH2 = 0;
  double m_accelUp = 0;
  double m_jolt = 0;
  // How much the box shakes during the line, in percent of the limit under which the box counts itself still: 100 is
  // at the limit. -1 if the box doesn't tell it, see Esp32Source::GetShake().
  int m_shakePct = -1;
};

/// An event of the box: an error, its end or a calibration.
struct Event
{
  int64_t m_number = 0;
  int64_t m_timeMs = 0;
  // E - error, W - warning, I - information.
  std::string m_level;
  std::string m_code;
  std::string m_text;
};

/// A reply to a command.
struct Reply
{
  int m_id = 0;
  bool m_ok = false;
  // The progress in percent, nothing if it is the final reply.
  std::optional<int> m_progress;
  std::string m_error;
  // What an accepted command returns, e.g. the size of a piece and of the window of a firmware update.
  std::vector<std::string> m_values;
};

/// What the box tells about itself when a connection starts.
struct Info
{
  std::string m_firmware;
  // A firmware is made for a chip and a board.
  std::string m_chip;
  std::string m_board;
  // The box takes a new firmware over Bluetooth.
  bool m_canUpdate = false;
  // The four characters of the name of the box, NonGPS-XXXX.
  std::string m_id;
  // How many times the box was powered on, nothing from a firmware that doesn't count it.
  std::optional<int64_t> m_powerOns;
  // The hardware revision of the board, "R1", empty from a firmware that doesn't tell it.
  std::string m_revision;

  /// The firmware is older than kMinFirmware: the box can take an update and nothing else.
  bool IsTooOld() const;
};

/// A value the box sends in its status and info lines, for the page that shows them all. The platforms show them in
/// this order, by groups.
enum class BoxValue
{
  // The car.
  Engine,
  Rpm,
  // Volts.
  BoxVoltage,
  ElmVoltage,
  EcuVoltage,
  // 1 if the voltage of the box differs from the car, 0 if not.
  VoltageMismatch,
  // The gyroscope.
  ImuName,
  ImuState,
  ImuChipId,
  // Hz.
  ImuRate,
  // °C.
  ImuTemperature,
  ImuErrors,
  // Seconds.
  BiasAge,
  // °/s.
  Bias,
  // OBD.
  ObdState,
  ObdProtocol,
  ObdError,
  ObdBaud,
  // The box.
  Firmware,
  BuildDate,
  Chip,
  Board,
  // The hardware revision of the board, "R1".
  Revision,
  Id,
  // KB.
  FlashSize,
  MaxImageSize,
  Slot,
  SlotState,
  Abilities,
  PowerOns,
  LastEvent,
};

/// A phone paired with the box.
struct Phone
{
  // The Bluetooth address the box knows the phone by, "AA:BB:CC:DD:EE:FF".
  std::string m_address;
  // What the phone has sent in its hello, empty if nothing.
  std::string m_name;
  // When it has connected the last time by its own clock, 0 if unknown.
  int64_t m_seenUnixS = 0;
  // The phone that has asked.
  bool m_thisPhone = false;
  // The box takes the commands that change it from this phone. Firmware without the fifth part of a phone in
  // BT_LIST tells it only of the phone that has asked: another phone is known to change it when it is the only
  // other one.
  bool m_changesBox = false;

  bool operator==(Phone const &) const = default;
};

/// The reply to the list of the phones.
struct Phones
{
  std::vector<Phone> m_phones;
  // The box takes the commands that change it from this phone: no other phone has connected before it.
  bool m_changesBox = true;
};

int constexpr kMaxPhones = 4;
size_t constexpr kMaxPhoneNameSize = 20;
// A new phone pairs with a code of this many digits, the box takes it this long.
int constexpr kPairingCodeDigits = 6;
int64_t constexpr kPairingWindowMs = 120'000;
// The code of every window the phone has not opened with its own code: the one after a power-on of a box with no
// phones and the one of 3 quick power-ons, BLE-12 and BLE-16. The system dialog of the pairing asks for it.
std::string_view constexpr kDefaultPairingCode = "123456";
// The oldest firmware this application drives. An older box is offered the update and nothing else.
std::string_view constexpr kMinFirmware = "0.6.0";

/// What a phone tells the other phone on the same box about the place of the car, see PeerSync. The box passes the
/// payload of "PEER,<payload>" on to the other phones as "NGX,1,<payload>".
struct Peer
{
  // A anchor: the place was just set. S snapshot: the place now. C correction: the user has changed the place on the
  // phone that follows. G GPS fix of the phone that follows.
  char m_kind = 'A';
  // The distance counted by the box (Data::m_distMm) at the moment of the place.
  int64_t m_distMm = 0;
  int32_t m_latE7 = 0;
  int32_t m_lonE7 = 0;
  // Hundredths of a degree clockwise from the north, -1 if the place has no heading.
  int m_headingCdeg = -1;
  // Decimeters.
  int m_accuracyDm = 0;
  // What set the place, one letter: G GPS, M the manual mode, T a tap on the map, R a reversal, W a switch to
  // another road.
  char m_source = 'G';

  bool operator==(Peer const &) const = default;
};

/// The values as the platforms show them with their units, empty if the box sends the field empty.
using BoxValues = std::vector<std::pair<BoxValue, std::string>>;

/// The firmware the box is receiving.
struct UpdateProgress
{
  // The bytes written in a row from the start of the firmware.
  uint32_t m_received = 0;
  // RECV, RESEND, VERIFY, DONE, ABORTED or ERR_<code>.
  std::string m_state;
};

// The key given to a box when a phone is paired, a nonce of a session and the proof the box answers it with, in bytes.
size_t constexpr kAuthKeyBytes = 16;
size_t constexpr kAuthNonceBytes = 8;
size_t constexpr kAuthProofBytes = 8;

uint16_t Crc16(std::string_view text);

/// \returns the first kAuthProofBytes of HMAC-SHA256(key, nonce) in lowercase hex. The key and the nonce are the bytes
/// of their hex texts, as the commands AUTH_SET and AUTH carry them. Empty if one of them is not hex of its length.
std::string AuthProof(std::string_view keyHex, std::string_view nonceHex);

/// \returns the command line to send to the box.
std::string Command(int id, std::string_view command);
/// \returns the command that sends the place to the other phone.
std::string PeerCommand(Peer const & peer);
/// \returns the hello with the name of the phone and its time, a plain one without the name.
std::string Hello(std::string_view phoneName, int64_t unixMs);
/// \returns the name of the phone the way the box takes it: printable ASCII without the separators of the lines and
/// of the list of the phones, kMaxPhoneNameSize characters at most.
std::string PhoneName(std::string_view name);

/// \returns the fields of a line with a valid checksum, the first one is the line type.
std::optional<Fields> Parse(std::string_view line);

/// \returns the data of an NGD line.
std::optional<Data> ParseData(Fields const & fields);
/// \returns the reply of an NGA line.
std::optional<Reply> ParseReply(Fields const & fields);
/// \returns the event of an NGE line.
std::optional<Event> ParseEvent(Fields const & fields);
/// \returns what an NGI line tells about the box.
std::optional<Info> ParseInfo(Fields const & fields);
/// \returns the phones from the reply to BT_LIST.
std::optional<Phones> ParsePhones(Reply const & reply);
/// \returns true if the version of a firmware ("0.5.1", "0.6.0-dirty") is lower than `than`. A version with no numbers
/// is lower than any.
bool IsFirmwareBefore(std::string_view version, std::string_view than);

/// \returns the place of the other phone from an NGX line.
std::optional<Peer> ParsePeer(Fields const & fields);
/// \returns the progress of a firmware update from an NGO line.
std::optional<UpdateProgress> ParseUpdateProgress(Fields const & fields);
/// \returns the number of the last event of the box from an NGS line, if the box tells it.
std::optional<int64_t> ParseLastEventNumber(Fields const & fields);
/// \returns the state of the OBD adapter from an NGS line: NO_ADAPTER, NO_CAR, OK etc.
std::optional<std::string> ParseObdState(Fields const & fields);
/// \returns the name of the gyroscope from an NGS line.
std::optional<std::string> ParseImuName(Fields const & fields);
/// \returns what the box tells about the car in its status.
std::optional<CarInfo> ParseCarInfo(Fields const & fields);
/// \returns the values of an NGS or an NGI line that it has, except VoltageMismatch: the events of the box change it.
BoxValues ParseBoxValues(Fields const & fields);

std::string DebugPrint(BoxValue value);
std::string DebugPrint(Phone const & phone);
}  // namespace esp32
}  // namespace nogps
