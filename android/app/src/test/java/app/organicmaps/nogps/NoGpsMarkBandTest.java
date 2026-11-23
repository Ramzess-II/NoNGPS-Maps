package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.Test;

public class NoGpsMarkBandTest
{
  private static final String DIMENS = Files.exists(Paths.get("src/main/res/values/dimens.xml"))
                                         ? "src/main/res/values/dimens.xml"
                                         : "app/src/main/res/values/dimens.xml";

  private static int dp(String name) throws IOException
  {
    Matcher m = Pattern.compile("<dimen name=\"" + name + "\">(\\d+)dp</dimen>")
                    .matcher(new String(Files.readAllBytes(Paths.get(DIMENS))));
    assertTrue(name, m.find());
    return Integer.parseInt(m.group(1));
  }

  @Test
  public void routingOffset_isSheetPlusClearance()
  {
    assertEquals(180, NoGpsMarkBand.routingOffsetPx(104, 76));
    assertEquals(76, NoGpsMarkBand.routingOffsetPx(0, 76));
  }

  @Test
  public void bars_endBelowTheMark() throws IOException
  {
    assertTrue(dp("margin_half") + dp("speed_view_size") < dp("nogps_mark_clearance"));
  }

  @Test
  public void sprintAlert_staysAboveTheMark() throws IOException
  {
    assertTrue(dp("sprint_margin_bottom") >= NoGpsMarkBand.topPx(dp("nogps_mark_clearance"), dp("nogps_mark_height")));
  }
}
