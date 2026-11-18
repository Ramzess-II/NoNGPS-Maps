#include "app/organicmaps/sdk/Framework.hpp"

#include "app/organicmaps/sdk/core/jni_helper.hpp"

#include "map/nogps_replay/replay.hpp"

#include "platform/platform.hpp"

#include "base/logging.hpp"

#include <memory>

// A recorded trip driven again by a debug build, see libs/map/nogps_replay/replay.hpp.
namespace
{
std::unique_ptr<nogps::Replay> g_replay;

void RunReplay()
{
  if (!g_replay)
    return;
  if (g_replay->RunChunk())
    GetPlatform().RunTask(Platform::Thread::Gui, &RunReplay);
  else
    g_replay.reset();
}
}  // namespace

extern "C"
{
JNIEXPORT void Java_app_organicmaps_sdk_location_NoGps_nativeReplay(JNIEnv * env, jclass, jstring inputPath,
                                                                    jstring outputPath)
{
  if (g_replay)
    return;
  LOG(LINFO, ("A trip is driven again from", jni::ToNativeString(env, inputPath)));
  g_replay = std::make_unique<nogps::Replay>(g_framework->NativeFramework()->GetRoutingManager(),
                                             g_framework->NativeFramework()->GetDataSource(),
                                             jni::ToNativeString(env, inputPath), jni::ToNativeString(env, outputPath));
  GetPlatform().RunTask(Platform::Thread::Gui, &RunReplay);
}
}  // extern "C"
