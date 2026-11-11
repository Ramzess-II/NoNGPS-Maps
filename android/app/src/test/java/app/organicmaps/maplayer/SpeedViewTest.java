package app.organicmaps.maplayer;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class SpeedViewTest
{
  private static final float KMH = 1 / 3.6f;
  private static final float MPH = 1 / 2.2369363f;

  @Test
  public void overLimitAsShownInKilometers()
  {
    assertFalse(SpeedView.isOverLimit(50.4f * KMH, 50, false));
    assertTrue(SpeedView.isOverLimit(51 * KMH, 50, false));
  }

  // 50 km/h is shown as 31 mph: 31.4 mph is not over it, 32 mph is.
  @Test
  public void overLimitAsShownInMiles()
  {
    assertFalse(SpeedView.isOverLimit(31.4f * MPH, 50, true));
    assertTrue(SpeedView.isOverLimit(32 * MPH, 50, true));
  }

  @Test
  public void noLimitIsNeverOver()
  {
    assertFalse(SpeedView.isOverLimit(200 * KMH, 0, false));
    assertFalse(SpeedView.isOverLimit(200 * KMH, -1, false));
  }
}
