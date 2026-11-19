package app.organicmaps.nogps;

import static app.organicmaps.nogps.StatusNotification.Content.FOLLOWING;
import static app.organicmaps.nogps.StatusNotification.Content.NAVIGATION;
import static app.organicmaps.nogps.StatusNotification.Content.NONE;
import static app.organicmaps.nogps.StatusNotification.Content.SHARE_ONLY;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class StatusNotificationTest
{
  // Navigation first, then the car followed by the box, then the share notice. The box running while navigating, and
  // the share on, don't make a second item.
  @Test
  public void choosesOneContentForEveryCase()
  {
    for (boolean box : new boolean[] {false, true})
      for (boolean share : new boolean[] {false, true})
        assertEquals(NAVIGATION, StatusNotification.choose(true, box, share));
    assertEquals(FOLLOWING, StatusNotification.choose(false, true, false));
    assertEquals(FOLLOWING, StatusNotification.choose(false, true, true));
    assertEquals(SHARE_ONLY, StatusNotification.choose(false, false, true));
    assertEquals(NONE, StatusNotification.choose(false, false, false));
  }

  // The navigation ends while the box runs: the box content comes back.
  @Test
  public void endingNavigationFallsBackToTheBox()
  {
    assertEquals(NAVIGATION, StatusNotification.choose(true, true, false));
    assertEquals(FOLLOWING, StatusNotification.choose(false, true, false));
  }

  @Test
  public void titleHasTheDistanceToTheTurnAndTheNextStreet()
  {
    assertEquals("500 m · Main Street", StatusNotification.getTitle("500 m", "Main Street"));
    assertEquals("500 m", StatusNotification.getTitle("500 m", ""));
    assertEquals("500 m", StatusNotification.getTitle("500 m", null));
  }

  @Test
  public void textHasTheDistanceTheTimeLeftAndTheArrival()
  {
    assertEquals("12.4 km · 18 min · 14:32", StatusNotification.getText("12.4 km", 18 * 60, "h", "min", "14:32"));
    assertEquals("80 km · 1 h 5 min · 15:00", StatusNotification.getText("80 km", 65 * 60, "h", "min", "15:00"));
    assertEquals("2 h 0 min", StatusNotification.getText("", 2 * 3600, "h", "min", "").split(" · ")[1]);
    // The least time left is a minute.
    assertEquals("1 min", StatusNotification.getText("", 5, "h", "min", "").split(" · ")[1]);
  }
}
