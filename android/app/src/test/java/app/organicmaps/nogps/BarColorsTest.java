package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

import java.io.File;
import javax.xml.parsers.DocumentBuilderFactory;
import org.junit.Test;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/**
 * The bars are the NonGPS cream in light theme and keep the grey of the night theme. The tests are plain JUnit without
 * Robolectric, so the resource files are read as XML.
 */
public class BarColorsTest
{
  private static String value(String dir, String file, String tag, String name) throws Exception
  {
    final File f = new File("src/main/res/" + dir + "/" + file);
    final NodeList nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(f).getElementsByTagName(tag);
    for (int i = 0; i < nodes.getLength(); i++)
    {
      final Element e = (Element) nodes.item(i);
      if (name.equals(e.getAttribute("name")))
        return e.getTextContent().trim();
    }
    return null;
  }

  @Test
  public void primaryIsCreamInLightAndGreyAtNight() throws Exception
  {
    assertEquals("#FFE3E1D2", value("values", "colors.xml", "color", "nogps_primary"));
    assertEquals("#FF1E2226", value("values-night", "colors.xml", "color", "nogps_primary"));
  }

  @Test
  public void toolbarTextIsDarkInLightAndLightAtNight() throws Exception
  {
    assertEquals("@color/text_dark", value("values", "colors.xml", "color", "toolbar_text"));
    assertEquals("@color/text_light", value("values-night", "colors.xml", "color", "toolbar_text"));
    assertNotNull(value("values", "colors.xml", "color", "toolbar_text_hint"));
    assertNotNull(value("values-night", "colors.xml", "color", "toolbar_text_hint"));
  }

  @Test
  public void statusBarIconsFollowTheBar() throws Exception
  {
    assertEquals("true", value("values", "bools.xml", "bool", "nogps_light_bars"));
    assertEquals("false", value("values-night", "bools.xml", "bool", "nogps_light_bars"));
  }

  @Test
  public void themesTakeThePrimary() throws Exception
  {
    for (String dir : new String[] {"values", "values-night"})
      assertEquals("@color/nogps_primary", value(dir, "themes-base.xml", "item", "colorPrimary"));
  }
}
