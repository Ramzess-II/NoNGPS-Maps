#include "map/nogps_replay_tool/fixed_locale.hpp"

#import <Foundation/Foundation.h>

namespace nogps
{
void UseFixedLocale()
{
  // NSLocale reads the locale of the Mac from the user defaults, which the argument domain overrides for this process
  // only.
  NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary * args = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy];
  if (!args)
    args = [NSMutableDictionary dictionary];
  args[@"AppleLocale"] = @"en_US";
  [defaults setVolatileDomain:args forName:NSArgumentDomain];
}
}  // namespace nogps
