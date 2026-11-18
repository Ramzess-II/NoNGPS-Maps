package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.location.NoGps.BleState;
import app.organicmaps.sdk.location.NoGps.CalibrationState;
import app.organicmaps.sdk.location.NoGps.SourceState;
import app.organicmaps.sdk.location.NoGps.SpeedMilestone;
import java.lang.reflect.Field;
import org.junit.Test;

public class SpeedHintsTest
{
  private static final int RANGES = 14;

  // The core shows the bar, the asking to calibrate the box comes first.
  @Test
  public void shownUnlessBoxIsToBeCalibrated()
  {
    final NoGps.Status status = status(CalibrationState.DONE);
    assertFalse(SpeedHints.isShown(status));
    status.speedHintShown = true;
    assertTrue(SpeedHints.isShown(status));
    assertTrue(SpeedHints.celebrates(status));

    final NoGps.Status notCalibrated = status(CalibrationState.NONE);
    notCalibrated.speedHintShown = true;
    assertFalse(SpeedHints.isShown(notCalibrated));
    assertFalse(SpeedHints.celebrates(notCalibrated));
  }

  // Accurate GPS measures the speed now, or the user is asked to turn it on.
  @Test
  public void textsTellWhetherGpsMeasures()
  {
    final NoGps.Status status = status(CalibrationState.DONE);
    status.speedHintGps = true;
    assertEquals(R.string.nogps_speed_hint_calibrating, SpeedHints.titleText(status));
    assertEquals(R.string.nogps_speed_hint_keep_gps, SpeedHints.subtitleText(status));
    status.speedHintGps = false;
    assertEquals(R.string.nogps_speed_hint_not_calibrated, SpeedHints.titleText(status));
    assertEquals(R.string.nogps_speed_hint_turn_gps_on, SpeedHints.subtitleText(status));
  }

  // The GPS table tells the ranges measured and how far the others are driven.
  @Test
  public void progressOfRanges()
  {
    final NoGps.Status status = status(CalibrationState.DONE);
    status.gpsSpeedTableScale[1] = 1.02f;
    status.gpsSpeedTableCarM[1] = 450;
    status.gpsSpeedTableCarM[5] = 120;
    assertTrue(SpeedHints.isMeasured(status, 1));
    assertFalse(SpeedHints.isMeasured(status, 5));
    assertEquals(1, SpeedHints.measuredCount(status));
    assertEquals(1, SpeedHints.progress(status, 1), 0);
    assertEquals(0.4f, SpeedHints.progress(status, 5), 1e-6);
    assertEquals(0, SpeedHints.progress(status, 6), 0);
    assertEquals(180, SpeedHints.metersLeft(status, 5));
    // Not 0 m before the core counts the range measured.
    status.gpsSpeedTableCarM[5] = 299.9f;
    assertEquals(1, SpeedHints.metersLeft(status, 5));
  }

  // A milestone is celebrated longer, with its own texts.
  @Test
  public void celebrationOfMilestones()
  {
    assertEquals(R.string.nogps_speed_hint_done, SpeedHints.celebrationTitle(SpeedMilestone.RANGE));
    assertEquals(R.string.nogps_speed_hint_done_count, SpeedHints.celebrationSubtitle(SpeedMilestone.RANGE));
    assertEquals(R.string.nogps_speed_hint_city, SpeedHints.celebrationTitle(SpeedMilestone.CITY));
    assertEquals(R.string.nogps_speed_hint_city_hint, SpeedHints.celebrationSubtitle(SpeedMilestone.CITY));
    assertEquals(R.string.nogps_speed_hint_out_of_town, SpeedHints.celebrationTitle(SpeedMilestone.OUT_OF_TOWN));
    assertEquals(R.string.nogps_speed_hint_out_of_town_hint,
                 SpeedHints.celebrationSubtitle(SpeedMilestone.OUT_OF_TOWN));
    assertEquals(R.string.nogps_speed_hint_full, SpeedHints.celebrationTitle(SpeedMilestone.FULL));
    assertEquals(R.string.nogps_speed_hint_full_hint, SpeedHints.celebrationSubtitle(SpeedMilestone.FULL));
    assertEquals(SpeedHints.CELEBRATION_MS, SpeedHints.celebrationMs(SpeedMilestone.RANGE));
    assertEquals(SpeedHints.MILESTONE_MS, SpeedHints.celebrationMs(SpeedMilestone.CITY));
    assertEquals(SpeedHints.MILESTONE_MS, SpeedHints.celebrationMs(SpeedMilestone.FULL));
  }

  private static NoGps.Status status(CalibrationState calibration)
  {
    final NoGps.Status status = new NoGps.Status();
    status.inertialEnabled = true;
    status.inertialStarted = true;
    status.esp32Source = true;
    status.gpsSpeedTableCarM = new float[RANGES];
    status.gpsSpeedTableScale = new float[RANGES];
    setState(status, "sourceState", SourceState.CONNECTED.ordinal());
    setState(status, "bleState", BleState.CONNECTED.ordinal());
    setState(status, "calibration", calibration.ordinal());
    return status;
  }

  // The states are set by JNI only.
  private static void setState(NoGps.Status status, String name, int value)
  {
    try
    {
      final Field field = NoGps.Status.class.getDeclaredField(name);
      field.setAccessible(true);
      field.setInt(status, value);
    }
    catch (ReflectiveOperationException e)
    {
      throw new AssertionError(e);
    }
  }
}
