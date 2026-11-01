package app.organicmaps.maplayer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.location.NoGps.BleState;
import app.organicmaps.sdk.location.NoGps.GpsState;
import app.organicmaps.sdk.location.NoGps.PositionSource;
import app.organicmaps.sdk.location.NoGps.SourceState;
import java.lang.reflect.Field;
import org.junit.Test;

public class StatusBarTest
{
  // The source button of the navigation menu shows the box when the car follows it, or when the mark is set by hand
  // with a box set up. Else it shows GPS.
  @Test
  public void navButtonShowsBoxOnlyForBox()
  {
    assertFalse(StatusBar.navShowsBox(PositionSource.GPS, true));
    assertFalse(StatusBar.navShowsBox(PositionSource.NETWORK, true));
    assertTrue(StatusBar.navShowsBox(PositionSource.INERTIAL, true));
    assertTrue(StatusBar.navShowsBox(PositionSource.MANUAL, true));
    assertFalse(StatusBar.navShowsBox(PositionSource.MANUAL, false));
    assertFalse(StatusBar.navShowsBox(PositionSource.NONE, true));
    assertFalse(StatusBar.navShowsBox(PositionSource.NONE, false));
  }

  // GPS not used by the car keeps the color of its signal and gets the pause badge.
  @Test
  public void disabledGpsShowsItsSignal()
  {
    final NoGps.Status good = gpsStatus(GpsState.GOOD);
    good.gpsDisabled = true;
    final StatusBar.Look look = StatusBar.getGpsLook(good);
    assertEquals(R.color.source_good, look.color);
    assertEquals(R.drawable.ic_nogps_badge_pause, look.badge);

    final NoGps.Status none = gpsStatus(GpsState.NONE);
    none.gpsDisabled = true;
    assertEquals(R.color.source_bad, StatusBar.getGpsLook(none).color);
  }

  // The spoofing badge matters more than the pause one.
  @Test
  public void disabledSpoofedGpsKeepsTheAlert()
  {
    final NoGps.Status status = gpsStatus(GpsState.SPOOFED);
    status.gpsDisabled = true;
    assertEquals(R.drawable.ic_nogps_badge_alert, StatusBar.getGpsLook(status).badge);
  }

  @Test
  public void usedGpsHasNoBadge()
  {
    assertEquals(0, StatusBar.getGpsLook(gpsStatus(GpsState.GOOD)).badge);
  }

  // The phone looks for a sleeping box: the button shows the search with the moon.
  @Test
  public void sleepingBoxShowsTheSearch()
  {
    final StatusBar.Look look = StatusBar.getBoxLook(boxStatus(SourceState.BOX_SLEEPING, BleState.SEARCHING));
    assertEquals(R.drawable.ic_nogps_bluetooth, look.icon);
    assertTrue(look.pulsing);
    assertEquals(R.drawable.ic_nogps_badge_sleep, look.badge);
  }

  // Bluetooth off matters more than the sleep: the box would not be found when it wakes.
  @Test
  public void sleepingBoxWithBluetoothOffShowsIt()
  {
    final StatusBar.Look look = StatusBar.getBoxLook(boxStatus(SourceState.BOX_SLEEPING, BleState.DISABLED));
    assertEquals(R.drawable.ic_nogps_bluetooth_off, look.icon);
    assertFalse(look.pulsing);
    assertEquals(0, look.badge);
  }

  // The OBD of a box that is heard sleeps: nothing is searched.
  @Test
  public void sleepingObdShowsTheMoon()
  {
    final StatusBar.Look look = StatusBar.getBoxLook(boxStatus(SourceState.OBD_SLEEPING, BleState.CONNECTED));
    assertEquals(R.drawable.ic_nogps_box, look.icon);
    assertFalse(look.pulsing);
    assertEquals(R.drawable.ic_nogps_badge_sleep, look.badge);
  }

  private static NoGps.Status gpsStatus(GpsState gps)
  {
    final NoGps.Status status = new NoGps.Status();
    setState(status, "gpsState", gps.ordinal());
    return status;
  }

  private static NoGps.Status boxStatus(SourceState source, BleState ble)
  {
    final NoGps.Status status = new NoGps.Status();
    status.inertialEnabled = true;
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
