package app.organicmaps.maplayer;

import android.animation.ObjectAnimator;
import android.content.Context;
import android.content.res.ColorStateList;
import android.view.View;
import android.widget.ImageView;
import android.widget.TextView;
import androidx.annotation.ColorInt;
import androidx.annotation.ColorRes;
import androidx.annotation.DrawableRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.core.graphics.ColorUtils;
import androidx.core.widget.ImageViewCompat;
import app.organicmaps.R;
import app.organicmaps.nogps.SensorsBottomSheet;
import app.organicmaps.sdk.location.LocationUtils;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.ThemeUtils;

/**
 * The middle of the bottom bar: one button with where the position of the car comes from and its accuracy. It shows the
 * state of what moves the mark by the shape and the color of the icon and the tint of the background, and opens the
 * Box sheet.
 */
public class StatusBar
{
  interface Listener
  {
    void showBoxSheet();
  }

  private static final long PULSE_DURATION_MS = 700;
  // The tint of the button background: the color of the look at this alpha, 16 % in the light theme and 24 % in the
  // dark.
  private static final int TINT_ALPHA_LIGHT = 0x29;
  private static final int TINT_ALPHA_DARK = 0x3D;

  /**
   * How a state is drawn: the icon, its color, a badge and if it pulses while something is in progress.
   */
  public static final class Look
  {
    @DrawableRes
    public final int icon;
    // 0 for the color of the other icons.
    @ColorRes
    public final int color;
    // 0 for none.
    @DrawableRes
    final int badge;
    @ColorRes
    final int badgeColor;
    public final boolean pulsing;

    Look(@DrawableRes int icon, @ColorRes int color, @DrawableRes int badge, @ColorRes int badgeColor, boolean pulsing)
    {
      this.icon = icon;
      this.color = color;
      this.badge = badge;
      this.badgeColor = badgeColor;
      this.pulsing = pulsing;
    }

    public Look(@DrawableRes int icon, @ColorRes int color)
    {
      this(icon, color, 0, 0, false);
    }

    @ColorInt
    public int getColor(@NonNull Context context)
    {
      return color == 0 ? ThemeUtils.getColor(context, R.attr.iconTint) : ContextCompat.getColor(context, color);
    }

    @ColorInt
    public int getTint(@NonNull Context context)
    {
      return ColorUtils.setAlphaComponent(getColor(context),
                                          ThemeUtils.isDarkTheme(context) ? TINT_ALPHA_DARK : TINT_ALPHA_LIGHT);
    }

    @NonNull
    Look withBadge(@DrawableRes int badge, @ColorRes int badgeColor)
    {
      return new Look(icon, color, badge, badgeColor, pulsing);
    }
  }

  @NonNull
  private final Button mNav;
  @NonNull
  private final TextView mWord;
  @NonNull
  private final TextView mAccuracy;

  StatusBar(@NonNull View root, @NonNull Listener listener)
  {
    mNav = new Button(root, root.findViewById(R.id.status_nav_icon), root.findViewById(R.id.status_nav_badge));
    mWord = root.findViewById(R.id.status_word);
    mAccuracy = root.findViewById(R.id.status_accuracy);
    root.setOnClickListener(v -> listener.showBoxSheet());
  }

  void update(@NonNull NoGps.Status status)
  {
    final Context context = mNav.mView.getContext();
    mWord.setText(getSourceWord(context, status));
    final String accuracy = getAccuracyText(context, status);
    mAccuracy.setText(accuracy);
    mAccuracy.setVisibility(accuracy != null ? View.VISIBLE : View.GONE);
    mNav.show(getBarLook(context, status));
    mNav.mView.setContentDescription(getBarDescription(context, status));
  }

  /**
   * What the button tells to a screen reader: what moves the mark, its state and the accuracy.
   */
  @NonNull
  public static String getBarDescription(@NonNull Context context, @NonNull NoGps.Status status)
  {
    final boolean box = navShowsBox(status.getSource(), status.inertialEnabled);
    final String title = context.getString(box ? R.string.nogps_box_title : R.string.nogps_status_gps);
    final String state = box ? status.inertialEnabled ? SensorsBottomSheet.boxStateText(context, status) : ""
                             : getGpsStateText(context, status);
    final String accuracy = getAccuracyText(context, status);
    final StringBuilder text = new StringBuilder(title);
    if (!state.isEmpty())
      text.append(", ").append(state);
    if (accuracy != null)
      text.append(", ").append(accuracy);
    return text.toString();
  }

  @NonNull
  public static String getSourceWord(@NonNull Context context, @NonNull NoGps.Status status)
  {
    return switch (status.getSource())
    {
      case GPS -> context.getString(R.string.nogps_status_gps);
      case NETWORK -> context.getString(R.string.nogps_bar_network);
      case MANUAL -> context.getString(R.string.nogps_bar_manual);
      case INERTIAL -> context.getString(R.string.nogps_bar_inertial);
      case NONE -> "—";
    };
  }

