package app.organicmaps.nogps;

import androidx.annotation.NonNull;
import androidx.annotation.StringRes;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;

/**
 * What the bar of the speed calibration next to the speed on the map tells, see maplayer.SpeedHintView. GPS measures
 * the error of the car speed in ranges, the distance without GPS is counted with it.
 */
public final class SpeedHints
{
  // A range measured is celebrated this long, a milestone longer.
  public static final long CELEBRATION_MS = 2800;
  public static final long MILESTONE_MS = 4500;

  private SpeedHints() {}

  /**
   * The asking to calibrate the box comes first: both are at the bottom of the map.
   */
  public static boolean isShown(@NonNull NoGps.Status status)
  {
    return status.speedHintShown && !status.boxNeedsCalibration;
  }

  /**
   * The speed is on the map when the position has one, and while the box is connected without one: the calibration bar
   * slides out of it.
   */
  public static boolean isSpeedShown(@NonNull NoGps.Status status, boolean hasSpeed)
  {
    return hasSpeed || BoxBottomSheet.isConnected(status);
  }

  public static boolean celebrates(@NonNull NoGps.Status status)
  {
    return !status.boxNeedsCalibration;
  }

  public static boolean isMeasured(@NonNull NoGps.Status status, int range)
  {
    return range >= 0 && range < status.gpsSpeedTableScale.length && status.gpsSpeedTableScale[range] > 0;
  }

  public static int measuredCount(@NonNull NoGps.Status status)
  {
    int count = 0;
    for (int i = 0; i < status.gpsSpeedTableScale.length; ++i)
      if (isMeasured(status, i))
        ++count;
    return count;
  }

  /**
   * @return the part of the distance driven of what measures the range, 1 for a measured one.
   */
  public static float progress(@NonNull NoGps.Status status, int range)
  {
    if (isMeasured(status, range))
      return 1;
    if (range < 0 || range >= status.gpsSpeedTableCarM.length)
      return 0;
    return Math.max(0, Math.min(1, status.gpsSpeedTableCarM[range] / NoGps.SPEED_TABLE_MIN_DISTANCE_M));
  }

  public static int metersLeft(@NonNull NoGps.Status status, int range)
  {
    final float carM = range >= 0 && range < status.gpsSpeedTableCarM.length ? status.gpsSpeedTableCarM[range] : 0;
    return Math.max(1, (int) Math.ceil(NoGps.SPEED_TABLE_MIN_DISTANCE_M - carM));
  }

  /**
   * Formatted with the range, see NoGps.speedTableFromKmh().
   */
  @StringRes
  public static int titleText(@NonNull NoGps.Status status)
  {
    return status.speedHintGps ? R.string.nogps_speed_hint_calibrating : R.string.nogps_speed_hint_not_calibrated;
  }

  @StringRes
  public static int subtitleText(@NonNull NoGps.Status status)
  {
    return status.speedHintGps ? R.string.nogps_speed_hint_keep_gps : R.string.nogps_speed_hint_turn_gps_on;
  }

  /**
   * The range itself is formatted with the range, the milestones are not formatted.
   */
  @StringRes
  public static int celebrationTitle(@NonNull NoGps.SpeedMilestone milestone)
  {
    return switch (milestone)
    {
      case RANGE -> R.string.nogps_speed_hint_done;
      case CITY -> R.string.nogps_speed_hint_city;
      case OUT_OF_TOWN -> R.string.nogps_speed_hint_out_of_town;
      case FULL -> R.string.nogps_speed_hint_full;
    };
  }

  /**
   * The range: with the ranges measured and all of them. The full table: with all of them.
   */
  @StringRes
  public static int celebrationSubtitle(@NonNull NoGps.SpeedMilestone milestone)
  {
    return switch (milestone)
    {
      case RANGE -> R.string.nogps_speed_hint_done_count;
      case CITY -> R.string.nogps_speed_hint_city_hint;
      case OUT_OF_TOWN -> R.string.nogps_speed_hint_out_of_town_hint;
      case FULL -> R.string.nogps_speed_hint_full_hint;
    };
  }

  public static long celebrationMs(@NonNull NoGps.SpeedMilestone milestone)
  {
    return milestone == NoGps.SpeedMilestone.RANGE ? CELEBRATION_MS : MILESTONE_MS;
  }
}
