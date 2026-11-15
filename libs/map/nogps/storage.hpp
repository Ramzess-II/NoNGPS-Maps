#pragma once

#include "platform/settings.hpp"

#include <array>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace nogps
{
/// What the navigation without GPS keeps between the starts of the app: the settings and what it has learned.
class Storage
{
public:
  // The keys are shared with the settings of the Android app made before the navigation moved to the core.
  static std::string_view constexpr kInertialEnabled = "NoGpsInertialEnabled";
  static std::string_view constexpr kElm327Address = "NoGpsElm327Address";
  static std::string_view constexpr kEsp32Source = "NoGpsEsp32Source";
  // The user has chosen to ignore GPS, see Engine::SetGpsDisabled().
  static std::string_view constexpr kGpsDisabled = "NoGpsGpsDisabled";
  static std::string_view constexpr kSpeedScale = "NoGpsSpeedScale";
  static std::string_view constexpr kSpeedTable = "NoGpsSpeedTable";
  static std::string_view constexpr kRoughSpeedTable = "NoGpsRoughSpeedTable";
  static std::string_view constexpr kSpeedFactor = "NoGpsSpeedFactor";
  static std::string_view constexpr kSpeedLag = "NoGpsSpeedLag";
  // How the accelerometer of the sensor box is fixed in the car: the identifier of the box and what is learned.
  static std::string_view constexpr kBoxAccel = "NoGpsBoxAccel";
  static std::string_view constexpr kWrongNetworkPoints = "NoGpsWrongNetworkPoints";
  static std::string_view constexpr kLastTrusted = "NoGpsLastTrusted";
  // Where the car was left and the way it looked, "lat,lon,bearing,manual,unixMs": "-" for an unknown bearing, 1 if
  // GPS was not trusted then.
  static std::string_view constexpr kCarPosition = "NoGpsCarPosition";
  // When the ESP32 sensor box was powered on the last time, milliseconds since the Unix epoch: for a box that
  // doesn't count its power-ons.
  static std::string_view constexpr kBoxPowerOnTime = "NoGpsBoxPowerOnTime";
  // How many times the known boxes were powered on by their own count, "C47D:3,42FD:1".
  static std::string_view constexpr kBoxPowerOns = "NoGpsBoxPowerOns";
  // The box has been powered on since the user calibrated it.
  static std::string_view constexpr kBoxCalibrationAdvised = "NoGpsBoxCalibrationAdvised";
  // The identifiers of the boxes of the cars of the user, "C47D,42FD", see CarStorage.
  static std::string_view constexpr kCars = "NoGpsCars";
  // The car of the box heard the last time or chosen by the user.
  static std::string_view constexpr kCurrentCar = "NoGpsCurrentCar";

  virtual ~Storage() = default;

  virtual std::optional<std::string> GetString(std::string_view key) const = 0;
  virtual void SetString(std::string_view key, std::string const & value) = 0;
  virtual void Remove(std::string_view key) = 0;

  template <class T>
  T Get(std::string_view key, T const & defaultValue) const
  {
    auto const s = GetString(key);
    T value;
    if (s && settings::FromString(*s, value))
      return value;
    return defaultValue;
  }

  template <class T>
  void Set(std::string_view key, T const & value)
  {
    SetString(key, settings::ToString(value));
  }

  // A new user has no box until they connect one. The choice was not saved while the navigation was on by
  // default: who has heard a box or chosen the ELM327 adapter then keeps it.
  bool IsInertialEnabled() const
  {
    return Get<bool>(kInertialEnabled, GetString(kElm327Address) || GetString(kBoxAccel) || GetString(kBoxPowerOns) ||
                                           GetString(kBoxPowerOnTime));
  }
  // Who has chosen the ELM327 adapter, when the phone was the default source, keeps the phone.
  bool IsEsp32Source() const { return Get<bool>(kEsp32Source, Get<std::string>(kElm327Address, "").empty()); }
};

/// The storage in the settings of the app.
class SettingsStorage : public Storage
{
public:
  std::optional<std::string> GetString(std::string_view key) const override;
  void SetString(std::string_view key, std::string const & value) override;
  void Remove(std::string_view key) override;
};

/// A car is known by the sensor box in it.
struct Car
{
  // The four characters of the name of the box, NoGPS-XXXX.
  std::string m_id;
  // Empty until the user names the car: the platforms show "Car C47D".
  std::string m_name;
  std::string m_firmware;
  // When the box told about itself the last time, milliseconds since the Unix epoch.
  int64_t m_lastSeenUnixMs = 0;
};

std::string DebugPrint(Car const & car);

/// What is learned about a car is kept for each car of the user: one phone is driven in several cars. The values of
/// kCarValues are read and written by their keys as before, for the current car. They are kept by the keys of the car,
/// see GetCarKey(). Without a car (no box heard yet, or the phone with an ELM327 adapter is the source) the values are
/// kept by the keys themselves, as before the cars: they go to the first car when it is heard.
class CarStorage : public Storage
{
public:
  static std::array<std::string_view, 10> constexpr kCarValues = {
      kSpeedScale, kSpeedTable,  kRoughSpeedTable, kSpeedFactor, kSpeedLag,
      kBoxAccel,   kCarPosition, kBoxPowerOnTime,  kBoxPowerOns, kBoxCalibrationAdvised,
  };
  // The name the user has given the car, kept by the keys of the car as its values: NoGpsCar.C47D.Name.
  static std::string_view constexpr kCarName = "NoGpsName";
  // The values the box of the car keeps too, see BoxCarValues.
  static std::array<std::string_view, 7> constexpr kValuesOnBox = {
      kSpeedTable, kRoughSpeedTable, kSpeedFactor, kSpeedLag, kSpeedScale, kCarName, kCarPosition,
  };

  explicit CarStorage(Storage & storage) : m_storage(storage) {}

  /// The key a value of the car is kept by: NoGpsCar.C47D.SpeedTable for NoGpsSpeedTable.
  static std::string GetCarKey(std::string_view carId, std::string_view key);

  std::optional<std::string> GetString(std::string_view key) const override;
  void SetString(std::string_view key, std::string const & value) override;
  void Remove(std::string_view key) override;

  /// In the order the cars were added.
  std::vector<Car> GetCars() const;
  /// Empty without a car.
  std::string GetCurrentCar() const;
  /// The box has told about itself: its car is the current one, a box not heard before is a new car. The values kept
  /// before the cars go to the first car: of the box the accelerometer was learned with, else of this one.
  void OnBoxHeard(std::string const & id, std::string const & firmware, int64_t unixMs);
  /// \returns false if there is no such car.
  bool SelectCar(std::string const & id);
  /// An empty name gives the car its usual name back.
  void RenameCar(std::string const & id, std::string const & name);
  /// Forgets the car with all its values. Another car, the one heard last, becomes the current one.
  void ForgetCar(std::string const & id);

  /// A value of the car, whether it is the current one or not.
  std::optional<std::string> GetCarValue(std::string const & id, std::string_view key) const;
  /// Empty removes the value.
  void SetCarValue(std::string const & id, std::string_view key, std::string const & value);
  /// What the box of the car kept when the phone saw it the last time, by the keys of the box, see BoxCarValues.
  std::map<std::string, std::string> GetKnownBoxValues(std::string const & id) const;
  void SetKnownBoxValues(std::string const & id, std::map<std::string, std::string> const & values);

private:
  std::vector<std::string> GetIds() const;
  void SetIds(std::vector<std::string> const & ids);
  bool IsCarValue(std::string_view key) const;
  std::string MapKey(std::string_view key) const;

  Storage & m_storage;
};
}  // namespace nogps
