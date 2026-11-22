#pragma once

#include "map/nogps/clock.hpp"

#include <cstdint>
#include <string>
#include <string_view>

namespace nogps
{
/// The version of the trip log format, the number in the `LOGFMT` line a platform writes at the top of every file.
/// No tool reads the line yet: reading the number, and refusing a file of another format, is #464.
inline constexpr int kLogFormat = 2;

/// The head of a line the tools read: "TAG ms=<unix ms>", or "TAG name ms=<unix ms>" when the line is a rule, an event
/// or an action. The tag and the name are stable, and the tools skip the head (`nogps_replay.sentence`) and read the
/// free sentence after it as they did before LOGFMT 2, so the sentence of a line a tool counts cannot be reworded;
/// reading the name and the keys instead is #464. The time is UTC, so no tool has to recover a year or reason about
/// midnight.
inline std::string LogHead(Clock const & clock, std::string_view tag, std::string_view name = {})
{
  std::string head(tag);
  if (!name.empty())
  {
    head += ' ';
    head += name;
  }
  head += " ms=" + std::to_string(clock.UnixNowMs());
  return head;
}
}  // namespace nogps
