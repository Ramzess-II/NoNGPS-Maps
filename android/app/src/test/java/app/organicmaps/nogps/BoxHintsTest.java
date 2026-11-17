package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.location.NoGps.BleState;
import app.organicmaps.sdk.location.NoGps.CalibrationState;
import app.organicmaps.sdk.location.NoGps.SourceState;
import java.lang.reflect.Field;
import org.junit.Test;

public class BoxHintsTest
{
  // The phone can't reach the box by itself: the user is told what to do.
  @Test
  public void linkHintTellsWhatToDo()
  {
    assertEquals(R.string.nogps_box_bt_pairing_closed,
                 BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.PAIRING_CLOSED)));
    assertEquals(R.string.nogps_box_bt_pairing_by_phone,
                 BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.PAIRING_BY_PHONE)));
    assertEquals(R.string.nogps_box_bt_pairing_full,
                 BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.PAIRING_FULL)));
    assertEquals(R.string.nogps_box_bt_pairing,
                 BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.PAIRING)));
    assertEquals(R.string.nogps_box_bt_pairing_failed,
                 BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.PAIRING_FAILED)));
    assertEquals(R.string.nogps_box_bt_bond_lost,
                 BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.BOND_LOST)));
  }

  // The steps tell the search and the connection themselves.
  @Test
  public void noLinkHintWhileItGoes()
  {
    assertEquals(0, BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.SEARCHING)));
    assertEquals(0, BoxBottomSheet.linkHintText(status(SourceState.CONNECTING, BleState.CONNECTING)));
    assertEquals(0, BoxBottomSheet.linkHintText(status(SourceState.CONNECTED, BleState.CONNECTED)));
  }

  // The box is heard but the car gives no speed: the hint names what to check.
  @Test
  public void obdHintTellsWhatToCheck()
  {
    assertEquals(R.string.nogps_box_hint_no_car,
                 BoxBottomSheet.obdHintText(status(SourceState.NO_CAR_DATA, BleState.CONNECTED)));
    // The box searches the car protocol again while the car is silent: the hint doesn't flip.
    assertEquals(R.string.nogps_box_hint_no_car,
                 BoxBottomSheet.obdHintText(status(SourceState.OBD_CONNECTING, BleState.CONNECTED)));
    assertEquals(R.string.nogps_box_hint_no_adapter,
                 BoxBottomSheet.obdHintText(status(SourceState.NO_ADAPTER, BleState.CONNECTED)));
    assertEquals(R.string.nogps_box_hint_obd_error,
                 BoxBottomSheet.obdHintText(status(SourceState.OBD_ERROR, BleState.CONNECTED)));
    assertEquals(R.string.nogps_box_hint_obd_disabled,
                 BoxBottomSheet.obdHintText(status(SourceState.OBD_DISABLED, BleState.CONNECTED)));
  }

  @Test
  public void noObdHintWithSpeedOrWithoutBox()
  {
    assertEquals(0, BoxBottomSheet.obdHintText(status(SourceState.CONNECTED, BleState.CONNECTED)));
    assertEquals(0, BoxBottomSheet.obdHintText(status(SourceState.OBD_SLEEPING, BleState.CONNECTED)));
    assertEquals(0, BoxBottomSheet.obdHintText(status(SourceState.CONNECTING, BleState.CONNECTED)));
    assertEquals(0, BoxBottomSheet.obdHintText(status(SourceState.NO_CAR_DATA, BleState.SEARCHING)));
  }

  // The bar on the map stays until the box is calibrated.
  @Test
  public void calibrationNeededUntilDone()
  {
    assertTrue(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.NONE, false)));
    assertTrue(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.FAILED_MOVING, false)));
    assertTrue(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.MOUNT_MOVED, false)));
    assertTrue(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.LINK_LOST, false)));
    // The box has been plugged in again since it was calibrated.
    assertTrue(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.DONE, true)));
    assertFalse(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.DONE, false)));
    assertFalse(BoxBottomSheet.needsCalibration(calibrated(CalibrationState.CALIBRATING, true)));
  }

  // Only the phone that can calibrate the box now is asked to.
  @Test
  public void calibrationNotAskedWithoutBoxOrOnReadOnlyBox()
  {
    final NoGps.Status readOnly = calibrated(CalibrationState.NONE, true);
    readOnly.boxReadOnly = true;
    assertFalse(BoxBottomSheet.needsCalibration(readOnly));
    final NoGps.Status outOfReach = calibrated(CalibrationState.NONE, true);
    setState(outOfReach, "bleState", BleState.SEARCHING.ordinal());
    assertFalse(BoxBottomSheet.needsCalibration(outOfReach));
    final NoGps.Status notHeard = calibrated(CalibrationState.NONE, true);
    setState(notHeard, "sourceState", SourceState.CONNECTING.ordinal());
    assertFalse(BoxBottomSheet.needsCalibration(notHeard));
  }

  private static NoGps.Status calibrated(CalibrationState calibration, boolean advised)
  {
    final NoGps.Status status = status(SourceState.CONNECTED, BleState.CONNECTED);
    setState(status, "calibration", calibration.ordinal());
    status.boxCalibrationAdvised = advised;
    return status;
  }

  private static NoGps.Status status(SourceState source, BleState ble)
  {
    final NoGps.Status status = new NoGps.Status();
    status.inertialEnabled = true;
    status.inertialStarted = true;
    status.esp32Source = true;
    setState(status, "sourceState", source.ordinal());
    setState(status, "bleState", ble.ordinal());
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
