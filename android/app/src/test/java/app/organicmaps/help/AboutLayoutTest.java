package app.organicmaps.help;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import javax.xml.parsers.DocumentBuilderFactory;
import org.junit.Test;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/**
 * The portrait and the landscape About Organic Maps layouts are two files that have to agree, see HelpFragment.
 */
public class AboutLayoutTest
{
  private static final String[] LAYOUTS = {"src/main/res/layout/about.xml", "src/main/res/layout-land/about.xml"};

  /** The leaf is one color and the screen tints it per theme; @drawable/logo is the fork's full-color icon. */
  @Test
  public void bothOrientationsShowTheTintedOrganicMapsLeaf()
  {
    for (String layout : LAYOUTS)
    {
      final Element logo = elementWithAttribute(layout, "app:srcCompat", "@drawable/ic_logo_organicmaps");
      assertNotNull(layout + " shows no @drawable/ic_logo_organicmaps", logo);
      assertEquals(layout + " does not tint the leaf", "?attr/colorLogo", logo.getAttribute("app:tint"));
      assertTrue(layout + " still shows the fork's @drawable/logo",
                 elementWithAttribute(layout, "app:srcCompat", "@drawable/logo") == null);
    }
  }

  /** @string/app_name is the fork's name, so a screen reader would call the Organic Maps leaf "NonGPS Maps". */
  @Test
  public void theLeafIsLabelledOrganicMaps()
  {
    for (String layout : LAYOUTS)
    {
      final Element logo = elementWithAttribute(layout, "app:srcCompat", "@drawable/ic_logo_organicmaps");
      assertNotNull(layout + " shows no @drawable/ic_logo_organicmaps", logo);
      assertEquals(layout + " does not label the leaf Organic Maps", "@string/organic_maps_name",
                   logo.getAttribute("android:contentDescription"));
    }
  }

  /**
   * A focusable version row swallows the first tap: View.onTouchEvent skips performClick() when the touch takes the
   * focus, so HelpFragment.copyVersion would copy on the second tap only.
   */
  @Test
  public void theVersionRowCopiesOnTheFirstTap()
  {
    for (String layout : LAYOUTS)
    {
      final Element version = elementWithAttribute(layout, "android:id", "@+id/version");
      assertNotNull(layout + " has no version row", version);
      assertEquals(layout + " keeps the version row selectable", "", version.getAttribute("android:textIsSelectable"));
      assertEquals(layout + " keeps selectAllOnFocus on the version row", "",
                   version.getAttribute("android:selectAllOnFocus"));
    }
  }

  /**
   * The scrolled column is the only child of a fillViewport ScrollView: when the content is shorter than the
   * viewport, ScrollView.onMeasure re-measures the column with EXACTLY the viewport height and
   * LinearLayout.measureVertical gives a match_parent child all the height left, pushing the rows below it off
   * the screen with nothing to scroll.
   */
  @Test
  public void noScrolledRowTakesTheHeightLeftOver()
  {
    for (String layout : LAYOUTS)
    {
      final Element column = onlyElementChild(parse(layout).getDocumentElement());
      assertEquals(layout + " does not scroll a LinearLayout", "LinearLayout", column.getTagName());
      for (Element row : elementChildren(column))
        assertTrue(layout + " lets the scrolled " + row.getTagName() + " \"" + row.getAttribute("android:text")
                       + "\" take the height left over",
                   !"match_parent".equals(row.getAttribute("android:layout_height")));
    }
  }

  private static Element onlyElementChild(Element parent)
  {
    final List<Element> children = elementChildren(parent);
    assertEquals("Expected one child of " + parent.getTagName(), 1, children.size());
    return children.get(0);
  }

  private static List<Element> elementChildren(Element parent)
  {
    final List<Element> result = new ArrayList<>();
    final NodeList nodes = parent.getChildNodes();
    for (int i = 0; i < nodes.getLength(); ++i)
      if (nodes.item(i) instanceof Element)
        result.add((Element) nodes.item(i));
    return result;
  }

  private static Element elementWithAttribute(String layout, String attribute, String value)
  {
    for (Element element : elements(layout, attribute))
      if (value.equals(element.getAttribute(attribute)))
        return element;
    return null;
  }

  private static List<Element> elements(String layout, String attribute)
  {
    final List<Element> result = new ArrayList<>();
    final NodeList nodes = parse(layout).getElementsByTagName("*");
    for (int i = 0; i < nodes.getLength(); ++i)
    {
      final Element element = (Element) nodes.item(i);
      if (element.hasAttribute(attribute))
        result.add(element);
    }
    return result;
  }

  private static Document parse(String layout)
  {
    File file = new File(layout);
    if (!file.exists())
      file = new File("android/app", layout);
    try
    {
      final DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
      factory.setNamespaceAware(false);
      return factory.newDocumentBuilder().parse(file);
    }
    catch (Exception e)
    {
      throw new AssertionError("Cannot parse " + file.getAbsolutePath(), e);
    }
  }
}
