package app.organicmaps.search;

import static org.junit.Assert.assertEquals;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;

public class SearchBookmarksTest
{
  @Test
  public void sortsNearestFirstAndByNameOnEqualDistance()
  {
    final List<SearchBookmarks.Item> items =
        new ArrayList<>(Arrays.asList(item(1, "b", 500.0), item(2, "c", 100.0), item(3, "A", 500.0)));

    SearchBookmarks.sort(items);

    assertEquals(Arrays.asList(2L, 3L, 1L), ids(items));
  }

  @Test
  public void sortsByNameIgnoringCaseWithoutPosition()
  {
    final List<SearchBookmarks.Item> items =
        new ArrayList<>(Arrays.asList(item(1, "work", null), item(2, "Home", null), item(3, "gym", null)));

    SearchBookmarks.sort(items);

    assertEquals(Arrays.asList(3L, 2L, 1L), ids(items));
  }

  private static SearchBookmarks.Item item(long id, String name, Double distance)
  {
    return new SearchBookmarks.Item(id, name, "My places", distance);
  }

  private static List<Long> ids(List<SearchBookmarks.Item> items)
  {
    final List<Long> ids = new ArrayList<>();
    for (SearchBookmarks.Item item : items)
      ids.add(item.id);
    return ids;
  }
}
