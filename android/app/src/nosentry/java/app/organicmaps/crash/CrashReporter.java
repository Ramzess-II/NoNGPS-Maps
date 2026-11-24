package app.organicmaps.crash;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/// The F-Droid flavor links no Sentry: it would get a Tracking anti-feature.
public final class CrashReporter
{
  private CrashReporter() {}

  public static boolean isAvailable()
  {
    return false;
  }

  public static boolean isEnabled(@NonNull Context context)
  {
    return false;
  }

  public static void start(@NonNull Context context) {}

  public static void setEnabled(@NonNull Context context, boolean enabled) {}

  public static void setTag(@NonNull String key, @Nullable String value) {}

  public static void setScreen(@NonNull String name) {}
}
