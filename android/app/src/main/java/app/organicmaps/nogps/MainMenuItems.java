package app.organicmaps.nogps;

import androidx.annotation.DrawableRes;
import androidx.annotation.NonNull;
import androidx.annotation.StringRes;
import app.organicmaps.R;
import app.organicmaps.util.bottomsheet.MenuBottomSheetItem;
import java.util.ArrayList;
import java.util.List;

/**
 * The rows of the main menu sheet, in four groups: what the driver taps on a trip stays apart from what is set up
 * once. The map styles of the sheet header are the first group; the first row of every other group draws a divider
 * above it. Kept out of MwmActivity so the order can be tested.
 */
public final class MainMenuItems
{
  /** What the rows do. MwmActivity owns the screens, the list only orders them. */
  public interface Handlers
  {
    void openProfile();

    void openSettings();

    void shareLocation();

    void openBookmarks();

    void downloadMaps();

    void toggleTrackRecording();

    void addPlace();

    void openAboutNoGps();

    void openAboutOrganicMaps();

    void buyBox();

    void donate();
  }

  /**
   * @param mapEditing     a MAP_EDITING build: only there the user can add a place to OpenStreetMap
   * @param donate         a donate URL is configured
   * @param downloadsBadge how many maps wait for an update, 0 for no badge
   */
  @NonNull
  public static ArrayList<MenuBottomSheetItem> create(boolean mapEditing, boolean donate, int downloadsBadge,
                                                      @NonNull Handlers handlers)
  {
    final List<Row> setup =
        List.of(new Row(R.string.nogps_menu_profile, R.drawable.profile_generic, handlers::openProfile),
                new Row(R.string.settings, R.drawable.ic_settings, handlers::openSettings),
                new Row(R.string.share_my_location, R.drawable.ic_share, handlers::shareLocation));

    final List<Row> trip = new ArrayList<>(
        List.of(new Row(R.string.bookmarks, R.drawable.ic_bookmarks_and_tracks, handlers::openBookmarks),
                new Row(R.string.download_maps, R.drawable.ic_download, downloadsBadge, handlers::downloadMaps),
                // The adapter shows the running state of the recorder on this row itself.
                new Row(R.string.start_track_recording, R.drawable.ic_track_recording_off, -1,
                        handlers::toggleTrackRecording)));
    if (mapEditing)
      trip.add(new Row(R.string.placepage_add_place_button, R.drawable.ic_plus, handlers::addPlace));

    final List<Row> about = new ArrayList<>(
        List.of(new Row(R.string.nogps_about_title, R.drawable.ic_question_mark, handlers::openAboutNoGps),
                new Row(R.string.nogps_about_om_menu, R.drawable.ic_openstreetmap, handlers::openAboutOrganicMaps),
                new Row(R.string.nogps_box_buy, R.drawable.ic_nogps_box, handlers::buyBox)));
    if (donate)
      about.add(new Row(R.string.donate, R.drawable.ic_donate, handlers::donate));

    final ArrayList<MenuBottomSheetItem> items = new ArrayList<>();
    for (List<Row> group : List.of(setup, trip, about))
      for (int i = 0; i < group.size(); ++i)
      {
        final Row row = group.get(i);
        items.add(new MenuBottomSheetItem(row.titleRes(), row.iconRes(), row.badgeCount(), i == 0, row.onClick()));
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
