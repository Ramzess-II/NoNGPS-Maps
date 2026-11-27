package app.organicmaps.maplayer;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class ShakeTraceViewTest
{
  private static final float HEIGHT = 100;
  private static final float DELTA = 0.01f;

  // The limit is at 45% from the top, 0 at the bottom, 1000 and more at the top edge, 300 is 3x on the log scale.
  @Test
  public void splitScale()
  {
    assertEquals(100, ShakeTraceView.y(0, HEIGHT), DELTA);
    assertEquals(45, ShakeTraceView.y(100, HEIGHT), DELTA);
    assertEquals(45 * (1 - (float) Math.log10(3)), ShakeTraceView.y(300, HEIGHT), DELTA);
    assertEquals(0, ShakeTraceView.y(1000, HEIGHT), DELTA);
    assertEquals(0, ShakeTraceView.y(9999, HEIGHT), DELTA);
    assertEquals(100, ShakeTraceView.y(-5, HEIGHT), DELTA);
  }

  // A value of 100 and more is not still: it resets the count.
  @Test
  public void heldTimeIsTheNewestValuesUnderTheLimit()
  {
    assertEquals(0, ShakeTraceView.heldMs(new int[0]));
    assertEquals(0, ShakeTraceView.heldMs(new int[] {10, 20, 100}));
    assertEquals(40, ShakeTraceView.heldMs(new int[] {500, 10, 99}));
    final int[] still = new int[150];
    assertEquals(ShakeTraceView.HOLD_MS, ShakeTraceView.heldMs(still));
    still[10] = 400;
    assertEquals(ShakeTraceView.HOLD_MS, ShakeTraceView.heldMs(still));
    still[149] = 100;
    assertEquals(0, ShakeTraceView.heldMs(still));
  }
}
