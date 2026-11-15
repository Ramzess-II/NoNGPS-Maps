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

  // The sweep starts at the top and turns through the map side: the west in LTR, the east in RTL. The angles are of a
  // canvas, clockwise from the east, so the arc from sectorStart() clockwise by the sweep is what is shown.
  @Test
  public void sweepStartsAtTopAndTurnsThroughMapSide()
  {
    assertEquals(270, SearchWheelFrame.sectorStart(0, false), 0);
    // From the west to the top.
    assertEquals(180, SearchWheelFrame.sectorStart(90, false), 0);
    // From the bottom through the west to the top.
    assertEquals(90, SearchWheelFrame.sectorStart(SearchWheelFrame.FULL_SWEEP, false), 0);
    // From the top to the east, then to the bottom.
    assertEquals(270, SearchWheelFrame.sectorStart(90, true), 0);
    assertEquals(270, SearchWheelFrame.sectorStart(SearchWheelFrame.FULL_SWEEP, true), 0);
  }
}
