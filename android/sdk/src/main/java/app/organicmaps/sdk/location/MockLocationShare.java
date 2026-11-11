package app.organicmaps.sdk.location;

import android.annotation.SuppressLint;
import android.app.AppOpsManager;
import android.content.Context;
import android.location.Location;
import android.location.LocationManager;
import android.location.provider.ProviderProperties;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.provider.Settings;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.UiThread;
import androidx.core.location.LocationCompat;
import app.organicmaps.sdk.util.Config;
import app.organicmaps.sdk.util.log.Logger;

/**
 * Gives the position of the navigation without GPS to every app on the phone (Google Maps, Waze…) while the core
 * doesn't follow GPS: in the manual mode or with GPS turned off by the user. The app is the mock location app chosen
 * in Developer options for it. While the position is shared, Android hides the real GPS from every app, this one too:
 * the share pauses now and then to hear whether GPS is back, see {@link Schedule}. Called on the UI thread.
 */
public final class MockLocationShare
{
  private static final String TAG = MockLocationShare.class.getSimpleName();
  private static final long TICK_MS = 1000;

  enum State
  {
    OFF,
    SHARING,
    // The share is stopped for a while: GPS reaches the core.
    PROBING,
  }

  /**
   * When to share, without Android.
   */
  static final class Schedule
  {
    static final long kShareProbeIntervalMs = 60_000;
    static final long kShareProbeMs = 10_000;
    // The pause goes on while good GPS comes, so that the rule of GPS back (15 s or 30 s) can end.
    static final long kShareProbeMaxMs = 30_000;
    static final float kShareProbeGoodGpsAccuracyM = 25;

    @NonNull
    private State mState = State.OFF;
    private long mStateSinceMs;

    /**
     * @param gpsHeard the system location runs. It is paused while the box follows the car in the background:
     *                 GPS can't be heard in a pause then.
     */
    @NonNull
    State update(@NonNull NoGps.Status status, boolean gpsHeard, long nowMs)
    {
      final boolean canProbe = gpsHeard && !status.gpsDisabled;
      final long stateMs = nowMs - mStateSinceMs;
      final State state;
      if (!status.manualMode && !status.gpsDisabled)
        state = State.OFF;
      else if (mState == State.SHARING)
        state = canProbe && stateMs >= kShareProbeIntervalMs ? State.PROBING : State.SHARING;
      else if (mState == State.PROBING)
        state = canProbe && (stateMs < kShareProbeMs || (isGoodGps(status) && stateMs < kShareProbeMaxMs))
                  ? State.PROBING
                  : State.SHARING;
      else
        state = State.SHARING;
      if (state != mState)
      {
        mState = state;
        mStateSinceMs = nowMs;
      }
      return state;
    }

    void reset()
    {
      mState = State.OFF;
    }

    /**
     * A mock position is ours while the share runs: it is never read back. A pause doesn't change it, late fixes of
     * the share may still come in it.
     */
    boolean dropsFix(boolean mock)
    {
      return mock && mState != State.OFF;
    }

    private static boolean isGoodGps(@NonNull NoGps.Status status)
    {
      return status.workingGpsAccuracyM >= 0 && status.workingGpsAccuracyM <= kShareProbeGoodGpsAccuracyM;
    }
  }

  @NonNull
  private final Context mContext;
  @NonNull
  private final LocationManager mManager;
  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mTick = this::tick;
  private final Schedule mSchedule = new Schedule();
  // The test providers are added.
  private boolean mShared;
  private boolean mStarted;
  private boolean mGpsHeard = true;
  @Nullable
  private Location mLocation;

  MockLocationShare(@NonNull Context context)
  {
    mContext = context;
    mManager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
  }

  /**
   * The user wants the position shared. It is shared only while {@link #isAllowed} too.
   */
  public static boolean isEnabled()
  {
    return Config.isNoGpsSharePositionEnabled();
  }

  public static void setEnabled(boolean enabled)
  {
    Config.setNoGpsSharePositionEnabled(enabled);
  }

