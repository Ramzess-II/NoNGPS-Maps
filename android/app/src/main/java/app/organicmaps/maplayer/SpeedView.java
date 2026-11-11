package app.organicmaps.maplayer;

import android.content.Context;
import android.location.Location;
import android.util.Pair;
import android.view.View;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.settings.UnitLocale;
import app.organicmaps.sdk.util.StringUtils;
import app.organicmaps.util.ThemeUtils;

/**
 * The round view at the bottom start of the map: the speed of the position that moves the mark and the limit of the
 * road it is on as a road sign. Over the limit the number is red, over the limit of a speed camera the whole view is.
 */
class SpeedView
{
  private static final float MPS_TO_KMH = 3.6f;
  private static final float MPS_TO_MPH = 2.2369363f;
  private static final String NO_LIMIT = "∞";
  private static final int CAMERA_UNITS_COLOR = 0xCCFFFFFF;

  @NonNull
  private final View mView;
  @NonNull
  private final TextView mValue;
  @NonNull
  private final TextView mUnits;
  @NonNull
  private final TextView mLimit;

  SpeedView(@NonNull View view)
  {
    mView = view;
    mValue = view.findViewById(R.id.speed_view_value);
    mUnits = view.findViewById(R.id.speed_view_units);
    mLimit = view.findViewById(R.id.speed_view_limit);
  }

  /**
   * @param location the position of the car, null if there is none: the view is hidden, but keeps its place.
   * @param camera   the speed is over the limit of a speed camera ahead.
   */
  void update(@NonNull NoGps.Status status, @Nullable Location location, boolean camera)
  {
    if (location == null || status.getSource() == NoGps.PositionSource.NONE)
    {
      mView.setVisibility(View.INVISIBLE);
      return;
    }
    mView.setVisibility(View.VISIBLE);
    final Context context = mView.getContext();
    final float speed = location.hasSpeed() ? location.getSpeed() : 0;
    final Pair<String, String> speedAndUnits = StringUtils.nativeFormatSpeedAndUnits(speed);
    mValue.setText(speedAndUnits.first);
    mUnits.setText(speedAndUnits.second);

    final int limit = status.speedLimitKmh;
    final boolean over = isOverLimit(speed, limit, UnitLocale.getUnits() == UnitLocale.UNITS_FOOT);
    mView.setActivated(camera);
    if (camera)
    {
      mValue.setTextColor(ContextCompat.getColor(context, R.color.white_primary));
      mUnits.setTextColor(CAMERA_UNITS_COLOR);
    }
    else
    {
      mValue.setTextColor(over ? ContextCompat.getColor(context, R.color.base_red)
                               : ThemeUtils.getColor(context, android.R.attr.textColorPrimary));
      mUnits.setTextColor(ThemeUtils.getColor(context, android.R.attr.textColorSecondary));
    }
    mLimit.setVisibility(limit < 0 ? View.GONE : View.VISIBLE);
    final String limitText = limit == 0 ? NO_LIMIT : StringUtils.nativeFormatSpeedAndUnits(limit / MPS_TO_KMH).first;
    mLimit.setText(limitText);

    final StringBuilder description = new StringBuilder(
        context.getString(R.string.nogps_speed_view, speedAndUnits.first + " " + speedAndUnits.second));
    if (limit == 0)
      description.append(". ").append(context.getString(R.string.nogps_speed_no_limit));
    else if (limit > 0)
      description.append(". ").append(
          context.getString(R.string.nogps_speed_limit, limitText + " " + speedAndUnits.second));
    if (camera)
      description.append(". ").append(context.getString(R.string.nogps_speed_over_camera));
    mView.setContentDescription(description);
  }

  /**
   * Compares the speed with the limit as both are shown: rounded in the units of the user.
   * @param speedMps the speed of the car.
   * @param limitKmh the limit of the road: 0 if there is none, -1 if unknown.
   * @param imperial the speeds are shown in miles per hour.
   */
  static boolean isOverLimit(float speedMps, int limitKmh, boolean imperial)
  {
    if (limitKmh <= 0)
      return false;
    final float perMps = imperial ? MPS_TO_MPH : MPS_TO_KMH;
    return Math.round(speedMps * perMps) > Math.round(limitKmh / MPS_TO_KMH * perMps);
  }
}
