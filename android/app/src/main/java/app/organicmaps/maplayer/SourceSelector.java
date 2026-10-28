package app.organicmaps.maplayer;

import android.animation.ObjectAnimator;
import android.content.Context;
import android.content.res.ColorStateList;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.ColorRes;
import androidx.annotation.DrawableRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.core.widget.ImageViewCompat;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.ThemeUtils;

/**
 * Chooses where the position of the car comes from: GPS while it is good with the sensor box taking over by itself,
 * or the box alone with GPS ignored. Each segment shows how its source works now, tapping the chosen one tells more.
 */
class SourceSelector
{
  interface Listener
  {
    /**
     * Shows the sensors screen.
     * @param backToGps GPS comes back if the box is still not connected when the user closes the screen.
     */
    void showSensors(boolean backToGps);

    /**
     * The user has chosen a source: what depends on it is updated at once.
     */
    void onSourceChosen();
  }

  private static final long BLINK_DURATION_MS = 700;
  private static final float DISABLED_ALPHA = 0.4f;

  @NonNull
  private final View mThumb;
  @NonNull
  private final Segment mGps;
  @NonNull
  private final Segment mBox;
  @NonNull
  private final Listener mListener;
  @Nullable
  private NoGps.Status mStatus;

  SourceSelector(@NonNull View root, @NonNull Listener listener)
  {
    mListener = listener;
    mThumb = root.findViewById(R.id.source_thumb);
    mGps = new Segment(root.findViewById(R.id.source_gps), root.findViewById(R.id.source_gps_icon),
                       root.findViewById(R.id.source_gps_badge), root.findViewById(R.id.source_gps_label));
    mBox = new Segment(root.findViewById(R.id.source_box), root.findViewById(R.id.source_box_icon),
                       root.findViewById(R.id.source_box_badge), root.findViewById(R.id.source_box_label));
    mGps.mView.setOnClickListener(v -> onGpsTapped());
    mBox.mView.setOnClickListener(v -> onBoxTapped());
    // The thumb takes the place of the chosen segment once the segments are measured.
    root.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> placeThumb(false));
  }

  void update(@NonNull NoGps.Status status)
  {
    final boolean moved = mStatus != null && mStatus.gpsDisabled != status.gpsDisabled;
    mStatus = status;
    mGps.setChosen(!status.gpsDisabled);
    mBox.setChosen(status.gpsDisabled);
    updateGps(status, mGps.mView.getContext());
    updateBox(status);
    placeThumb(moved);
  }

  private void placeThumb(boolean animated)
  {
    final View chosen = mStatus != null && mStatus.gpsDisabled ? mBox.mView : mGps.mView;
    if (chosen.getWidth() == 0)
      return;
    final FrameLayout.LayoutParams params = (FrameLayout.LayoutParams) mThumb.getLayoutParams();
    // From the physical left, as getLeft() is, also in a right-to-left layout.
    if (params.width != chosen.getWidth() || params.gravity != Gravity.LEFT)
    {
      params.width = chosen.getWidth();
      params.gravity = Gravity.LEFT;
      mThumb.setLayoutParams(params);
    }
    if (animated)
      mThumb.animate().translationX(chosen.getLeft()).start();
    else
      mThumb.setTranslationX(chosen.getLeft());
  }

  private void updateGps(@NonNull NoGps.Status status, @NonNull Context context)
  {
    mGps.mView.setContentDescription(context.getString(R.string.nogps_status_gps) + ", " + getGpsText(status, context));
    // Not blinking: GPS is not connected to, it is there or not.
    if (status.gpsSpoofed)
      mGps.show(R.drawable.ic_nogps_gps, R.color.source_warning, R.drawable.ic_nogps_badge_alert,
                R.color.source_warning, false);
    // Also while it is ignored or not trusted yet.
    else if (status.workingGpsAccuracyM >= 0)
      mGps.show(R.drawable.ic_nogps_gps, R.color.source_good, 0, 0, false);
    else
      mGps.show(R.drawable.ic_nogps_gps_off, R.color.source_bad, 0, 0, false);
  }

  private void updateBox(@NonNull NoGps.Status status)
  {
    final Context context = mBox.mView.getContext();
    mBox.mView.setEnabled(status.inertialEnabled);
    mBox.mView.setAlpha(status.inertialEnabled ? 1f : DISABLED_ALPHA);
    mBox.mView.setContentDescription(context.getString(R.string.nogps_source_box));
    if (!status.inertialEnabled)
    {
      mBox.show(R.drawable.ic_nogps_box, 0, 0, 0, false);
      return;
    }
    switch (status.getSourceState())
    {
    case CONNECTED -> mBox.show(R.drawable.ic_nogps_box, R.color.source_good, 0, 0, false);
    case UPDATING ->
      mBox.show(R.drawable.ic_nogps_box, 0, R.drawable.ic_nogps_badge_update, R.color.source_connecting, false);
    case BOX_SLEEPING, OBD_SLEEPING ->
      mBox.show(R.drawable.ic_nogps_box, R.color.source_sleeping, R.drawable.ic_nogps_badge_sleep,
                R.color.source_sleeping, false);
    case NO_CAR_DATA, OBD_DISABLED, OBD_CONNECTING, OBD_ERROR, NO_ADAPTER ->
      mBox.show(R.drawable.ic_nogps_box, 0, R.drawable.ic_nogps_badge_alert, R.color.source_warning, false);
    default -> showBoxSearch(status);
    }
  }

  /**
   * The box is not heard yet: first the phone looks for it by Bluetooth (red), then waits for its data (blue).
   */
  private void showBoxSearch(@NonNull NoGps.Status status)
  {
    // The ELM327 adapter of the phone is reached without Bluetooth LE.
    if (!status.esp32Source)
    {
      mBox.show(R.drawable.ic_nogps_bluetooth, R.color.source_bad, 0, 0, true);
      return;
    }
    switch (status.getBleState())
    {
    case CONNECTED -> mBox.show(R.drawable.ic_nogps_box, R.color.source_connecting, 0, 0, true);
    case OFF, NO_PERMISSION, DISABLED ->
      mBox.show(R.drawable.ic_nogps_bluetooth_off, R.color.source_sleeping, 0, 0, false);
    default -> mBox.show(R.drawable.ic_nogps_bluetooth, R.color.source_bad, 0, 0, true);
    }
  }

  @NonNull
  private static String getGpsText(@NonNull NoGps.Status status, @NonNull Context context)
  {
    if (status.gpsSpoofed)
      return context.getString(R.string.nogps_status_gps_spoofed);
    if (status.workingGpsAccuracyM < 0)
      return context.getString(R.string.nogps_status_no_gps);
    return context.getString(R.string.nogps_status_gps) + " · ±" + formatAccuracy(context, status.workingGpsAccuracyM);
  }

  @NonNull
  static String formatAccuracy(@NonNull Context context, float meters)
  {
    if (meters < 1000)
      return context.getString(R.string.nogps_meters, Math.round(meters));
    return context.getString(R.string.nogps_kilometers, meters / 1000);
  }

  private void onGpsTapped()
  {
    if (mStatus == null)
      return;
    if (!mStatus.gpsDisabled)
      Toast.makeText(mGps.mView.getContext(), getGpsText(mStatus, mGps.mView.getContext()), Toast.LENGTH_SHORT).show();
    else
      choose(false /* gpsDisabled */);
  }

  private void onBoxTapped()
  {
    if (mStatus == null)
      return;
    if (!mStatus.gpsDisabled)
    {
      choose(true /* gpsDisabled */);
      // The box drives the car, nothing to tell.
      if (mStatus.getSourceState() == NoGps.SourceState.CONNECTED)
        return;
    }
    // The sensors screen tells why the box doesn't drive the car.
    mListener.showSensors(true /* backToGps */);
  }

  private void choose(boolean gpsDisabled)
  {
    NoGps.nativeSetGpsDisabled(gpsDisabled);
    update(NoGps.getStatus());
    mListener.onSourceChosen();
  }

  /**
   * Stops the blinking in the background, the next update starts it again.
   */
  void stop()
  {
    mGps.blink(false);
    mBox.blink(false);
  }

  /**
   * A source: its state icon with a badge and its name.
   */
  private static class Segment
  {
    @NonNull
    final View mView;
    @NonNull
    private final ImageView mIcon;
    @NonNull
    private final ImageView mBadge;
    @NonNull
    private final TextView mLabel;
    @Nullable
    private ObjectAnimator mBlinking;

    Segment(@NonNull View view, @NonNull ImageView icon, @NonNull ImageView badge, @NonNull TextView label)
    {
      mView = view;
      mIcon = icon;
      mBadge = badge;
      mLabel = label;
    }

    void setChosen(boolean chosen)
    {
      mView.setSelected(chosen);
      mLabel.setAlpha(chosen ? 1f : 0.6f);
    }

    /**
     * @param color 0 for the color of the other icons.
     * @param badge 0 for none.
     */
    void show(@DrawableRes int icon, @ColorRes int color, @DrawableRes int badge, @ColorRes int badgeColor,
              boolean blinking)
    {
      final Context context = mView.getContext();
      mIcon.setImageResource(icon);
      final int tint =
          color == 0 ? ThemeUtils.getColor(context, R.attr.iconTint) : ContextCompat.getColor(context, color);
      ImageViewCompat.setImageTintList(mIcon, ColorStateList.valueOf(tint));
      mBadge.setVisibility(badge == 0 ? View.GONE : View.VISIBLE);
      if (badge != 0)
      {
        mBadge.setImageResource(badge);
        mBadge.setBackgroundTintList(ColorStateList.valueOf(ContextCompat.getColor(context, badgeColor)));
        ImageViewCompat.setImageTintList(mBadge, ColorStateList.valueOf(0xFFFFFFFF));
      }
      blink(blinking);
    }

    void blink(boolean on)
    {
      if (on == (mBlinking != null))
        return;
      if (mBlinking != null)
      {
        mBlinking.cancel();
        mBlinking = null;
        mIcon.setAlpha(1f);
        return;
      }
      mBlinking = ObjectAnimator.ofFloat(mIcon, View.ALPHA, 1f, 0.3f);
      mBlinking.setDuration(BLINK_DURATION_MS);
      mBlinking.setRepeatCount(ObjectAnimator.INFINITE);
      mBlinking.setRepeatMode(ObjectAnimator.REVERSE);
      mBlinking.start();
    }
  }
}
