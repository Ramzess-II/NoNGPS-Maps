package app.organicmaps.util;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import app.organicmaps.sdk.util.Config;
import org.junit.Test;

public class LightThemeHysteresisTest
{
  private static final long HOLD = LightThemeHysteresis.HOLD_MS;

  @Test
  public void firstReadingAppliesAtOnce()
  {
    assertEquals(Config.UiTheme.DARK, new LightThemeHysteresis().onReading(2, 0));
    assertEquals(Config.UiTheme.LIGHT, new LightThemeHysteresis().onReading(500, 0));
    // Inside the band: the nearer side.
    assertEquals(Config.UiTheme.DARK, new LightThemeHysteresis().onReading(20, 0));
    assertEquals(Config.UiTheme.LIGHT, new LightThemeHysteresis().onReading(40, 0));
  }

  @Test
  public void staysInsideBand()
  {
    final var h = new LightThemeHysteresis();
    h.onReading(500, 0);
    assertNull(h.onReading(30, 10 * HOLD));
    assertNull(h.onReading(10, 20 * HOLD));
    assertNull(h.onTick(30 * HOLD));
    assertFalse(h.hasPending());
  }

  @Test
  public void switchesAfterHold()
  {
    final var h = new LightThemeHysteresis();
    h.onReading(500, 0);
    assertNull(h.onReading(1, 1000));
    assertTrue(h.hasPending());
    // A steady reading sends no event: the timer asks.
    assertNull(h.onTick(1000 + HOLD - 1));
    assertEquals(Config.UiTheme.DARK, h.onTick(1000 + HOLD));
    assertFalse(h.hasPending());
    assertNull(h.onTick(100 * HOLD));
  }

  @Test
  public void reportingDuringHoldDoesNotRestartIt()
  {
    final var h = new LightThemeHysteresis();
    h.onReading(500, 0);
    assertNull(h.onReading(1, 0));
    assertNull(h.onReading(3, HOLD - 1));
    assertEquals(Config.UiTheme.DARK, h.onReading(2, HOLD));
  }

  @Test
  public void ignoresSpikeShorterThanHold()
  {
    final var h = new LightThemeHysteresis();
    h.onReading(500, 0);
    assertNull(h.onReading(1, 1000));
    // Back to bright, even only into the band, cancels the dark candidate.
    assertNull(h.onReading(60, 2000));
    assertFalse(h.hasPending());
    assertNull(h.onTick(1000 + HOLD));
    // A new dip counts from its own start.
    assertNull(h.onReading(1, 10 * HOLD));
    assertNull(h.onTick(10 * HOLD + HOLD - 1));
    assertEquals(Config.UiTheme.DARK, h.onTick(11 * HOLD));
  }

  @Test
  public void switchesBack()
  {
    final var h = new LightThemeHysteresis();
    h.onReading(1, 0);
    h.onReading(500, 100);
    assertEquals(Config.UiTheme.LIGHT, h.onTick(100 + HOLD));
  }
}
