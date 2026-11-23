package app.organicmaps.nogps;

/**
 * The free band at the bottom of the map in navigation: the speed button, its bars and the "Calibrate the sensor box"
 * pill end at the top of the band, the car mark stands above it. The core adds the mark's own height to the offset.
 */
public final class NoGpsMarkBand
{
  private NoGpsMarkBand() {}

  /**
   * The offset of the mark's lowest point above the bottom of the map.
   *
   * @param widgetsOffsetPx the height of the bottom sheet.
   * @param clearancePx     the band above the sheet.
   */
  public static int routingOffsetPx(int widgetsOffsetPx, int clearancePx)
  {
    return widgetsOffsetPx + clearancePx;
  }

  /**
   * The top of the mark above the sheet: what the alert of a timed run stays above.
   */
  public static int topPx(int clearancePx, int markHeightPx)
  {
    return clearancePx + markHeightPx;
  }
}
