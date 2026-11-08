#pragma once

#include <string_view>

namespace nogps
{
/// The version of the NonGPS add-on, MAJOR.MINOR.PATCH, shown in About and in the trip log of both apps.
/// Every PR into master raises it: PATCH for a fix, MINOR for new behavior, MAJOR when we decide.
constexpr std::string_view kAddonVersion = "1.3.0";
}  // namespace nogps
