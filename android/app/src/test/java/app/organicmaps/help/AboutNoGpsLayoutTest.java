package app.organicmaps.help;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import javax.xml.parsers.DocumentBuilderFactory;
import org.junit.Test;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/** About NonGPS Maps fits a phone screen: no description, the globe takes the height the other rows leave. */
public class AboutNoGpsLayoutTest
{
  private static final String LAYOUT = "src/main/res/layout/about_nogps.xml";

  @Test
  public void thereIsNoDescriptionUnderTheGlobe()
  {
    for (Element element : elements())
      assertTrue("@string/nogps_about_description is back",
                 !"@string/nogps_about_description".equals(element.getAttribute("android:text")));
  }

  @Test
  public void theGlobeTakesTheHeightLeftOver()
  {
    final Element globe = elementWithAttribute("android:id", "@+id/globe");
    assertNotNull(globe);
    assertEquals("0dp", globe.getAttribute("android:layout_height"));
    assertEquals("1", globe.getAttribute("android:layout_weight"));
    assertEquals("@dimen/nogps_globe_min_height", globe.getAttribute("android:minHeight"));
  }

  @Test
  public void theMapDataCreditStays()
  {
    assertNotNull(elementWithAttribute("android:id", "@+id/map_data"));
  }

  private static Element elementWithAttribute(String attribute, String value)
  {
    for (Element element : elements())
      if (value.equals(element.getAttribute(attribute)))
        return element;
    return null;
  }

  private static Element[] elements()
  {
    File file = new File(LAYOUT);
    if (!file.exists())
      file = new File("android/app", LAYOUT);
    try
    {
      final DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
      factory.setNamespaceAware(false);
      final Document document = factory.newDocumentBuilder().parse(file);
      final NodeList nodes = document.getElementsByTagName("*");
      final Element[] result = new Element[nodes.getLength()];
      for (int i = 0; i < result.length; ++i)
        result[i] = (Element) nodes.item(i);
      return result;
    }
    catch (Exception e)
    {
      throw new AssertionError("Cannot parse " + file.getAbsolutePath(), e);
    }
  }
}
