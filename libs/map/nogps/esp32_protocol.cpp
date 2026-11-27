#include "map/nogps/esp32_protocol.hpp"

#include "base/string_utils.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include <boost/hash2/hmac.hpp>
#include <boost/hash2/sha2.hpp>

namespace nogps
{
namespace esp32
{
namespace
{
std::string_view TrimLine(std::string_view s)
{
  while (!s.empty() && static_cast<unsigned char>(s.front()) <= ' ')
    s.remove_prefix(1);
  while (!s.empty() && static_cast<unsigned char>(s.back()) <= ' ')
    s.remove_suffix(1);
  return s;
}

// Splits by commas keeping the empty fields: the optional fields of the status may be empty.
Fields SplitFields(std::string_view body)
{
  Fields fields;
  while (true)
  {
    auto const comma = body.find(',');
    fields.emplace_back(body.substr(0, comma));
    if (comma == std::string_view::npos)
      return fields;
    body.remove_prefix(comma + 1);
  }
}

bool IsLine(Fields const & fields, size_t minSize, std::string_view type)
{
  return fields.size() >= minSize && fields[0] == type;
}

// Returns -1 for an absent or an empty field.
int ParseOptionalInt(Fields const & fields, size_t index)
{
  int value;
  if (index >= fields.size() || !strings::to_int(fields[index], value))
    return -1;
  return value;
}

// A field of a line shown on the page of the box values. A field the box sends in smaller units is divided.
struct BoxField
{
  size_t m_index;
  BoxValue m_value;
  int m_divisor = 1;
  int m_decimals = 0;
};

// The firmware is in both lines, it is shown from the status.
BoxField constexpr kStatusFields[] = {
    {2, BoxValue::Firmware},
    {3, BoxValue::ImuName},
    {4, BoxValue::ImuRate},
    {5, BoxValue::ObdState},
    {6, BoxValue::ObdProtocol},
    {7, BoxValue::BiasAge},
    {8, BoxValue::ImuTemperature, 10, 1},
    {9, BoxValue::ImuErrors},
    {10, BoxValue::ImuState},
    {11, BoxValue::ImuChipId},
    {12, BoxValue::ObdError},
    {13, BoxValue::ObdBaud},
    {14, BoxValue::Bias, 1000, 3},
    {15, BoxValue::LastEvent},
    {16, BoxValue::Engine},
    {17, BoxValue::Rpm},
    {18, BoxValue::BoxVoltage, 1000, 2},
    {19, BoxValue::ElmVoltage, 1000, 2},
    {20, BoxValue::EcuVoltage, 1000, 2},
};

BoxField constexpr kInfoFields[] = {
    {3, BoxValue::BuildDate}, {4, BoxValue::Chip},       {5, BoxValue::Board},
    {6, BoxValue::Id},        {7, BoxValue::FlashSize},  {8, BoxValue::MaxImageSize, 1024, 0},
    {9, BoxValue::Slot},      {10, BoxValue::SlotState}, {11, BoxValue::Abilities},
    {12, BoxValue::PowerOns}, {13, BoxValue::Revision},
};

// An empty or a wrong field is shown as it is.
std::string ToBoxValue(std::string const & field, int divisor, int decimals)
{
  int64_t value;
  if (divisor == 1 || !strings::to_int(field, value))
    return field;
  char text[32];
  std::snprintf(text, sizeof(text), "%.*f", decimals, static_cast<double>(value) / divisor);
  return text;
}

template <size_t N>
BoxValues ToBoxValues(Fields const & fields, BoxField const (&boxFields)[N])
{
  BoxValues values;
  for (auto const & field : boxFields)
    if (field.m_index < fields.size())
      values.emplace_back(field.m_value, ToBoxValue(fields[field.m_index], field.m_divisor, field.m_decimals));
  std::sort(values.begin(), values.end());
  return values;
}
}  // namespace

uint16_t Crc16(std::string_view text)
{
  uint16_t crc = 0xFFFF;
  for (char const c : text)
  {
    crc ^= static_cast<uint16_t>(static_cast<unsigned char>(c) << 8);
    for (int i = 0; i < 8; ++i)
      crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021) : static_cast<uint16_t>(crc << 1);
  }
  return crc;
}

std::string AuthProof(std::string_view keyHex, std::string_view nonceHex)
{
  auto const decode = [](std::string_view hex, size_t size) -> std::optional<std::string>
  {
    if (hex.size() != size * 2)
      return {};
    std::string bytes;
    for (size_t i = 0; i < hex.size(); i += 2)
    {
      unsigned value = 0;
      for (char const c : hex.substr(i, 2))
      {
        value <<= 4;
        if (c >= '0' && c <= '9')
          value += c - '0';
        else if (c >= 'a' && c <= 'f')
          value += c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
          value += c - 'A' + 10;
        else
          return {};
      }
      bytes += static_cast<char>(value);
    }
    return bytes;
  };
  auto const key = decode(keyHex, kAuthKeyBytes);
  auto const nonce = decode(nonceHex, kAuthNonceBytes);
  if (!key || !nonce)
    return {};
  boost::hash2::hmac<boost::hash2::sha2_256> hmac(key->data(), key->size());
  hmac.update(nonce->data(), nonce->size());
  auto const digest = hmac.result();
  char constexpr kHex[] = "0123456789abcdef";
  std::string proof;
  for (size_t i = 0; i < kAuthProofBytes; ++i)
  {
    proof += kHex[digest[i] >> 4];
    proof += kHex[digest[i] & 15];
  }
  return proof;
}

std::string Command(int id, std::string_view command)
{
  std::string const body = "NGC," + std::to_string(id) + "," + std::string(command);
  char crc[8];
  std::snprintf(crc, sizeof(crc), "%04X", Crc16(body));
  return "$" + body + "*" + crc + "\r\n";
}

std::string Hello(std::string_view phoneName, int64_t unixMs)
{
  if (phoneName.empty())
    return "HELLO";
  return "HELLO," + std::string(phoneName) + "," + std::to_string(unixMs / 1000);
}

std::string PeerCommand(Peer const & peer)
{
  return "PEER," + std::string(1, peer.m_kind) + "," + std::to_string(peer.m_distMm) + "," +
         std::to_string(peer.m_latE7) + "," + std::to_string(peer.m_lonE7) + "," + std::to_string(peer.m_headingCdeg) +
         "," + std::to_string(peer.m_accuracyDm) + "," + std::string(1, peer.m_source);
}

std::string PhoneName(std::string_view name)
{
  strings::Trim(name);
  std::string result;
  for (char const c : name.substr(0, kMaxPhoneNameSize))
  {
    bool const bad = c < 0x20 || c > 0x7E || std::string_view(",*$|;").find(c) != std::string_view::npos;
    result += bad ? '_' : c;
  }
  strings::Trim(result);
  return result;
}

std::optional<Fields> Parse(std::string_view line)
{
  auto const trimmed = TrimLine(line);
  auto const star = trimmed.rfind('*');
  if (trimmed.empty() || trimmed.front() != '$' || star == std::string_view::npos || trimmed.size() != star + 5)
    return {};
  auto const body = trimmed.substr(1, star - 1);
  uint32_t crc;
  if (!strings::to_uint(trimmed.substr(star + 1), crc, 16) || crc != Crc16(body))
    return {};
  return SplitFields(body);
}

std::optional<Data> ParseData(Fields const & fields)
{
  int version;
  if (!IsLine(fields, 10, "NGD") || !strings::to_int(fields[1], version) || version != kVersion)
    return {};
  Data data;
  if (!strings::to_int(fields[2], data.m_seq) || !strings::to_int(fields[3], data.m_timeMs) ||
      !strings::to_int(fields[4], data.m_yawMdeg) || !strings::to_int(fields[5], data.m_rateMdps) ||
      !strings::to_int(fields[6], data.m_distMm) || !strings::to_int(fields[7], data.m_speedKmh) ||
      !strings::to_int(fields[8], data.m_speedAgeMs) || !strings::to_int(fields[9], data.m_flags, 16))
  {
    return {};
  }
  if (fields.size() >= 14 && !fields[10].empty())
  {
    int h1, h2, up, jolt;
    if (!strings::to_int(fields[10], h1) || !strings::to_int(fields[11], h2) || !strings::to_int(fields[12], up) ||
        !strings::to_int(fields[13], jolt))
    {
      return {};
    }
    data.m_accelH1 = h1 / 1000.0;
    data.m_accelH2 = h2 / 1000.0;
    data.m_accelUp = up / 1000.0;
    data.m_jolt = jolt / 1000.0;
    data.m_hasAccel = true;
  }
  if (fields.size() >= 15 && !fields[14].empty() && !strings::to_int(fields[14], data.m_shakePct))
    return {};
  return data;
}

std::optional<Reply> ParseReply(Fields const & fields)
{
  Reply reply;
  if (!IsLine(fields, 3, "NGA") || !strings::to_int(fields[1], reply.m_id))
    return {};
  if (fields[2] == "OK")
  {
    reply.m_ok = true;
    reply.m_values.assign(fields.begin() + 3, fields.end());
  }
  else if (fields[2] == "PROGRESS")
  {
    int progress = 0;
    if (fields.size() > 3 && !strings::to_int(fields[3], progress))
      return {};
    reply.m_progress = progress;
  }
  else if (fields[2] == "ERR")
  {
    if (fields.size() > 3)
      reply.m_error = fields[3];
  }
  else
  {
    return {};
  }
  return reply;
}

std::optional<Event> ParseEvent(Fields const & fields)
{
  Event event;
  if (!IsLine(fields, 7, "NGE") || !strings::to_int(fields[2], event.m_number) ||
      !strings::to_int(fields[3], event.m_timeMs))
  {
    return {};
  }
  event.m_level = fields[4];
  event.m_code = fields[5];
  event.m_text = fields[6];
  return event;
}

std::optional<Info> ParseInfo(Fields const & fields)
{
  // Version, firmware, build date, chip, board, id, flash size, largest image, partition, its state, abilities,
  // power-ons, hardware revision.
  int version;
  if (!IsLine(fields, 6, "NGI") || !strings::to_int(fields[1], version) || version != kVersion)
    return {};
  Info info;
  info.m_firmware = fields[2];
  info.m_chip = fields[4];
  info.m_board = fields[5];
  if (fields.size() > 11)
  {
    for (auto const ability : strings::Tokenize(fields[11], " "))
      if (ability == "OTA")
        info.m_canUpdate = true;
  }
  if (fields.size() > 6)
    info.m_id = fields[6];
  if (int64_t powerOns; fields.size() > 12 && strings::to_int(fields[12], powerOns))
    info.m_powerOns = powerOns;
  if (fields.size() > 13)
    info.m_revision = fields[13];
  return info;
}

bool Info::IsTooOld() const
{
  return IsFirmwareBefore(m_firmware, kMinFirmware);
}

bool IsFirmwareBefore(std::string_view version, std::string_view than)
{
  // A build may add a suffix ("0.6.0-dirty"): the numbers tell the firmware.
  auto const numbers = [](std::string_view text)
  {
    std::vector<int> result;
    text = text.substr(0, text.find_first_not_of("0123456789."));
    for (auto const part : strings::Tokenize(text, "."))
    {
      int number = 0;
      strings::to_int(part, number);
      result.push_back(number);
    }
    return result;
  };
  return numbers(version) < numbers(than);
}

std::optional<Phones> ParsePhones(Reply const & reply)
{
  // OK,<address>|<name>|<seen, Unix s>|<1 if this phone>[|<1 if the box takes changes from it>];...,
  // <1 if this phone changes the box>
  if (!reply.m_ok || reply.m_values.empty())
    return {};
  Phones phones;
  bool known = true;
  if (reply.m_values.size() > 1)
    phones.m_changesBox = reply.m_values[1] != "0";
  if (reply.m_values[0].empty())
    return phones;
  for (auto const item : strings::Tokenize(reply.m_values[0], ";"))
  {
    // Tokenize skips the empty parts, a phone without a name has them.
    std::vector<std::string_view> parts;
    for (size_t start = 0;;)
    {
      size_t const bar = item.find('|', start);
      parts.push_back(item.substr(start, bar == std::string_view::npos ? std::string_view::npos : bar - start));
      if (bar == std::string_view::npos)
        break;
      start = bar + 1;
    }
    if (parts.size() < 4 || parts[0].empty())
      return {};
    Phone phone;
    phone.m_address = parts[0];
    phone.m_name = parts[1];
    if (!parts[2].empty() && !strings::to_int(parts[2], phone.m_seenUnixS))
      return {};
    phone.m_thisPhone = parts[3] == "1";
    // Older firmware has no fifth part.
    if (parts.size() > 4)
      phone.m_changesBox = parts[4] == "1";
    else
      known = false;
    phones.m_phones.push_back(std::move(phone));
  }
  auto const others = std::count_if(phones.m_phones.begin(), phones.m_phones.end(),
                                    [](Phone const & phone) { return !phone.m_thisPhone; });
  for (auto & phone : phones.m_phones)
  {
    // The box tells about this phone itself: it changes the box also when no phone has sent HELLO.
    if (phone.m_thisPhone)
      phone.m_changesBox = phones.m_changesBox;
    else if (!known)
      phone.m_changesBox = !phones.m_changesBox && others == 1;
  }
  return phones;
}

std::optional<Peer> ParsePeer(Fields const & fields)
{
  // NGX,<version>,<kind>,<dist_mm>,<lat_e7>,<lon_e7>,<heading_cdeg>,<acc_dm>,<src>
  int version;
  if (!IsLine(fields, 9, "NGX") || !strings::to_int(fields[1], version) || version != kVersion ||
      fields[2].size() != 1 || fields[8].size() != 1 ||
      std::string_view("ASCG").find(fields[2][0]) == std::string_view::npos)
  {
    return {};
  }
  Peer peer;
  peer.m_kind = fields[2][0];
  peer.m_source = fields[8][0];
  if (!strings::to_int(fields[3], peer.m_distMm) || !strings::to_int(fields[4], peer.m_latE7) ||
      !strings::to_int(fields[5], peer.m_lonE7) || !strings::to_int(fields[6], peer.m_headingCdeg) ||
      !strings::to_int(fields[7], peer.m_accuracyDm))
  {
    return {};
  }
  // A wrong place is worse than none.
  if (peer.m_latE7 < -900'000'000 || peer.m_latE7 > 900'000'000 || peer.m_lonE7 < -1'800'000'000 ||
      peer.m_lonE7 > 1'800'000'000 || peer.m_headingCdeg < -1 || peer.m_headingCdeg >= 36000 || peer.m_accuracyDm < 0 ||
      peer.m_accuracyDm > kMaxPeerAccuracyDm || peer.m_distMm < 0)
  {
    return {};
  }
  return peer;
}

std::optional<UpdateProgress> ParseUpdateProgress(Fields const & fields)
{
  int version;
  UpdateProgress progress;
  if (!IsLine(fields, 4, "NGO") || !strings::to_int(fields[1], version) || version != kVersion ||
      !strings::to_uint(fields[2], progress.m_received))
  {
    return {};
  }
  progress.m_state = fields[3];
  return progress;
}

std::optional<int64_t> ParseLastEventNumber(Fields const & fields)
{
  int64_t number;
  if (!IsLine(fields, 16, "NGS") || !strings::to_int(fields[15], number))
    return {};
  return number;
}

std::optional<std::string> ParseObdState(Fields const & fields)
{
  if (!IsLine(fields, 6, "NGS"))
    return {};
  return fields[5];
}

std::optional<std::string> ParseImuName(Fields const & fields)
{
  if (!IsLine(fields, 4, "NGS"))
    return {};
  return fields[3];
}

std::optional<CarInfo> ParseCarInfo(Fields const & fields)
{
  // Fields 17-21 of the status: engine, rpm, the voltage measured by the box, by ELM327 and by the control
  // unit of the car. Older firmwares send less fields.
  if (!IsLine(fields, 17, "NGS"))
    return {};
  CarInfo car;
  if (fields[16] == "RUN")
    car.m_engineRunning = true;
  else if (fields[16] == "OFF")
    car.m_engineRunning = false;
  car.m_rpm = ParseOptionalInt(fields, 17);
  car.m_boxMillivolts = ParseOptionalInt(fields, 18);
  car.m_elmMillivolts = ParseOptionalInt(fields, 19);
  car.m_ecuMillivolts = ParseOptionalInt(fields, 20);
  int const reference = car.GetReferenceMillivolts();
  car.m_voltageMismatch = car.m_boxMillivolts >= 0 && reference >= 0 &&
                          std::abs(car.m_boxMillivolts - reference) * 100 > reference * kMaxVoltageDiffPercent;
  return car;
}

BoxValues ParseBoxValues(Fields const & fields)
{
  int version;
  if (fields.size() < 2 || !strings::to_int(fields[1], version) || version != kVersion)
    return {};
  if (fields[0] == "NGS")
    return ToBoxValues(fields, kStatusFields);
  if (fields[0] == "NGI")
    return ToBoxValues(fields, kInfoFields);
  return {};
}

std::string DebugPrint(BoxValue value)
{
  return std::to_string(static_cast<int>(value));
}

std::string DebugPrint(Phone const & phone)
{
  return phone.m_address + " " + phone.m_name + " seen " + std::to_string(phone.m_seenUnixS) +
         (phone.m_thisPhone ? " this" : "") + (phone.m_changesBox ? " changes" : "");
}
}  // namespace esp32
}  // namespace nogps
