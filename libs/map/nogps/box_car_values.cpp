#include "map/nogps/box_car_values.hpp"

#include "map/nogps/clock.hpp"
#include "map/nogps/esp32_source.hpp"

#include "base/assert.hpp"
#include "base/logging.hpp"

#include <algorithm>
#include <cstdio>

namespace nogps
{
namespace
{
// The keys of the box for the values of the phone: 1-15 characters of [a-z0-9_].
struct BoxKeys
{
  std::string_view m_key;
  std::string_view m_box;
  // The second half of a table, empty for a value kept whole.
  std::string_view m_secondHalf;
};

BoxKeys constexpr kBoxKeys[] = {
    {Storage::kSpeedTable, "spd_table_lo", "spd_table_hi"},
    {Storage::kRoughSpeedTable, "spd_rough_lo", "spd_rough_hi"},
    {Storage::kSpeedFactor, "spd_factor", {}},
    {Storage::kSpeedLag, "spd_lag", {}},
    {Storage::kSpeedScale, "spd_scale", {}},
    {CarStorage::kCarName, "car_name", {}},
    {Storage::kCarPosition, "car_pos", {}},
};

BoxKeys const & FindBoxKeys(std::string_view key)
{
  auto const it =
      std::find_if(std::begin(kBoxKeys), std::end(kBoxKeys), [key](BoxKeys const & k) { return k.m_key == key; });
  CHECK(it != std::end(kBoxKeys), (key));
  return *it;
}

// A value of the box is printable ASCII without ",", "*" and "$".
std::string EncodeByte(char c)
{
  auto const u = static_cast<unsigned char>(c);
  if (u < 0x20 || u > 0x7E || c == '%' || c == ',' || c == '*' || c == '$')
  {
    char hex[4];
    std::snprintf(hex, sizeof(hex), "%%%02X", u);
    return hex;
  }
  return std::string(1, c);
}

// The name is cut between its characters.
std::string Escape(std::string const & value, bool cut)
{
  std::string result;
  for (size_t i = 0; i < value.size();)
  {
    // The bytes of a UTF-8 character that follow its first one are 10xxxxxx.
    size_t end = i + 1;
    while (end < value.size() && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80)
      ++end;
    std::string character;
    for (; i < end; ++i)
      character += EncodeByte(value[i]);
    if (cut && result.size() + character.size() > BoxCarValues::kMaxNameSize)
      break;
    result += character;
  }
  return result;
}

int HexDigit(char c)
{
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  return -1;
}

std::string Unescape(std::string_view value)
{
  std::string result;
  for (size_t i = 0; i < value.size(); ++i)
  {
    int const high = value[i] == '%' && i + 2 < value.size() ? HexDigit(value[i + 1]) : -1;
    int const low = high >= 0 ? HexDigit(value[i + 2]) : -1;
    if (low < 0)
    {
      result += value[i];
      continue;
    }
    result += static_cast<char>(high * 16 + low);
    i += 2;
  }
  return result;
}

std::string GetValue(BoxCarValues::Values const & values, std::string_view key)
{
  auto const it = values.find(std::string(key));
  return it == values.end() ? std::string() : it->second;
}
}  // namespace

std::vector<std::pair<std::string, std::string>> BoxCarValues::Encode(std::string_view key, std::string const & value)
{
  auto const & keys = FindBoxKeys(key);
  if (keys.m_secondHalf.empty())
  {
    // The commas of the place would be escaped, colons are shorter.
    std::string text = value;
    if (key == Storage::kCarPosition)
      std::replace(text.begin(), text.end(), ',', ':');
    return {{std::string(keys.m_box), Escape(text, key == CarStorage::kCarName)}};
  }
  // The ranges of the table go by ";": the first half of them and the rest.
  size_t const ranges = std::count(value.begin(), value.end(), ';') + 1;
  size_t split = std::string::npos;
  for (size_t i = 0; i < (ranges + 1) / 2; ++i)
    split = value.find(';', split + 1);
  std::string const low = value.substr(0, split);
  std::string const high = split == std::string::npos ? "" : value.substr(split + 1);
  return {{std::string(keys.m_box), Escape(low, false)}, {std::string(keys.m_secondHalf), Escape(high, false)}};
}

std::optional<std::string> BoxCarValues::Decode(std::string_view key, Values const & values)
{
  auto const & keys = FindBoxKeys(key);
  auto const first = GetValue(values, keys.m_box);
  if (first.empty())
    return {};
  if (!keys.m_secondHalf.empty())
  {
    // A half written without the other one is not a table.
    auto const second = GetValue(values, keys.m_secondHalf);
    if (second.empty())
      return {};
    return Unescape(first) + ";" + Unescape(second);
  }
  std::string value = Unescape(first);
  if (key == Storage::kCarPosition)
    std::replace(value.begin(), value.end(), ':', ',');
  return value;
}

void BoxCarValues::OnBoxHeard(Esp32Source & box, std::string const & carId)
{
  m_carId = carId;
  m_boxValues.reset();
  m_busy = false;
  std::vector<std::string> keys;
  for (auto const & k : kBoxKeys)
  {
    keys.emplace_back(k.m_box);
    if (!k.m_secondHalf.empty())
      keys.emplace_back(k.m_secondHalf);
  }
  box.ReadCarValues(std::move(keys));
}

BoxCarValues::Taken BoxCarValues::OnValues(Esp32Source & box, Values const & values)
{
  auto const known = m_cars.GetKnownBoxValues(m_carId);
  m_boxValues = values;
  m_cars.SetKnownBoxValues(m_carId, values);
  Taken taken;
  std::vector<std::string> takenKeys;
  for (auto const key : CarStorage::kValuesOnBox)
  {
    // A box without the value has lost it or has not got it yet: Save() gives it the value of the phone.
    auto const boxValue = Decode(key, values);
    if (!boxValue)
      continue;
    // The box keeps what the phone saw there the last time: the value of the phone is newer, if it differs. Another
    // phone has written the box since: its value is newer.
    auto const & keys = FindBoxKeys(key);
    bool const changed = GetValue(values, keys.m_box) != GetValue(known, keys.m_box) ||
                         GetValue(values, keys.m_secondHalf) != GetValue(known, keys.m_secondHalf);
    if (!changed || boxValue == m_cars.GetCarValue(m_carId, key))
      continue;
    m_cars.SetCarValue(m_carId, key, *boxValue);
    takenKeys.emplace_back(key);
    if (key == Storage::kCarPosition)
      taken.m_position = true;
    else if (key != CarStorage::kCarName)
      taken.m_calibration = true;
  }
  LOG(LINFO, ("The values of the car", m_carId, "taken from its box:", takenKeys));
  Save(&box, true /* now */);
  return taken;
}

void BoxCarValues::OnWritten(std::string const & key, std::string const & value, std::string const & error)
{
  if (!m_boxValues)
    return;
  if (error.empty())
  {
    (*m_boxValues)[key] = value;
    m_cars.SetKnownBoxValues(m_carId, *m_boxValues);
    return;
  }
  // Another phone keeps the box: what it writes there is taken at the next connection.
  if (error == "BUSY" && !m_busy)
  {
    LOG(LINFO, ("Another phone keeps the box of the car", m_carId));
    m_busy = true;
  }
}

void BoxCarValues::Save(Esp32Source * box, bool now)
{
  if (!box || !box->CanStoreCarValues() || !m_boxValues || m_busy)
    return;
  int64_t const nowMs = m_clock.NowMs();
  if (!now && m_savedMs && nowMs - *m_savedMs < kSaveIntervalMs)
    return;
  // A value changed since is written at the next time.
  m_savedMs = nowMs;
  std::vector<std::string> written;
  for (auto const key : CarStorage::kValuesOnBox)
  {
    for (auto const & [boxKey, value] : Encode(key, m_cars.GetCarValue(m_carId, key).value_or("")))
    {
      if (GetValue(*m_boxValues, boxKey) == value)
        continue;
      box->WriteCarValue(boxKey, value);
      written.push_back(boxKey);
    }
  }
  if (!written.empty())
    LOG(LINFO, ("The values of the car", m_carId, "written to its box:", written));
}
}  // namespace nogps
