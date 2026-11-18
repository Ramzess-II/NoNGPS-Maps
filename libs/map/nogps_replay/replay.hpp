#pragma once

#include <memory>
#include <string>

class DataSource;
class RoutingManager;

namespace nogps
{
// A recorded trip driven again, by the Android debug app and by nogps_replay_tool: everything the navigation without
// GPS was given on a trip, taken from its trip log, goes through a navigation of its own on the roads of the map, as
// fast as the machine counts, and what it logs is written to a file as a trip log. It tells what a new rule does on the
// trips already driven, where GPS was seen, before the user drives with it. The route the user has asked for on the
// trip is built again by a router of its own and lives as the route of the application does, see ReplayRoute.
//
// The input is made by tools/python/nogps_replay.py, a record a line, the time is milliseconds of the day:
//   D <MM-DD>                     the date for the stamps of the output
//   S <ms> <0|1|2>                the navigation is stopped, started, or the application is started anew
//   C <ms> <lat> <lon> <bearing or -> <manual 0|1> <age ms>
//                                 where the application kept the car when it was started anew: the next start shows
//                                 the car there, unless the trip driven again has kept a car of its own by then
//   J <ms>                        the time jumps on: nothing has happened meanwhile
//   L <ms> <state>                Bluetooth of the box, as DebugPrint(BleState) tells it
//   B <ms> <duration ms> <yaw mdeg> <km/h> <flags hex> <h1> <h2> <up>
//                                 a part of a second of the box that ends at the time: its rotation, the speed of
//                                 the car, the acceleration in mm/s2 or "-" without it
//   G <ms> <lat> <lon> <accuracy m> <m/s or -> <bearing or -> <its accuracy or ->     a position of GPS
//   X <ms> <0|1>   A <ms> <0|1>   the user turns GPS off or on, the manual mode on or off
//   T <ms> <lat> <lon>            the user taps the map
//   H <ms> <bearing>              the mark looked this way after that tap: it is turned if it doesn't
//   R <ms>   P <ms> <0|1>   M <ms> <meters>
//                                 the reverse button, the pause button of the trips before October 16 (there is no
//                                 pause since then), the mark moved along the road
//   W <ms>                        the button showing the car on another road it may be on
//   N <ms> <lat> <lon> <lat> <lon> ...
//                                 the user asks for a route through the points, the first one is where the car is
//   F <ms> <0|1>                  the user closes the route, or starts to follow it
//
// The output is written to <output>, and <output>.done when the trip is over. The log lines of the thread that runs
// RunChunk() go to the output while it runs.
class Replay
{
public:
  Replay(RoutingManager & routing, DataSource const & dataSource, std::string const & inputPath,
         std::string const & outputPath);
  ~Replay();

  // Drives on for a part of a second. Call it on the GUI thread again and again, letting the tasks posted to that
  // thread run between the calls, until it returns false: the trip is over.
  bool RunChunk();

  class Impl;

private:
  std::unique_ptr<Impl> m_impl;
};
}  // namespace nogps
