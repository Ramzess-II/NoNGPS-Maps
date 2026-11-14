#include "map/nogps/storage.hpp"

#include "base/assert.hpp"
#include "base/logging.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cctype>

namespace nogps
{
namespace
{
// What the car is, kept by the keys of the car as its values: NoGpsCar.C47D.Firmware.
std::string_view constexpr kCarFirmware = "NoGpsFirmware";
std::string_view constexpr kCarLastSeen = "NoGpsLastSeen";
// What the box of the car kept when the phone saw it the last time, "car_name:Kia,spd_scale:1.04".
std::string_view constexpr kCarKnownBoxValues = "NoGpsKnownBoxValues";

// The identifier goes into the keys and the list of the cars.
bool IsCarId(std::string_view id)
{
  return !id.empty() &&
         std::all_of(id.begin(), id.end(), [](char c) { return std::isalnum(static_cast<unsigned char>(c)) != 0; });
}
}  // namespace

std::optional<std::string> SettingsStorage::GetString(std::string_view key) const
{
  std::string value;
  if (!settings::Get(key, value))
    return {};
  return value;
}

void SettingsStorage::SetString(std::string_view key, std::string const & value)
{
  settings::Set(key, value);
}

void SettingsStorage::Remove(std::string_view key)
{
  settings::Delete(key);
}

std::string DebugPrint(Car const & car)
{
  return car.m_id + (car.m_name.empty() ? "" : " \"" + car.m_name + "\"");
}

std::string CarStorage::GetCarKey(std::string_view carId, std::string_view key)
{
  std::string_view constexpr kPrefix = "NoGps";
  ASSERT(key.starts_with(kPrefix), (key));
  key.remove_prefix(kPrefix.size());
  return std::string(kPrefix) + "Car." + std::string(carId) + "." + std::string(key);
}

bool CarStorage::IsCarValue(std::string_view key) const
{
  return std::find(kCarValues.begin(), kCarValues.end(), key) != kCarValues.end();
}

std::string CarStorage::MapKey(std::string_view key) const
{
  if (IsCarValue(key))
    if (auto const car = GetCurrentCar(); !car.empty())
      return GetCarKey(car, key);
  return std::string(key);
}

std::optional<std::string> CarStorage::GetString(std::string_view key) const
{
  return m_storage.GetString(MapKey(key));
}

void CarStorage::SetString(std::string_view key, std::string const & value)
{
  m_storage.SetString(MapKey(key), value);
}

void CarStorage::Remove(std::string_view key)
{
  m_storage.Remove(MapKey(key));
}

std::optional<std::string> CarStorage::GetCarValue(std::string const & id, std::string_view key) const
{
  return m_storage.GetString(GetCarKey(id, key));
}

void CarStorage::SetCarValue(std::string const & id, std::string_view key, std::string const & value)
{
  if (value.empty())
    m_storage.Remove(GetCarKey(id, key));
  else
    m_storage.SetString(GetCarKey(id, key), value);
}

std::map<std::string, std::string> CarStorage::GetKnownBoxValues(std::string const & id) const
{
  // The keys of the box are [a-z0-9_], its values have no commas.
  std::map<std::string, std::string> values;
  for (auto const item : strings::Tokenize(m_storage.Get<std::string>(GetCarKey(id, kCarKnownBoxValues), ""), ","))
    if (auto const colon = item.find(':'); colon != std::string_view::npos && colon + 1 < item.size())
      values.emplace(item.substr(0, colon), item.substr(colon + 1));
  return values;
}

void CarStorage::SetKnownBoxValues(std::string const & id, std::map<std::string, std::string> const & values)
{
  std::string text;
  for (auto const & [key, value] : values)
    if (!value.empty())
      text += (text.empty() ? "" : ",") + key + ":" + value;
  if (text.empty())
    m_storage.Remove(GetCarKey(id, kCarKnownBoxValues));
  else
    m_storage.Set(GetCarKey(id, kCarKnownBoxValues), text);
}

std::vector<std::string> CarStorage::GetIds() const
{
  std::vector<std::string> ids;
  for (auto const id : strings::Tokenize(m_storage.Get<std::string>(kCars, ""), ","))
    if (IsCarId(id))
      ids.emplace_back(id);
  return ids;
}

void CarStorage::SetIds(std::vector<std::string> const & ids)
{
  m_storage.Set(kCars, strings::JoinStrings(ids, ","));
}

std::vector<Car> CarStorage::GetCars() const
{
  std::vector<Car> cars;
  for (auto const & id : GetIds())
  {
    Car car;
    car.m_id = id;
    car.m_name = m_storage.Get<std::string>(GetCarKey(id, kCarName), "");
    car.m_firmware = m_storage.Get<std::string>(GetCarKey(id, kCarFirmware), "");
    car.m_lastSeenUnixMs = m_storage.Get<int64_t>(GetCarKey(id, kCarLastSeen), 0);
    cars.push_back(std::move(car));
  }
  return cars;
}

std::string CarStorage::GetCurrentCar() const
{
  // The adapter is not a box: the car it is in is not known.
  if (!m_storage.IsEsp32Source())
    return {};
  return m_storage.Get<std::string>(kCurrentCar, "");
}

void CarStorage::OnBoxHeard(std::string const & id, std::string const & firmware, int64_t unixMs)
{
  if (!IsCarId(id))
  {
    LOG(LWARNING, ("Wrong box id", id));
    return;
  }
  auto ids = GetIds();
  if (ids.empty())
  {
    // The navigation was on by default before the choice was saved, a user who had heard a box keeps it on.
    if (!m_storage.GetString(kInertialEnabled))
      m_storage.Set(kInertialEnabled, m_storage.IsInertialEnabled());
    auto const accel = m_storage.Get<std::string>(kBoxAccel, "");
    std::string owner = accel.substr(0, accel.find(':'));
    if (!IsCarId(owner))
      owner = id;
    for (auto const key : kCarValues)
    {
      if (auto const value = m_storage.GetString(key))
      {
        m_storage.SetString(GetCarKey(owner, key), *value);
        m_storage.Remove(key);
      }
    }
    LOG(LINFO, ("The values learned before the cars go to the car", owner));
    if (owner != id)
      ids.push_back(owner);
  }
  if (std::find(ids.begin(), ids.end(), id) == ids.end())
  {
    LOG(LINFO, ("New car", id));
    ids.push_back(id);
    SetIds(ids);
  }
  if (m_storage.Get<std::string>(kCurrentCar, "") != id)
    m_storage.Set(kCurrentCar, id);
  if (m_storage.Get<std::string>(GetCarKey(id, kCarFirmware), "") != firmware)
    m_storage.Set(GetCarKey(id, kCarFirmware), firmware);
  m_storage.Set(GetCarKey(id, kCarLastSeen), unixMs);
}

bool CarStorage::SelectCar(std::string const & id)
{
  auto const ids = GetIds();
  if (std::find(ids.begin(), ids.end(), id) == ids.end())
    return false;
  m_storage.Set(kCurrentCar, id);
  return true;
}

void CarStorage::RenameCar(std::string const & id, std::string const & name)
{
  auto const ids = GetIds();
  if (std::find(ids.begin(), ids.end(), id) == ids.end())
    return;
  // A line of the settings.
  std::string text = name;
  std::replace(text.begin(), text.end(), '\n', ' ');
  strings::Trim(text);
  SetCarValue(id, kCarName, text);
}

void CarStorage::ForgetCar(std::string const & id)
{
  auto ids = GetIds();
  auto const it = std::find(ids.begin(), ids.end(), id);
  if (it == ids.end())
    return;
  LOG(LINFO, ("Forget the car", id));
  ids.erase(it);
  SetIds(ids);
  for (auto const key : kCarValues)
    m_storage.Remove(GetCarKey(id, key));
  for (auto const key : {kCarName, kCarFirmware, kCarLastSeen, kCarKnownBoxValues})
    m_storage.Remove(GetCarKey(id, key));
  if (m_storage.Get<std::string>(kCurrentCar, "") != id)
    return;
  auto const cars = GetCars();
  auto const last = std::max_element(
      cars.begin(), cars.end(), [](Car const & a, Car const & b) { return a.m_lastSeenUnixMs < b.m_lastSeenUnixMs; });
  if (last == cars.end())
    m_storage.Remove(kCurrentCar);
  else
    m_storage.Set(kCurrentCar, last->m_id);
}
}  // namespace nogps
