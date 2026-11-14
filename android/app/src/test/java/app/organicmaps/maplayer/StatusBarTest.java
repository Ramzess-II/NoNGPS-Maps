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

  // A failed pairing or a box that forgot the phone stops the search until the user acts: no waves.
  @Test
  public void pairingFailedAsksTheUser()
  {
    for (BleState ble : new BleState[] {BleState.PAIRING_FAILED, BleState.BOND_LOST})
    {
      final StatusBar.Look look = StatusBar.getBoxLook(boxStatus(SourceState.CONNECTING, ble));
      assertEquals(R.drawable.ic_nogps_box, look.icon);
      assertFalse(look.pulsing);
      assertEquals(R.drawable.ic_nogps_badge_alert, look.badge);
    }
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

  // GPS moves the mark: its look, no badge when the box is not a problem.
  @Test
  public void barShowsGpsGood()
  {
    final StatusBar.Look look = StatusBar.getBarLook(boxSetUp(gpsStatus(GpsState.GOOD, PositionSource.GPS)));
    assertEquals(R.color.source_good, look.color);
    assertEquals(R.drawable.ic_nogps_gps, look.icon);
    assertFalse(look.pulsing);
    assertEquals(0, look.badge);
  }

  @Test
  public void barShowsGpsChecking()
  {
    final StatusBar.Look look = StatusBar.getBarLook(boxSetUp(gpsStatus(GpsState.CHECKING, PositionSource.GPS)));
    assertEquals(R.color.source_connecting, look.color);
    assertTrue(look.pulsing);
  }

  @Test
  public void barShowsGpsCoarse()
  {
    final StatusBar.Look look = StatusBar.getBarLook(boxSetUp(gpsStatus(GpsState.COARSE, PositionSource.NETWORK)));
    assertEquals(R.color.source_warning, look.color);
    assertEquals(0, look.badge);
  }

  @Test
  public void barShowsGpsSpoofed()
  {
    final StatusBar.Look look = StatusBar.getBarLook(boxSetUp(gpsStatus(GpsState.SPOOFED, PositionSource.GPS)));
    assertEquals(R.color.source_warning, look.color);
    assertEquals(R.drawable.ic_nogps_badge_alert, look.badge);
  }

  @Test
  public void barShowsNoGps()
  {
    final StatusBar.Look look = StatusBar.getBarLook(boxSetUp(gpsStatus(GpsState.NONE, PositionSource.NONE)));
    assertEquals(R.color.source_bad, look.color);
    assertEquals(R.drawable.ic_nogps_gps_off, look.icon);
  }

  // GPS not used by the car keeps the color of its signal and gets the pause badge.
  @Test
  public void barShowsDisabledGps()
  {
    final NoGps.Status status = boxSetUp(gpsStatus(GpsState.GOOD, PositionSource.MANUAL));
    status.inertialEnabled = false;
    status.gpsDisabled = true;
    final StatusBar.Look look = StatusBar.getBarLook(status);
    assertEquals(R.color.source_good, look.color);
    assertEquals(R.drawable.ic_nogps_badge_pause, look.badge);
  }

  // The box moves the mark: purple.
  @Test
  public void barShowsInertialBox()
  {
    final NoGps.Status status = boxStatus(SourceState.CONNECTED, BleState.CONNECTED);
    setState(status, "source", PositionSource.INERTIAL.ordinal());
    setState(status, "gpsState", GpsState.GOOD.ordinal());
    final StatusBar.Look look = StatusBar.getBarLook(status);
    assertEquals(R.drawable.ic_nogps_box, look.icon);
    assertEquals(R.color.source_inertial, look.color);
    assertEquals(0, look.badge);
  }

  // The mark is set by hand with a box set up: the box look.
  @Test
  public void barShowsBoxForManualWithBox()
  {
    final NoGps.Status status = boxStatus(SourceState.CONNECTED, BleState.CONNECTED);
    setState(status, "source", PositionSource.MANUAL.ordinal());
    setState(status, "gpsState", GpsState.GOOD.ordinal());
    assertEquals(R.drawable.ic_nogps_box, StatusBar.getBarLook(status).icon);
  }

  // GPS moves the mark: a box that searches is not shown, and a blue box gives no dot.
  @Test
  public void barIgnoresSearchingBoxWhileGpsIsGood()
  {
    final NoGps.Status status = boxStatus(SourceState.DISCONNECTED, BleState.SEARCHING);
    setState(status, "source", PositionSource.GPS.ordinal());
    setState(status, "gpsState", GpsState.GOOD.ordinal());
    final StatusBar.Look look = StatusBar.getBarLook(status);
    assertEquals(R.color.source_good, look.color);
    assertEquals(R.drawable.ic_nogps_gps, look.icon);
    assertEquals(0, look.badge);
  }

  // Without a box the button invites to set one up.
  @Test
  public void barShowsPlusWithoutBox()
  {
    final StatusBar.Look look = StatusBar.getBarLook(gpsStatus(GpsState.GOOD, PositionSource.GPS));
    assertEquals(R.drawable.ic_nogps_badge_add, look.badge);
    assertEquals(R.color.source_good, look.color);
  }

  // The look's own badge goes before the plus.
  @Test
  public void barKeepsOwnBadgeWithoutBox()
  {
    final StatusBar.Look look = StatusBar.getBarLook(gpsStatus(GpsState.SPOOFED, PositionSource.GPS));
    assertEquals(R.drawable.ic_nogps_badge_alert, look.badge);
  }

  // The box moves the mark while GPS is lost: a red dot of GPS.
  @Test
  public void barShowsDotOfOtherSourceWhenBad()
  {
    final NoGps.Status status = boxStatus(SourceState.CONNECTED, BleState.CONNECTED);
    setState(status, "source", PositionSource.INERTIAL.ordinal());
    setState(status, "gpsState", GpsState.NONE.ordinal());
    final StatusBar.Look look = StatusBar.getBarLook(status);
    assertEquals(R.drawable.ic_nogps_badge_dot, look.badge);
    assertEquals(R.color.source_bad, look.badgeColor);

    setState(status, "gpsState", GpsState.COARSE.ordinal());
    assertEquals(R.color.source_warning, StatusBar.getBarLook(status).badgeColor);

    setState(status, "gpsState", GpsState.CHECKING.ordinal());
    assertEquals(0, StatusBar.getBarLook(status).badge);
  }

  // GPS moves the mark while the box has a car-data problem: an orange dot of the box.
  @Test
  public void barShowsDotOfBoxProblem()
  {
    final NoGps.Status status = boxStatus(SourceState.NO_CAR_DATA, BleState.CONNECTED);
    setState(status, "source", PositionSource.GPS.ordinal());
    setState(status, "gpsState", GpsState.GOOD.ordinal());
    final StatusBar.Look look = StatusBar.getBarLook(status);
    assertEquals(R.drawable.ic_nogps_badge_dot, look.badge);
    assertEquals(R.color.source_warning, look.badgeColor);
  }

  private static NoGps.Status gpsStatus(GpsState gps, PositionSource source)
  {
    final NoGps.Status status = gpsStatus(gps);
    setState(status, "source", source.ordinal());
    return status;
  }

  // A box that is connected and does not draw attention.
  private static NoGps.Status boxSetUp(NoGps.Status status)
  {
    status.inertialEnabled = true;
    status.esp32Source = true;
    setState(status, "sourceState", SourceState.CONNECTED.ordinal());
    setState(status, "bleState", BleState.CONNECTED.ordinal());
    return status;
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
