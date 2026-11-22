package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.Context;
import app.organicmaps.R;
import org.junit.Test;

/**
 * The texts of the How NonGPS works page, see HowNoGpsFragment.
 */
public class HowNoGpsFragmentTest
{
  @Test
  public void rightPanelLineTellsAboutTheZoomSlide()
  {
    final Context context = mock(Context.class);
    when(context.getString(R.string.nogps_how_right)).thenReturn("right");
    when(context.getString(R.string.nogps_intro_right_swipe)).thenReturn("slide");
    // The same line the balloon of the intro and the page on iOS show: both platforms have the gesture.
    assertEquals("right slide", HowNoGpsFragment.rightText(context));
  }
}
