#include "map/nogps_replay_tool/fixed_locale.hpp"

namespace nogps
{
// platform::GetCurrentLocale() of the other platforms reads the environment: set LANG=en_US.UTF-8 for the tool.
void UseFixedLocale() {}
}  // namespace nogps
