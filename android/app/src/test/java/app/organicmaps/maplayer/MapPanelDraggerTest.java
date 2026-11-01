package app.organicmaps.maplayer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class MapPanelDraggerTest
{
  private static final float DT = 1f / 60;

  @Test
  public void flingSlowsToStop()
  {
    float y = 0;
    float v = 1000;
    int frames = 0;
    while (v != 0)
    {
      final float[] next = MapPanelDragger.step(y, v, DT, 0, 10000);
      assertTrue(next[1] < v);
      assertTrue(next[1] >= 0);
      y = next[0];
      v = next[1];
      assertTrue(++frames < 1000);
    }
    // A scroll view flung with 1000 dp/s goes about 500 dp.
    assertEquals(1000 / -Math.log(MapPanelDragger.DECELERATION) / 1000, y, 20);
  }

  @Test
  public void bouncesAtEachEnd()
  {
    final double decay = Math.pow(MapPanelDragger.DECELERATION, DT * 1000);
    float[] next = MapPanelDragger.step(99, 1000, DT, 0, 100);
    assertEquals(-1000 * decay * MapPanelDragger.BOUNCE, next[1], 0.01);
    assertTrue(next[0] <= 100);
    next = MapPanelDragger.step(1, -1000, DT, 0, 100);
    assertEquals(1000 * decay * MapPanelDragger.BOUNCE, next[1], 0.01);
    assertTrue(next[0] >= 0);
  }

  @Test
  public void neverLeavesRange()
  {
    for (float v0 : new float[] {-50000, -3000, 3000, 50000})
    {
      float y = 50;
      float v = v0;
      for (int i = 0; i < 600; ++i)
      {
        // A long frame too, e.g. after the app was in the background.
        final float[] next = MapPanelDragger.step(y, v, i == 2 ? 1 : DT, 0, 100);
        y = next[0];
        v = next[1];
        assertTrue(y + " with " + v0, y >= 0 && y <= 100);
      }
      assertEquals(0, v, 0);
    }
  }

  @Test
  public void slowReleaseDoesNotMove()
  {
    assertFalse(MapPanelDragger.flings(0));
    assertFalse(MapPanelDragger.flings(MapPanelDragger.FLING_SPEED - 1));
    assertFalse(MapPanelDragger.flings(-MapPanelDragger.FLING_SPEED + 1));
    assertTrue(MapPanelDragger.flings(MapPanelDragger.FLING_SPEED));
    assertTrue(MapPanelDragger.flings(-MapPanelDragger.FLING_SPEED));
    // A slow fling stops at once.
    assertEquals(0, MapPanelDragger.step(50, MapPanelDragger.STOP_SPEED / 2, DT, 0, 100)[1], 0);
  }
}
