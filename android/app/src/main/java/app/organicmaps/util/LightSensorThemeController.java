package app.organicmaps.util;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.SystemClock;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import app.organicmaps.sdk.util.Config;
import app.organicmaps.sdk.util.concurrency.UiThread;

/**
 * Applies the dark or light theme by the ambient light sensor, see {@link LightThemeHysteresis}.
 *
 * <p>The sensor is registered only while the mode is enabled and the app is in the foreground. Reading it needs no
 * permission. It is {@link ThemeSwitcher} that decides when the mode is enabled.</p>
 */
final class LightSensorThemeController implements SensorEventListener
{
  @NonNull
  private final SensorManager mSensorManager;
  @NonNull
  private final SynchronizedThemeController.ThemeDelegate mThemeDelegate;

  @NonNull
  private LightThemeHysteresis mHysteresis = new LightThemeHysteresis();
  private boolean mEnabled;
  private boolean mForeground;
  private boolean mRegistered;

  LightSensorThemeController(@NonNull Context context, @NonNull SynchronizedThemeController.ThemeDelegate delegate)
  {
    mSensorManager = (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
    mThemeDelegate = delegate;
  }

  static boolean isAvailable(@NonNull Context context)
  {
    final var manager = (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
    return manager != null && manager.getDefaultSensor(Sensor.TYPE_LIGHT) != null;
  }

  @androidx.annotation.UiThread
  void setEnabled(boolean enabled)
  {
    mEnabled = enabled;
    update();
  }

  @androidx.annotation.UiThread
  void setForeground(boolean foreground)
  {
    mForeground = foreground;
    update();
  }

  private void update()
  {
    final boolean shouldRegister = mEnabled && mForeground;
    if (shouldRegister == mRegistered)
      return;

    if (shouldRegister)
    {
      final Sensor sensor = mSensorManager.getDefaultSensor(Sensor.TYPE_LIGHT);
      if (sensor == null)
        return;
      // The first reading after each start applies at once.
      mHysteresis = new LightThemeHysteresis();
      mRegistered = mSensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL);
    }
    else
    {
      mSensorManager.unregisterListener(this);
      UiThread.cancelDelayedTasks(mHoldChecker);
      mRegistered = false;
    }
  }

  // Sensor callbacks come on the main thread: no handler is passed to registerListener.
  @Override
  public void onSensorChanged(@NonNull SensorEvent event)
  {
    apply(mHysteresis.onReading(event.values[0], SystemClock.elapsedRealtime()));
    scheduleHoldCheck();
  }

  @Override
  public void onAccuracyChanged(@NonNull Sensor sensor, int accuracy)
  {}

  private final Runnable mHoldChecker = () ->
  {
    apply(mHysteresis.onTick(SystemClock.elapsedRealtime()));
    scheduleHoldCheck();
  };

  private void scheduleHoldCheck()
  {
    UiThread.cancelDelayedTasks(mHoldChecker);
    if (!mHysteresis.hasPending())
      return;
    final long dueMs = mHysteresis.pendingSinceMs() + LightThemeHysteresis.HOLD_MS;
    UiThread.runLater(mHoldChecker, Math.max(0, dueMs - SystemClock.elapsedRealtime()));
  }

  private void apply(@Nullable Config.UiTheme theme)
  {
    if (theme != null)
      mThemeDelegate.applyTheme(theme);
  }
}
