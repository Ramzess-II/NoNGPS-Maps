#pragma once

namespace nogps
{
// Formats numbers of the trip log as the phone of the trips does (en_US), not as the machine's locale does: two
// replays then differ only by what the navigation did. Call it before the first number is formatted.
void UseFixedLocale();
}  // namespace nogps
