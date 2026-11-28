package app.organicmaps.nogps;

import androidx.annotation.DrawableRes;
import androidx.annotation.NonNull;
import androidx.annotation.StringRes;
import app.organicmaps.R;
import app.organicmaps.util.bottomsheet.MenuBottomSheetItem;
import java.util.ArrayList;
import java.util.List;

/**
 * The rows of the main menu sheet and of the Map tools sheet it opens, in groups. The first group has no divider above
 * it (the main menu has the map styles there); the first row of every other group draws one. Kept out of MwmActivity
 * so the order can be tested.
 */
public final class MainMenuItems
{
  /** What the rows do. MwmActivity owns the screens, the list only orders them. */
  public interface Handlers
  {
    void openProfile();

    void openSettings();

    void openMapTools();

    void shareLocation();

    void openBookmarks();

    void downloadMaps();

    void toggleTrackRecording();

    void addPlace();

    void openHowItWorks();

    void openAboutNoGps();

    void openAboutOrganicMaps();

    void buyBox();

    void donate();
  }

  /**
   * The main menu: Profile, Settings and the Map tools row, then the NonGPS and about rows.
   *
   * @param donate         a donate URL is configured
   * @param downloadsBadge how many maps wait for an update, 0 for no badge: the Map tools row carries it
   */
  @NonNull
  public static ArrayList<MenuBottomSheetItem> create(boolean donate, int downloadsBadge, @NonNull Handlers handlers)
  {
    final List<Row> setup = List.of(
        new Row(R.string.nogps_menu_profile, R.drawable.profile_generic, handlers::openProfile),
        new Row(R.string.settings, R.drawable.ic_settings, handlers::openSettings),
        // The adapter shows the running state of the recorder on this row too.
        new Row(R.string.nogps_menu_map_tools, R.drawable.ic_map_tools, downloadsBadge, handlers::openMapTools));

    final List<Row> about = new ArrayList<>(
        List.of(new Row(R.string.nogps_how_title, R.drawable.ic_question_mark, handlers::openHowItWorks),
                new Row(R.string.nogps_about_title, R.drawable.ic_info, handlers::openAboutNoGps),
                new Row(R.string.nogps_about_om_menu, R.drawable.ic_info, handlers::openAboutOrganicMaps),
                new Row(R.string.nogps_box_buy, R.drawable.ic_nogps_box, handlers::buyBox)));
    if (donate)
      about.add(new Row(R.string.donate, R.drawable.ic_donate, handlers::donate));

    return toItems(List.of(setup, about), true);
  }

  /**
   * The second sheet, opened by the Map tools row: the Organic Maps tools.
   *
   * @param mapEditing     a MAP_EDITING build: only there the user can add a place to OpenStreetMap
   * @param downloadsBadge how many maps wait for an update, 0 for no badge
   */
  @NonNull
  public static ArrayList<MenuBottomSheetItem> createMapTools(boolean mapEditing, int downloadsBadge,
                                                              @NonNull Handlers handlers)
  {
    final List<Row> rows = new ArrayList<>(
        List.of(new Row(R.string.share_my_location, R.drawable.ic_share, handlers::shareLocation),
                new Row(R.string.bookmarks, R.drawable.ic_bookmarks_and_tracks, handlers::openBookmarks),
                new Row(R.string.download_maps, R.drawable.ic_download, downloadsBadge, handlers::downloadMaps),
                // The adapter shows the running state of the recorder on this row itself.
                new Row(R.string.start_track_recording, R.drawable.ic_track_recording_off, -1,
                        handlers::toggleTrackRecording)));
    if (mapEditing)
      rows.add(new Row(R.string.placepage_add_place_button, R.drawable.ic_plus, handlers::addPlace));
    return toItems(List.of(rows), false);
  }

  @NonNull
  private static ArrayList<MenuBottomSheetItem> toItems(@NonNull List<List<Row>> groups, boolean dividerAboveFirst)
  {
    final ArrayList<MenuBottomSheetItem> items = new ArrayList<>();
    for (List<Row> group : groups)
      for (int i = 0; i < group.size(); ++i)
      {
        final Row row = group.get(i);
        // The main menu has the map styles above its first group, the sheet has nothing above it.
        items.add(new MenuBottomSheetItem(row.titleRes(), row.iconRes(), row.badgeCount(),
                                          i == 0 && (dividerAboveFirst || group != groups.get(0)), row.onClick()));
      }
    return items;
  }

  private record Row(@StringRes int titleRes, @DrawableRes int iconRes, int badgeCount,
                     @NonNull MenuBottomSheetItem.OnClickListener onClick)
  {
    Row(@StringRes int titleRes, @DrawableRes int iconRes, @NonNull MenuBottomSheetItem.OnClickListener onClick)
    {
      this(titleRes, iconRes, 0, onClick);
    }
  }

  private MainMenuItems() {}
}
