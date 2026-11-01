package app.organicmaps.maplayer;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class SearchWheelTest
{
  // The button of the right panel closes an open wheel, clears a searched category, or opens the wheel.
  @Test
  public void buttonClosesClearsOrOpens()
  {
    assertEquals(SearchWheel.Tap.CLOSE, SearchWheel.onButton(true, false));
    assertEquals(SearchWheel.Tap.CLEAR, SearchWheel.onButton(false, true));
    assertEquals(SearchWheel.Tap.OPEN, SearchWheel.onButton(false, false));
  }
}
