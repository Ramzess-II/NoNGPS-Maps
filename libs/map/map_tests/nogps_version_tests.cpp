#include "testing/testing.hpp"

#include "map/nogps/version.hpp"

#include <regex>
#include <string>

namespace nogps_version_tests
{
UNIT_TEST(NoGps_AddonVersion)
{
  std::string const version(nogps::kAddonVersion);
  TEST(std::regex_match(version, std::regex(R"((0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*))")), (version));
}
}  // namespace nogps_version_tests
