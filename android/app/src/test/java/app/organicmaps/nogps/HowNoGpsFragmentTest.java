package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

/**
 * What the How NonGPS works page does with a link and a locale, see HowNoGpsFragment. The same decisions are tested
 * on iOS in HowNoGpsTests.
 */
public class HowNoGpsFragmentTest
{
  @Test
  public void introLinkPlaysTheIntro()
  {
    assertEquals(HowNoGpsFragment.UrlAction.INTRO, HowNoGpsFragment.classify("nogps-guide://intro"));
  }

  @Test
  public void webLinksGoToTheBrowser()
  {
    assertEquals(HowNoGpsFragment.UrlAction.BROWSER, HowNoGpsFragment.classify("https://non-gps.com"));
    assertEquals(HowNoGpsFragment.UrlAction.BROWSER, HowNoGpsFragment.classify("http://example.com/a"));
  }

  @Test
  public void assetsAreLoaded()
  {
    assertEquals(HowNoGpsFragment.UrlAction.LOAD,
                 HowNoGpsFragment.classify("file:///android_asset/nogps_guide.html?lang=uk"));
  }

  @Test
  public void ukrainianForUkAndRuOnly()
  {
    assertEquals("uk", HowNoGpsFragment.pageLang("uk"));
    assertEquals("uk", HowNoGpsFragment.pageLang("ru"));
    assertEquals("en", HowNoGpsFragment.pageLang("de"));
    assertEquals("en", HowNoGpsFragment.pageLang("en"));
  }
}
