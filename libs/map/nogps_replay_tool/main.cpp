// Drives a recorded trip of the navigation without GPS again on a desktop, as the Android debug app does: see
// libs/map/nogps_replay/replay.hpp and tools/python/nogps_replay.py.

#include "map/framework.hpp"
#include "map/nogps_replay/replay.hpp"

#include "platform/local_country_file.hpp"
#include "platform/platform.hpp"

#include "base/file_name_utils.hpp"
#include "base/logging.hpp"
#include "base/string_utils.hpp"
#include "base/task_loop.hpp"
#include "base/thread_safe_queue.hpp"

#include "defines.hpp"

#include <cstdint>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

#include <gflags/gflags.h>

DEFINE_string(data_path, "", "The folder of the maps: .mwm files of one version, or folders of them named by it");
DEFINE_string(resources_path, "", "The resources: the data folder of the repository");
DEFINE_string(settings, "",
              "settings.ini of the app the trip was driven with, for what the navigation has learned about the car");

namespace
{
// The GUI thread is the main thread, which runs the tasks posted to it between the parts of the trip.
class GuiThread final : public base::TaskLoop
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

// The maps of the newest version folder in the path, or of the path itself. The world maps of the resources are
// registered already: the ones of the path replace them when they are newer.
void RegisterMaps(Framework & framework, std::string const & path)
{
  std::string dir = path;
  uint64_t version = 0;
  Platform::TFilesWithType subdirs;
  Platform::GetFilesByType(path, Platform::EFileType::Directory, subdirs);
  for (auto const & [name, type] : subdirs)
  {
    uint64_t number = 0;
    if (strings::to_uint64(name, number) && number > version)
    {
      version = number;
      dir = base::JoinPath(path, name);
    }
  }

  Platform::FilesList files;
  Platform::GetFilesByExt(dir, DATA_FILE_EXTENSION, files);
  CHECK(!files.empty(), ("No maps in", dir));
  for (auto name : files)
  {
    base::GetNameWithoutExt(name);
    platform::LocalCountryFile file(dir, platform::CountryFile(name), static_cast<int64_t>(version));
    file.SyncWithDisk();
    auto const result = framework.RegisterMap(file).second;
    if (name != WORLD_FILE_NAME && name != WORLD_COASTS_FILE_NAME)
      CHECK_EQUAL(result, MwmSet::RegResult::Success, (name));
  }
  LOG(LINFO, (files.size(), "maps of", dir));
}
}  // namespace

int main(int argc, char ** argv)
{
  gflags::SetUsageMessage(
      "Drives a trip again.\n"
      "nogps_replay_tool --data_path <maps> --resources_path <data> [--settings settings.ini] <in.txt> <out.txt>\n"
      "<in.txt> is made by tools/python/nogps_replay.py input. The trip log is written to <out.txt>, and\n"
      "<out.txt>.done when the trip is over.");
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  if (argc != 3 || FLAGS_data_path.empty() || FLAGS_resources_path.empty())
  {
    gflags::ShowUsageWithFlagsRestrict(argv[0], "nogps_replay_tool");
    return 1;
  }
  std::string const input = argv[1];
  std::string const output = argv[2];

  // The settings and the files the app writes go to a folder of the run, not to the folder of the maps or of the
  // desktop app.
  std::string const home = base::AddSlashIfNeeded(output + ".home");
  Platform::RmDirRecursively(home);
  CHECK(Platform::MkDirRecursively(home), (home));
  if (!FLAGS_settings.empty())
    std::filesystem::copy_file(FLAGS_settings, base::JoinPath(home, SETTINGS_FILE_NAME));

  auto & platform = GetPlatform();
  platform.SetResourceDir(FLAGS_resources_path);
  platform.SetWritableDirForTests(home);
  platform.SetSettingsDir(home);
  auto guiThread = std::make_unique<GuiThread>();
  auto & gui = *guiThread;
  platform.SetGuiThread(std::move(guiThread));

  {
    // The maps of the run's folder are none but the world maps of the resources, and the routing is set up.
    Framework framework(FrameworkParams(false /* m_enableDiffs */));
    RegisterMaps(framework, FLAGS_data_path);
    nogps::Replay replay(framework.GetRoutingManager(), framework.GetDataSource(), input, output);
    do
      gui.RunPending();
    while (replay.RunChunk());
  }
  Platform::RmDirRecursively(home);
  return 0;
}
