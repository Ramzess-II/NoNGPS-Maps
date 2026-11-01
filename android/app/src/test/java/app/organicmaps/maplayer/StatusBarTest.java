package app.organicmaps.maplayer;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.organicmaps.sdk.location.NoGps.PositionSource;
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
}
