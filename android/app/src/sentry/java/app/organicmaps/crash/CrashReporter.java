package app.organicmaps.crash;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.preference.PreferenceManager;
import app.organicmaps.BuildConfig;
import app.organicmaps.R;
import app.organicmaps.sdk.util.log.Logger;
import io.sentry.Sentry;
import io.sentry.SentryEvent;
import io.sentry.android.core.SentryAndroid;
import io.sentry.android.core.SentryAndroidOptions;
import io.sentry.protocol.SentryException;

/// Crash reports to Sentry. The report holds the stack, the device model, the app version and a few tags: no
/// coordinates, no logs, no IP address. An empty DSN, a debug build or the switch off keep Sentry stopped.
public final class CrashReporter
{
  private static final String TAG = CrashReporter.class.getSimpleName();
  private static final String LOGS_FOLDER_NAME = "logs";

  private CrashReporter() {}

  public static boolean isAvailable()
  {
    return true;
  }

  public static boolean isEnabled(@NonNull Context context)
  {
    return prefs(context).getBoolean(context.getString(R.string.pref_send_crash_reports), true);
  }

  /// Called from Application.onCreate() before the core is created, so an early native crash is caught.
  public static void start(@NonNull Context context)
  {
    if (shouldStart(BuildConfig.SENTRY_DSN, BuildConfig.DEBUG, isEnabled(context)))
      init(context);
  }

  /// The switch of the settings: takes effect at once, and stays on the next launch through the preference.
  public static void setEnabled(@NonNull Context context, boolean enabled)
  {
    prefs(context).edit().putBoolean(context.getString(R.string.pref_send_crash_reports), enabled).apply();
    if (!enabled)
      Sentry.close();
    else if (shouldStart(BuildConfig.SENTRY_DSN, BuildConfig.DEBUG, true) && !Sentry.isEnabled())
      init(context);
  }

  /// Adds a tag to the next report, e.g. the state of the box. A no-op while Sentry is stopped.
  public static void setTag(@NonNull String key, @Nullable String value)
  {
    if (Sentry.isEnabled())
      Sentry.setTag(key, value == null ? "" : value);
  }

  @VisibleForTesting
  static boolean shouldStart(@Nullable String dsn, boolean debug, boolean enabled)
  {
    return enabled && !debug && dsn != null && !dsn.isEmpty();
  }

  /// The listener of the core's failed CHECK/ASSERT: puts the condition and the place on the scope, where the
  /// native handler takes it into the report on disk. No network call from a dying process.
  @VisibleForTesting
  static void reportAssert(@NonNull String source, @NonNull String message)
  {
    if (!Sentry.isEnabled())
      return;
    Sentry.configureScope(scope -> {
      scope.setExtra("assert.message", message);
      scope.setExtra("assert.source", source);
    });
  }

  /// An event that carries a path of the logs folder is not sent: the trip logs hold coordinates.
  @VisibleForTesting
  static boolean holdsLogsPath(@NonNull SentryEvent event)
  {
    if (event.getMessage() != null && inLogs(event.getMessage().getFormatted()))
      return true;
    if (event.getExtras() != null)
    {
      for (final Object value : event.getExtras().values())
        if (value != null && inLogs(value.toString()))
          return true;
    }
    if (event.getExceptions() != null)
    {
      for (final SentryException e : event.getExceptions())
        if (inLogs(e.getValue()))
          return true;
    }
    return false;
  }

  private static boolean inLogs(@Nullable String text)
  {
    return text != null && text.contains("/" + LOGS_FOLDER_NAME + "/");
  }

  @VisibleForTesting
  static void configure(@NonNull SentryAndroidOptions options, @NonNull String dsn, @NonNull String environment,
                        @NonNull String release)
  {
    options.setDsn(dsn);
    options.setEnvironment(environment);
    options.setRelease(release);
    options.setSendDefaultPii(false);
    options.setTracesSampleRate(0.0);
    options.setEnableScopeSync(true);
    options.setAttachScreenshot(false);
    options.setAttachViewHierarchy(false);
    options.setBeforeSend((event, hint) -> holdsLogsPath(event) ? null : event);
  }

  private static void init(@NonNull Context context)
  {
    SentryAndroid.init(context, options -> {
      configure(options, BuildConfig.SENTRY_DSN, BuildConfig.BUILD_TYPE,
                BuildConfig.VERSION_NAME + "+" + BuildConfig.VERSION_CODE);
      // Nothing from logcat and no network breadcrumbs: our own log lines carry coordinates.
      options.setEnableAutoSessionTracking(false);
      options.setEnableUserInteractionBreadcrumbs(false);
      options.setEnableActivityLifecycleBreadcrumbs(false);
      options.setEnableAppComponentBreadcrumbs(false);
      options.setEnableSystemEventBreadcrumbs(false);
      options.setEnableNetworkEventBreadcrumbs(false);
      options.setAnrEnabled(false);
    });
    Sentry.configureScope(scope -> {
      scope.setTag("device.model", Build.MODEL);
      scope.setTag("build", String.valueOf(BuildConfig.VERSION_CODE));
    });
    Logger.setAssertListener(CrashReporter::reportAssert);
  }

  /// The screen name is a tag of the report; set from the activity lifecycle.
  public static void setScreen(@NonNull String name)
  {
    setTag("screen", name);
  }

  private static SharedPreferences prefs(@NonNull Context context)
  {
    return PreferenceManager.getDefaultSharedPreferences(context);
  }
}
