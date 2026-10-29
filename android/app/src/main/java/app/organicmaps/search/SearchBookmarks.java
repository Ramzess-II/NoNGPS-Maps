package app.organicmaps.search;

import android.location.Location;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import app.organicmaps.sdk.bookmarks.data.BookmarkCategory;
import app.organicmaps.sdk.bookmarks.data.BookmarkInfo;
import app.organicmaps.sdk.bookmarks.data.BookmarkManager;
import java.text.Collator;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

// The bookmarks shown on the search screen: the first list in the strip, all lists in the Bookmarks tab.
final class SearchBookmarks
{
  static final class Item
  {
    final long id;
    @NonNull
    final String name;
    @NonNull
    final String listName;
    @Nullable
    final Double distance;

    Item(long id, @NonNull String name, @NonNull String listName, @Nullable Double distance)
    {
      this.id = id;
      this.name = name;
      this.listName = listName;
      this.distance = distance;
    }
  }

  private SearchBookmarks() {}

  // The bookmarks of the first list in the Bookmarks screen order, in that list's order.
  @NonNull
  static long[] firstListIds()
  {
    final List<BookmarkCategory> categories = BookmarkManager.INSTANCE.getCategories();
    return categories.isEmpty() ? new long[0] : categories.get(0).getBookmarkIds();
  }

  // The bookmarks of all user lists, nearest first.
  @NonNull
  static List<Item> all(@Nullable Location location)
  {
    final List<Item> items = new ArrayList<>();
    for (BookmarkCategory category : BookmarkManager.INSTANCE.getCategories())
    {
      for (long id : category.getBookmarkIds())
      {
        final BookmarkInfo info = BookmarkManager.INSTANCE.getBookmarkInfo(id);
        if (info == null)
          continue;
        Double distance = null;
        if (location != null)
        {
          final float[] result = new float[1];
          Location.distanceBetween(location.getLatitude(), location.getLongitude(), info.getLat(), info.getLon(),
                                   result);
          distance = (double) result[0];
        }
        items.add(new Item(id, info.getName(), category.getName(), distance));
      }
    }
    sort(items);
    return items;
  }

  // Nearest first; by name when the position is unknown or the distances are equal.
  static void sort(@NonNull List<Item> items)
  {
    final Collator collator = Collator.getInstance();
    collator.setStrength(Collator.SECONDARY);
    final Comparator<Item> byName = (lhs, rhs) -> collator.compare(lhs.name, rhs.name);
    items.sort((lhs, rhs) -> {
      if (lhs.distance != null && rhs.distance != null && !lhs.distance.equals(rhs.distance))
        return Double.compare(lhs.distance, rhs.distance);
      return byName.compare(lhs, rhs);
    });
  }
}