  /**
   * The accuracy of the position, null without a position.
   */
  @Nullable
  public static String getAccuracyText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    if (status.getSource() == NoGps.PositionSource.NONE)
      return null;
    return "±" + formatAccuracy(context, status.accuracyM);
  }

  /**
   * One button for where the position comes from: the box when the car follows it, or when the mark is set by hand
   * with a box set up, else GPS.
   */
  public static boolean navShowsBox(@NonNull NoGps.PositionSource source, boolean inertialEnabled)
  {
    return switch (source)
    {
      case INERTIAL -> true;
      case MANUAL -> inertialEnabled;
      case GPS, NETWORK, NONE -> false;
    };
  }

  /**
   * The look of the button: of what moves the mark. One badge on it: the look's own, else "+" without a box, else a dot
   * in the color of the other source when it is orange or red.
   */
  @NonNull
  public static Look getBarLook(@NonNull NoGps.Status status)
  {
    return getBarLook(status, getGpsLook(status));
  }

  @NonNull
  public static Look getBarLook(@NonNull Context context, @NonNull NoGps.Status status)
  {
    return getBarLook(status, getGpsLook(context, status));
  }

  @NonNull
  private static Look getBarLook(@NonNull NoGps.Status status, @NonNull Look gps)
  {
    final boolean box = navShowsBox(status.getSource(), status.inertialEnabled);
    final Look own = box ? getBoxLook(status) : gps;
    if (own.badge != 0)
      return own;
    if (!status.inertialEnabled)
      return own.withBadge(R.drawable.ic_nogps_badge_add, R.color.source_connecting);
    final Look other = box ? gps : getBoxLook(status);
    if (other.color == R.color.source_warning || other.color == R.color.source_bad)
      return own.withBadge(R.drawable.ic_nogps_badge_dot, other.color);
    return own;
  }

  @NonNull
  public static Look getGpsLook(@NonNull Context context, @NonNull NoGps.Status status)
  {
    if (isGpsOffByOs(context))
      return new Look(R.drawable.ic_nogps_gps_off, R.color.source_sleeping);
    return getGpsLook(status);
  }

  /**
   * GPS allowed by the system: its state from the core.
   */
  @NonNull
  static Look getGpsLook(@NonNull NoGps.Status status)
  {
    final Look look = switch (status.getGpsState())
    {
      case GOOD -> new Look(R.drawable.ic_nogps_gps, R.color.source_good);
      case CHECKING -> new Look(R.drawable.ic_nogps_gps, R.color.source_connecting, 0, 0, true);
      case COARSE -> new Look(R.drawable.ic_nogps_gps, R.color.source_warning);
      case SPOOFED ->
        new Look(R.drawable.ic_nogps_gps, R.color.source_warning, R.drawable.ic_nogps_badge_alert,
                 R.color.source_warning, false);
      case NONE -> new Look(R.drawable.ic_nogps_gps_off, R.color.source_bad);
    };
    // The car doesn't follow GPS: the badge tells it, the color still tells the signal.
    if (status.gpsDisabled && look.badge == 0)
      return new Look(look.icon, look.color, R.drawable.ic_nogps_badge_pause, R.color.source_sleeping, look.pulsing);
    return look;
  }

  @NonNull
  public static Look getBoxLook(@NonNull NoGps.Status status)
  {
    // No box: the button calls to set one up or to buy it.
    if (!status.inertialEnabled)
      return new Look(R.drawable.ic_nogps_box, 0, R.drawable.ic_nogps_badge_add, R.color.source_connecting, false);
    return switch (status.getSourceState())
    {
      case CONNECTED -> new Look(R.drawable.ic_nogps_box, R.color.source_inertial);
      case UPDATING ->
        new Look(R.drawable.ic_nogps_box, R.color.source_connecting, R.drawable.ic_nogps_badge_update,
                 R.color.source_connecting, true);
      case BOX_SLEEPING -> getBoxSleepingLook(status);
      case OBD_SLEEPING ->
        new Look(R.drawable.ic_nogps_box, R.color.source_sleeping, R.drawable.ic_nogps_badge_sleep,
                 R.color.source_sleeping, false);
      case NO_CAR_DATA, OBD_DISABLED, OBD_CONNECTING, OBD_ERROR, NO_ADAPTER ->
        new Look(R.drawable.ic_nogps_box, R.color.source_warning, R.drawable.ic_nogps_badge_alert,
                 R.color.source_warning, false);
      case DISCONNECTED, CONNECTING -> getBoxSearchLook(status);
    };
  }

  /**
   * The box is away or its radio is off: the phone keeps looking for it.
   */
  @NonNull
  private static Look getBoxSleepingLook(@NonNull NoGps.Status status)
  {
    final Look look = getBoxSearchLook(status);
    if (!look.pulsing)
      return look;
    return new Look(look.icon, look.color, R.drawable.ic_nogps_badge_sleep, R.color.source_sleeping, true);
  }

  /**
   * The box is not heard yet: the phone looks for it by Bluetooth, then waits for its data.
   */
  @NonNull
  private static Look getBoxSearchLook(@NonNull NoGps.Status status)
  {
    // The ELM327 adapter of the phone is reached without Bluetooth LE.
    if (!status.esp32Source)
      return new Look(R.drawable.ic_nogps_bluetooth, R.color.source_connecting, 0, 0, true);
    return switch (status.getBleState())
    {
      case CONNECTED -> new Look(R.drawable.ic_nogps_box, R.color.source_connecting, 0, 0, true);
      case OFF, NO_PERMISSION, DISABLED -> new Look(R.drawable.ic_nogps_bluetooth_off, R.color.source_sleeping);
      default -> new Look(R.drawable.ic_nogps_bluetooth, R.color.source_connecting, 0, 0, true);
    };
  }

  @NonNull
  public static String getGpsStateText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    if (isGpsOffByOs(context))
      return context.getString(R.string.nogps_status_gps_off);
    return context.getString(switch (status.getGpsState())
    {
      case GOOD -> R.string.nogps_gps_state_good;
      case CHECKING -> R.string.nogps_gps_state_checking;
      case COARSE -> R.string.nogps_gps_state_coarse;
      case SPOOFED -> R.string.nogps_gps_state_spoofed;
      case NONE -> R.string.nogps_gps_state_none;
    });
  }

  /**
   * Why GPS is in its state, and if the car follows it.
   */
  @Nullable
  public static String getGpsWhyText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    if (isGpsOffByOs(context))
      return null;
    if (status.gpsDisabled)
      return context.getString(R.string.nogps_gps_why_ignored);
    return context.getString(switch (status.getGpsState())
    {
      case GOOD -> R.string.nogps_gps_why_used;
      // Good positions are checked in the manual mode, the satellites are searched after the start.
      case CHECKING -> status.manualMode ? R.string.nogps_gps_why_checking : R.string.nogps_gps_why_searching;
      case COARSE ->
        status.workingNetworkAccuracyM >= 0 && status.workingGpsAccuracyM < 0 ? R.string.nogps_gps_why_network
                                                                              : R.string.nogps_gps_why_coarse;
      case SPOOFED -> R.string.nogps_gps_why_spoofed;
      case NONE -> R.string.nogps_gps_why_none;
    });
  }

  @NonNull
  public static String formatAccuracy(@NonNull Context context, float meters)
  {
    if (meters < 1000)
      return context.getString(R.string.nogps_meters, Math.round(meters));
    return context.getString(R.string.nogps_kilometers, meters / 1000);
  }

  public static boolean isGpsOffByOs(@NonNull Context context)
  {
    return !LocationUtils.checkFineLocationPermission(context) || !LocationUtils.areLocationServicesTurnedOn(context);
  }

  /**
   * Stops the pulsing in the background, the next update starts it again.
   */
  void stop()
  {
    mNav.pulse(false);
  }

  /**
   * A button showing a state: its icon with a badge on a tinted background.
   */
  public static class Button
  {
    @NonNull
    final View mView;
    @NonNull
    private final ImageView mIcon;
    @NonNull
    private final ImageView mBadge;
    @Nullable
    private ObjectAnimator mPulsing;

    public Button(@NonNull View view, @NonNull ImageView icon, @NonNull ImageView badge)
    {
      mView = view;
      mIcon = icon;
      mBadge = badge;
    }

    public void show(@NonNull Look look)
    {
      show(look, look.pulsing);
    }

    /**
     * @param pulse whether the icon pulses; a sheet may show the progress in another way.
     */
    public void show(@NonNull Look look, boolean pulse)
    {
      final Context context = mView.getContext();
      mView.setBackgroundTintList(ColorStateList.valueOf(look.getTint(context)));
      mIcon.setImageResource(look.icon);
      ImageViewCompat.setImageTintList(mIcon, ColorStateList.valueOf(look.getColor(context)));
      mBadge.setVisibility(look.badge == 0 ? View.GONE : View.VISIBLE);
      if (look.badge != 0)
      {
        mBadge.setImageResource(look.badge);
        mBadge.setBackgroundTintList(ColorStateList.valueOf(ContextCompat.getColor(context, look.badgeColor)));
        ImageViewCompat.setImageTintList(mBadge, ColorStateList.valueOf(0xFFFFFFFF));
      }
      pulse(pulse);
    }

    public void pulse(boolean on)
    {
      if (on == (mPulsing != null))
        return;
      if (mPulsing != null)
      {
        mPulsing.cancel();
        mPulsing = null;
        mIcon.setAlpha(1f);
        return;
      }
      mPulsing = ObjectAnimator.ofFloat(mIcon, View.ALPHA, 1f, 0.3f);
      mPulsing.setDuration(PULSE_DURATION_MS);
      mPulsing.setRepeatCount(ObjectAnimator.INFINITE);
      mPulsing.setRepeatMode(ObjectAnimator.REVERSE);
      mPulsing.start();
    }
  }
}
