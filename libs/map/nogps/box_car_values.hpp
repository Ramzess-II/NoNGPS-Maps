#pragma once

#include "map/nogps/storage.hpp"

#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace nogps
{
class Clock;
class Esp32Source;

/// The sensor box keeps the values of its car for every phone in the car: the speed calibration, the name and where
/// the car was left, see "Машини" in docs/nogps/navigation-rules.md. The values of the car in the phone are a cache of
/// them. The phone remembers what the box kept when it saw it the last time: a value changed there since was written by
/// another phone, the phone takes it. Otherwise the value of the phone is newer and is written to the box.
class BoxCarValues
{
public:
  // A value changed by the phone is written not more often, not to wear the flash of the box out.
  static int64_t constexpr kSaveIntervalMs = 5 * 60 * 1000;
  // The box keeps values up to this long.
  static size_t constexpr kMaxValueSize = 200;
  // The phone writes a line in one piece of Bluetooth, iOS takes 182 bytes: the name is cut to fit.
  static size_t constexpr kMaxNameSize = 140;
  static size_t constexpr kMaxLineSize = 182;
  // The box doesn't tell a phone connected second that the first one has renamed the car: it reads the name this often.
  static int64_t constexpr kReadNameIntervalMs = 60 * 1000;

  /// The values of the box by its keys.
  using Values = std::map<std::string, std::string>;

  /// What the phone has taken from the box.
  struct Taken
  {
    bool m_calibration = false;
    bool m_position = false;
    bool m_name = false;
  };

  BoxCarValues(CarStorage & cars, Clock const & clock) : m_cars(cars), m_clock(clock) {}

  /// \returns the values the box keeps for |value| of |key| of CarStorage::kValuesOnBox, by their keys on the box: a
  /// speed table is longer than a value of the box, it is kept in two halves. Empty values erase them.
  static std::vector<std::pair<std::string, std::string>> Encode(std::string_view key, std::string const & value);
  /// \returns the value of |key| of CarStorage::kValuesOnBox from the values of the box, nothing if the box doesn't
  /// have it.
  static std::optional<std::string> Decode(std::string_view key, Values const & values);

  /// The box of the car has connected and told about itself: its values are read.
  void OnBoxHeard(Esp32Source & box, std::string const & carId);
  /// The phone takes the values another phone has written to the box, and writes its own ones that differ.
  /// \param values all the values of the box or some of them.
  Taken OnValues(Esp32Source & box, Values const & values);
  /// Reads the name again every kReadNameIntervalMs while another phone changes the box. Its other values are
  /// taken at the next connection: they change while the car drives.
  void ReadName(Esp32Source * box);
  /// \param error empty if the box keeps the value.
  void OnWritten(std::string const & key, std::string const & value, std::string const & error);
  /// Writes the values of the phone that differ from the box. Not more often than kSaveIntervalMs unless |now|: the
  /// values are compared that seldom too.
  void Save(Esp32Source * box, bool now);
  /// The car the values of the box are read for, empty before.
  std::string const & GetCarId() const { return m_carId; }

private:
  CarStorage & m_cars;
  Clock const & m_clock;
  std::string m_carId;
  // The values of the box read and written since it has connected, nothing until they are read.
  std::optional<Values> m_boxValues;
  // Another phone keeps the box until the next connection.
  bool m_busy = false;
  std::optional<int64_t> m_savedMs;
  int64_t m_readMs = 0;
};
}  // namespace nogps