  /**
   * The app is picked as the mock location app in Developer options.
   */
  @SuppressWarnings("deprecation")
  public static boolean isAllowed(@NonNull Context context)
  {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M)
      return "1".equals(Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ALLOW_MOCK_LOCATION));
    final AppOpsManager appOps = (AppOpsManager) context.getSystemService(Context.APP_OPS_SERVICE);
    final String op = AppOpsManager.OPSTR_MOCK_LOCATION;
    final int mode = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                       ? appOps.unsafeCheckOpNoThrow(op, Process.myUid(), context.getPackageName())
                       : appOps.checkOpNoThrow(op, Process.myUid(), context.getPackageName());
    return mode == AppOpsManager.MODE_ALLOWED;
  }

  @UiThread
  void start()
  {
    if (mStarted)
      return;
    mStarted = true;
    // A share of a killed run may be left.
    if (isEnabled() && isAllowed(mContext))
      removeProviders();
    mHandler.post(mTick);
  }

  @UiThread
  void stop()
  {
    mStarted = false;
    mHandler.removeCallbacks(mTick);
    apply(State.OFF);
    mSchedule.reset();
    // The core of the next start may have no position yet.
    mLocation = null;
  }

  @UiThread
  void setGpsHeard(boolean heard)
  {
    mGpsHeard = heard;
  }

  @UiThread
  void onPosition(@NonNull Location location)
  {
    mLocation = location;
    if (mShared)
      send();
  }

  @UiThread
  boolean dropsFix(@NonNull Location location)
  {
    return mSchedule.dropsFix(LocationCompat.isMock(location));
  }

  private void tick()
  {
    if (isEnabled() && isAllowed(mContext))
      apply(mSchedule.update(NoGps.getStatus(), mGpsHeard, SystemClock.elapsedRealtime()));
    else
    {
      apply(State.OFF);
      mSchedule.reset();
    }
    // Other apps take a position that stopped coming for lost: the one of a car stopped is repeated.
    if (mShared)
      send();
    mHandler.postDelayed(mTick, TICK_MS);
  }

  private void apply(@NonNull State state)
  {
    final boolean share = state == State.SHARING;
    if (share == mShared)
      return;
    Logger.i(TAG, "Position for other apps: " + state);
    if (share)
      mShared = addProviders();
    else
    {
      removeProviders();
      mShared = false;
    }
  }

  @NonNull
  private static String[] providers()
  {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
      return new String[] {LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER,
                           LocationManager.FUSED_PROVIDER};
    return new String[] {LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER};
  }

  // The constants of API 31 are inlined, they have the values of Criteria before it.
  @SuppressLint("InlinedApi")
  private boolean addProviders()
  {
    try
    {
      for (String provider : providers())
      {
        mManager.addTestProvider(provider, false /* requiresNetwork */,
                                 LocationManager.GPS_PROVIDER.equals(provider) /* requiresSatellite */,
                                 false /* requiresCell */, false /* hasMonetaryCost */, true /* supportsAltitude */,
                                 true /* supportsSpeed */, true /* supportsBearing */,
                                 ProviderProperties.POWER_USAGE_LOW, ProviderProperties.ACCURACY_FINE);
        mManager.setTestProviderEnabled(provider, true);
      }
      return true;
    }
    catch (SecurityException | IllegalArgumentException e)
    {
      // The app has been unpicked as the mock location app since the check.
      fail(e);
      return false;
    }
  }

  private void removeProviders()
  {
    for (String provider : providers())
    {
      try
      {
        mManager.removeTestProvider(provider);
      }
      catch (SecurityException | IllegalArgumentException e)
      {
        // Not added, or not the mock location app any more: Android has removed the provider then.
      }
    }
  }

  private void send()
  {
    if (mLocation == null)
      return;
    try
    {
      for (String provider : providers())
      {
        final Location location = new Location(mLocation);
        location.setProvider(provider);
        // The core gives the time of the GPS clock, other apps check the age by the phone clock.
        location.setTime(System.currentTimeMillis());
        location.setElapsedRealtimeNanos(SystemClock.elapsedRealtimeNanos());
        mManager.setTestProviderLocation(provider, location);
      }
    }
    catch (SecurityException | IllegalArgumentException e)
    {
      fail(e);
    }
  }

  /**
   * The share is turned off rather than tried again every second.
   */
  private void fail(@NonNull RuntimeException e)
  {
    Logger.w(TAG, "The position is not shared, the share is turned off", e);
    setEnabled(false);
    removeProviders();
    mShared = false;
    mSchedule.reset();
  }
}
