package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.location.NoGps.BleState;
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
