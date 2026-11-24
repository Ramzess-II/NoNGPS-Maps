package app.organicmaps.util;

import androidx.annotation.Nullable;
import app.organicmaps.sdk.util.Config;

/**
 * Turns ambient light readings into a dark/light decision with a dead band and a hold time.
 *
 * <p>Below {@link #DARK_BELOW_LUX} the target is dark, above {@link #LIGHT_ABOVE_LUX} it is light, between them the
 * current theme stays. A change is returned only after the target stayed on the other side for {@link #HOLD_MS}.
 * The first reading decides at once. Pure logic: time comes in as an argument.</p>
 */
final class LightThemeHysteresis
{
  static final float DARK_BELOW_LUX = 10;
  static final float LIGHT_ABOVE_LUX = 50;
  static final long HOLD_MS = 5000;

  @Nullable
  private Config.UiTheme mCurrent;
  @Nullable
  private Config.UiTheme mPending;
  private long mPendingSinceMs;

  /** Returns the theme to apply now, or null to keep the current one. */
  @Nullable
  Config.UiTheme onReading(float lux, long nowMs)
  {
    if (mCurrent == null)
    {
      mCurrent = lux < (DARK_BELOW_LUX + LIGHT_ABOVE_LUX) / 2 ? Config.UiTheme.DARK : Config.UiTheme.LIGHT;
      return mCurrent;
    }

    final Config.UiTheme target = lux < DARK_BELOW_LUX  ? Config.UiTheme.DARK
                                : lux > LIGHT_ABOVE_LUX ? Config.UiTheme.LIGHT
                                                        : mCurrent;
    if (target == mCurrent)
    {
      mPending = null;
      return null;
    }
    if (mPending != target)
    {
      mPending = target;
      mPendingSinceMs = nowMs;
    }
    return onTick(nowMs);
  }

  /** Called when no reading came but time passed: a steady reading sends no new event. */
  @Nullable
  Config.UiTheme onTick(long nowMs)
  {
    if (mPending == null || nowMs - mPendingSinceMs < HOLD_MS)
      return null;
    mCurrent = mPending;
    mPending = null;
    return mCurrent;
  }

  boolean hasPending()
  {
    return mPending != null;
  }

  long pendingSinceMs()
  {
    return mPendingSinceMs;
  }
}
