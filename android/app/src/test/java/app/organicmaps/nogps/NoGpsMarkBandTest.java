package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class NoGpsMarkBandTest
{
  // dp values of dimens.xml: margin_half + speed_view_size, nogps_mark_clearance, nogps_mark_height,
  // sprint_margin_bottom.
  private static final int BAR_TOP = 8 + 60;
  private static final int CLEARANCE = 76;
  private static final int MARK_HEIGHT = 64;
  private static final int SPRINT_MARGIN = 148;

  @Test
  public void routingOffset_isSheetPlusClearance()
  {
    assertEquals(180, NoGpsMarkBand.routingOffsetPx(104, CLEARANCE));
    assertEquals(CLEARANCE, NoGpsMarkBand.routingOffsetPx(0, CLEARANCE));
  }

  @Test
  public void bars_endBelowTheMark()
  {
    assertTrue(BAR_TOP < CLEARANCE);
  }

  @Test
  public void sprintAlert_staysAboveTheMark()
  {
    assertTrue(SPRINT_MARGIN >= NoGpsMarkBand.topPx(CLEARANCE, MARK_HEIGHT));
  }
}
