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
import androidx.core.widget.ImageViewCompat;
import app.organicmaps.R;
import app.organicmaps.nogps.SensorsBottomSheet;
import app.organicmaps.sdk.location.LocationUtils;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.ThemeUtils;

/**
 * The middle of the bottom bar: the sensor box, where the position of the car comes from with its accuracy, and GPS.
 * The box and GPS show their state by the shape and the color of the icon, and open their sheets.
 */
public class StatusBar
{
  interface Listener
  {
    void showGpsSheet();

    void showBoxSheet();
  }

  private static final long PULSE_DURATION_MS = 700;

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
    final boolean pulsing;

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
  }

  @NonNull
  private final Button mBox;
  @NonNull
  private final Button mGps;
  @NonNull
  private final View mSource;
  @NonNull
  private final TextView mWord;
  @NonNull
  private final TextView mAccuracy;

  StatusBar(@NonNull View root, @NonNull Listener listener)
  {
    mBox = new Button(root.findViewById(R.id.status_box), root.findViewById(R.id.status_box_icon),
                      root.findViewById(R.id.status_box_badge));
    mGps = new Button(root.findViewById(R.id.status_gps), root.findViewById(R.id.status_gps_icon),
                      root.findViewById(R.id.status_gps_badge));
    mSource = root.findViewById(R.id.status_source);
    mWord = root.findViewById(R.id.status_word);
    mAccuracy = root.findViewById(R.id.status_accuracy);
    mBox.mView.setOnClickListener(v -> listener.showBoxSheet());
    mGps.mView.setOnClickListener(v -> listener.showGpsSheet());
  }

  void update(@NonNull NoGps.Status status)
  {
    final Context context = mSource.getContext();
    final String word = getSourceWord(context, status);
    mWord.setText(word);
    final boolean known = status.getSource() != NoGps.PositionSource.NONE;
    final String accuracy = known ? "±" + formatAccuracy(context, status.accuracyM) : "";
    mAccuracy.setText(accuracy);
    mAccuracy.setVisibility(known ? View.VISIBLE : View.GONE);
    mSource.setContentDescription(word + " " + accuracy);

    mBox.show(getBoxLook(status));
    final String box = context.getString(R.string.nogps_box_title);
    mBox.mView.setContentDescription(
        status.inertialEnabled ? box + ", " + context.getString(SensorsBottomSheet.boxStateText(status)) : box);
    mGps.show(getGpsLook(context, status));
    mGps.mView.setContentDescription(context.getString(R.string.nogps_status_gps) + ", "
                                     + getGpsStateText(context, status));
  }

  @NonNull
  private static String getSourceWord(@NonNull Context context, @NonNull NoGps.Status status)
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

  @NonNull
  public static Look getGpsLook(@NonNull Context context, @NonNull NoGps.Status status)
  {
    if (isGpsOffByOs(context))
      return new Look(R.drawable.ic_nogps_gps_off, R.color.source_sleeping);
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
    // The car doesn't follow GPS: its signal is told by the shape only.
    if (status.gpsDisabled)
      return new Look(look.icon, R.color.source_sleeping, look.badge, look.badgeColor, false);
    return look;
  }

  @NonNull
  public static Look getBoxLook(@NonNull NoGps.Status status)
  {
    if (!status.inertialEnabled)
      return new Look(R.drawable.ic_nogps_box, 0);
    return switch (status.getSourceState())
    {
      case CONNECTED -> new Look(R.drawable.ic_nogps_box, R.color.source_good);
      case UPDATING ->
        new Look(R.drawable.ic_nogps_box, R.color.source_connecting, R.drawable.ic_nogps_badge_update,
                 R.color.source_connecting, true);
      case BOX_SLEEPING, OBD_SLEEPING ->
        new Look(R.drawable.ic_nogps_box, R.color.source_sleeping, R.drawable.ic_nogps_badge_sleep,
                 R.color.source_sleeping, false);
      case NO_CAR_DATA, OBD_DISABLED, OBD_CONNECTING, OBD_ERROR, NO_ADAPTER ->
        new Look(R.drawable.ic_nogps_box, 0, R.drawable.ic_nogps_badge_alert, R.color.source_warning, false);
      case DISCONNECTED, CONNECTING -> getBoxSearchLook(status);
    };
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
    mGps.pulse(false);
    mBox.pulse(false);
  }

  /**
   * A button of the bar showing a state: its icon with a badge.
   */
  private static class Button
  {
    @NonNull
    final View mView;
    @NonNull
    private final ImageView mIcon;
    @NonNull
    private final ImageView mBadge;
    @Nullable
    private ObjectAnimator mPulsing;

    Button(@NonNull View view, @NonNull ImageView icon, @NonNull ImageView badge)
    {
      mView = view;
      mIcon = icon;
      mBadge = badge;
    }

    void show(@NonNull Look look)
    {
      final Context context = mView.getContext();
      mIcon.setImageResource(look.icon);
      ImageViewCompat.setImageTintList(mIcon, ColorStateList.valueOf(look.getColor(context)));
      mBadge.setVisibility(look.badge == 0 ? View.GONE : View.VISIBLE);
      if (look.badge != 0)
      {
        mBadge.setImageResource(look.badge);
        mBadge.setBackgroundTintList(ColorStateList.valueOf(ContextCompat.getColor(context, look.badgeColor)));
        ImageViewCompat.setImageTintList(mBadge, ColorStateList.valueOf(0xFFFFFFFF));
      }
      pulse(look.pulsing);
    }

    void pulse(boolean on)
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
