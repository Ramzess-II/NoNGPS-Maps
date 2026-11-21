#include "testing/testing.hpp"

#include "map/framework.hpp"
#include "map/nogps_replay/replay.hpp"

#include "platform/gui_thread.hpp"
#include "platform/local_country_file.hpp"
#include "platform/platform.hpp"

#include "base/file_name_utils.hpp"
#include "base/scope_guard.hpp"
#include "base/string_utils.hpp"
#include "base/task_loop.hpp"
#include "base/thread_safe_queue.hpp"

#include "defines.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace nogps_replay_tests
{
// The GUI thread is the test thread, which runs the tasks posted to it between the parts of the trip, as
// nogps_replay_tool does.
class TestGuiThread final : public base::TaskLoop
{
public:
  PushResult Push(Task && task) override
  {
    m_tasks.Push(std::move(task));
    return {true, kNoId};
  }
  PushResult Push(Task const & task) override { return Push(Task(task)); }

  void RunPending()
  {
    Task task;
    while (m_tasks.TryPop(task))
      task();
  }

private:
  threads::ThreadSafeQueue<Task> m_tasks;
};

std::string ReadFile(std::string const & path)
{
  std::ifstream in(path);
  std::stringstream text;
  text << in.rdbuf();
  return text.str();
}

std::vector<std::string> TripLines(std::string const & log)
{
  std::vector<std::string> trips;
  std::istringstream in(log);
  for (std::string line; std::getline(in, line);)
    if (line.find(" TRIP ") != std::string::npos)
      trips.push_back(line);
  return trips;
}

// Drives the input on the test map and returns the trip log of the drive.
std::string Drive(std::string const & input)
{
  auto & platform = GetPlatform();
  std::string const inPath = base::JoinPath(platform.WritableDir(), "nogps-replay-test-in.txt");
  std::string const outPath = base::JoinPath(platform.WritableDir(), "nogps-replay-test-out.txt");
  std::string const donePath = outPath + ".done";
  SCOPE_GUARD(removeFiles, [&]
  {
    std::remove(inPath.c_str());
    std::remove(outPath.c_str());
    std::remove(donePath.c_str());
  });
  std::ofstream(inPath) << input;
  // The .done file of an earlier drive is not taken for this one.
  std::ofstream(donePath) << "stale\n";

  auto guiThread = std::make_unique<TestGuiThread>();
  auto & gui = *guiThread;
  platform.SetGuiThread(std::move(guiThread));
  SCOPE_GUARD(restoreGuiThread, [&platform] { platform.SetGuiThread(std::make_unique<platform::GuiThread>()); });

  Framework framework(FrameworkParams(false /* m_enableDiffs */));
  // The car model of the roads is taken by the country of the map: the test map is given the name of its country.
  std::string const country = "Belarus_Minsk Region";
  std::string const mapPath = base::JoinPath(platform.WritableDir(), country + DATA_FILE_EXTENSION);
  std::filesystem::copy_file(base::JoinPath(platform.ResourcesDir(), "minsk-pass" DATA_FILE_EXTENSION), mapPath,
                             std::filesystem::copy_options::overwrite_existing);
  SCOPE_GUARD(removeMap, [&] { std::remove(mapPath.c_str()); });
  platform::LocalCountryFile map(platform.WritableDir(), platform::CountryFile(country), 0 /* version */);
  map.SyncWithDisk();
  TEST_EQUAL(framework.RegisterMap(map).second, MwmSet::RegResult::Success, ());
  {
    nogps::Replay replay(framework.GetRoutingManager(), framework.GetDataSource(), inPath, outPath);
    TEST(!Platform::IsFileExistsByFullPath(donePath), ());
    do
      gui.RunPending();
    while (replay.RunChunk());
  }

  // Every record with a time is counted, the date is not.
  size_t records = 0;
  std::istringstream in(input);
  for (std::string line; std::getline(in, line);)
    records += !line.empty() && line[0] != 'D';
  TEST_EQUAL(ReadFile(donePath), std::to_string(records) + " records\n", ());
  return ReadFile(outPath);
}

// Box records of a car standing, every 200 ms from fromMs to toMs.
std::string Standing(int64_t fromMs, int64_t toMs)
{
  std::string box;
  for (int64_t ms = fromMs + 200; ms <= toMs; ms += 200)
    box += "B " + std::to_string(ms) + " 200 0 0 17 -\n";
  return box;
}

UNIT_TEST(NoGps_Replay_DrivesTripLog)
{
  // The application started anew has kept the car on a street of Minsk, a minute ago, without GPS.
  std::string const input =
      "D 11-02\n"
      "S 36000000 2\n"
      "C 36000000 53.9040184 27.5567595 90.0 1 60000\n"
      "S 36000000 1\n"
      "L 36000000 CONNECTED\n"
      "J 36001000\n" +
      Standing(36001000, 36006000) + "S 36006000 0\n";
  std::string const log = Drive(input);
  auto const trips = TripLines(log);
  TEST_GREATER_OR_EQUAL(trips.size(), 4, (log));
  for (auto const & trip : trips)
  {
    // The stamps are of the date and the time of the trip.
    TEST(trip.starts_with("11-02 10:00:0"), (trip));
    TEST(trip.find(" (replay) I/OMcore: ") != std::string::npos, (trip));
  }
  // The car is shown where it was kept, and the box drives it.
  TEST(log.find("The car is where it was left = 53.9040184,27.5567595,90.0,1,") != std::string::npos, (log));
  TEST(trips.back().find(" pos=53.904018,27.5567") != std::string::npos, (trips.back()));
  TEST(trips.back().find(" src=INERTIAL ") != std::string::npos, (trips.back()));
  TEST(trips.back().find(" link=BLE/CONNECTED ") != std::string::npos, (trips.back()));
}

UNIT_TEST(NoGps_Replay_DrivesJolt)
{
  // The car drives on from where it was kept and hits a pothole: the jolt of the part is the one of the box lines.
  std::string input =
      "D 11-02\n"
      "S 36000000 2\n"
      "C 36000000 53.9040184 27.5567595 90.0 1 60000\n"
      "S 36000000 1\n"
      "L 36000000 CONNECTED\n"
      "J 36001000\n" +
      Standing(36001000, 36002000);
  for (int64_t ms = 36002200; ms <= 36005000; ms += 200)
    input += "B " + std::to_string(ms) + " 200 0 36 17 0 0 9810 " + (ms == 36003000 ? "12000" : "500") + "\n";
  input += "S 36005000 0\n";
  auto const log = Drive(input);
  TEST(log.find("POTHOLE 31 12.0 53.904") != std::string::npos, (log));
}

UNIT_TEST(NoGps_Replay_BoxOfTrip)
{
  // The box of the trip is told to the navigation: its info line is accepted.
  std::string const input =
      "D 11-02\n"
      "S 36000000 2\n"
      "C 36000000 53.9040184 27.5567595 90.0 1 60000\n"
      "S 36000000 1\n"
      "L 36000000 CONNECTED\n"
      "I 36000000 42FD\n"
      "J 36001000\n" +
      Standing(36001000, 36003000) + "S 36003000 0\n";
  auto const log = Drive(input);
  TEST(log.find("I/OMcore: nogps/esp32_source.cpp:") != std::string::npos, (log));
  TEST(log.find("Box 42FD firmware") != std::string::npos, (log));
}

UNIT_TEST(NoGps_Replay_KeptCarOfDriveWins)
{
  // The drive keeps the car it has shown when the application is started anew: the car the application kept on
  // the trip is not taken.
  std::string const input =
      "D 11-02\n"
      "S 36000000 2\n"
      "C 36000000 53.9040184 27.5567595 90.0 1 60000\n"
      "S 36000000 1\n"
      "L 36000000 CONNECTED\n" +
      Standing(36000000, 36003000) +
      "S 36003000 0\n"
      "S 36010000 2\n"
      "C 36010000 53.9005419 27.5416291 90.0 1 1000\n"
      "S 36010000 1\n"
      "L 36010000 CONNECTED\n" +
      Standing(36010000, 36013000) + "S 36013000 0\n";
  size_t second = 0;
  for (auto const & trip : TripLines(Drive(input)))
  {
    // The first line of a start is written before the car is shown.
    if (!trip.starts_with("11-02 10:00:1") || trip.find(" pos=") == std::string::npos)
      continue;
    ++second;
    TEST(trip.find(" pos=53.904018,27.5567") != std::string::npos, (trip));
  }
  TEST_GREATER_OR_EQUAL(second, 3, ());
}
}  // namespace nogps_replay_tests
