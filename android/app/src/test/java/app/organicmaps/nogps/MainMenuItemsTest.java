package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;

import androidx.annotation.NonNull;
import app.organicmaps.R;
import app.organicmaps.util.bottomsheet.MenuBottomSheetItem;
import java.util.ArrayList;
import java.util.List;
import org.junit.Test;

public class MainMenuItemsTest
{
  /** Records which row was tapped, so the rows can be checked together with what they do. */
  private static class Taps implements MainMenuItems.Handlers
  {
    final List<String> calls = new ArrayList<>();

    @Override
    public void openProfile()
    {
      calls.add("profile");
    }

    @Override
    public void openSettings()
    {
      calls.add("settings");
    }

    @Override
    public void shareLocation()
    {
      calls.add("share");
    }

    @Override
    public void openBookmarks()
    {
      calls.add("bookmarks");
    }

    @Override
    public void downloadMaps()
    {
      calls.add("download");
    }

    @Override
    public void toggleTrackRecording()
    {
      calls.add("record");
    }

    @Override
    public void addPlace()
    {
      calls.add("addPlace");
    }

    @Override
    public void openHowItWorks()
    {
      calls.add("howItWorks");
    }

    @Override
    public void openAboutNoGps()
    {
      calls.add("aboutNoGps");
    }

    @Override
    public void openAboutOrganicMaps()
    {
      calls.add("aboutOrganicMaps");
    }

    @Override
    public void buyBox()
    {
      calls.add("buyBox");
    }

    @Override
    public void donate()
    {
      calls.add("donate");
    }
  }

  @NonNull
  private static List<Integer> titles(@NonNull List<MenuBottomSheetItem> items)
  {
    final List<Integer> titles = new ArrayList<>();
    for (MenuBottomSheetItem item : items)
      titles.add(item.titleRes);
    return titles;
  }

  /** The titles of the rows that draw a divider above them: the first row of every group. */
  @NonNull
  private static List<Integer> groupStarts(@NonNull List<MenuBottomSheetItem> items)
  {
    final List<Integer> starts = new ArrayList<>();
    for (MenuBottomSheetItem item : items)
      if (item.startsGroup)
        starts.add(item.titleRes);
    return starts;
  }

  @NonNull
  private static List<String> tapAll(@NonNull List<MenuBottomSheetItem> items, @NonNull Taps taps)
  {
    for (MenuBottomSheetItem item : items)
      item.onClickListener.onClick();
    return taps.calls;
  }

  @Test
  public void threeGroupsUnderTheMapStyles()
  {
    final List<MenuBottomSheetItem> items = MainMenuItems.create(true, true, 0, new Taps());
    assertEquals(List.of(R.string.nogps_menu_profile, R.string.settings, R.string.share_my_location, R.string.bookmarks,
                         R.string.download_maps, R.string.start_track_recording, R.string.placepage_add_place_button,
                         R.string.nogps_how_title, R.string.nogps_about_title, R.string.nogps_about_om_menu,
                         R.string.nogps_box_buy, R.string.donate),
                 titles(items));
    assertEquals(List.of(R.string.nogps_menu_profile, R.string.bookmarks, R.string.nogps_how_title),
                 groupStarts(items));
  }

  @Test
  public void everyRowOpensItsOwnScreen()
  {
    final Taps taps = new Taps();
    assertEquals(List.of("profile", "settings", "share", "bookmarks", "download", "record", "addPlace", "howItWorks",
                         "aboutNoGps", "aboutOrganicMaps", "buyBox", "donate"),
                 tapAll(MainMenuItems.create(true, true, 0, taps), taps));
  }

  @Test
  public void addPlaceOnlyWithMapEditing()
  {
    final List<MenuBottomSheetItem> items = MainMenuItems.create(false, true, 0, new Taps());
    assertEquals(
        List.of(R.string.nogps_menu_profile, R.string.settings, R.string.share_my_location, R.string.bookmarks,
                R.string.download_maps, R.string.start_track_recording, R.string.nogps_how_title,
                R.string.nogps_about_title, R.string.nogps_about_om_menu, R.string.nogps_box_buy, R.string.donate),
        titles(items));
    assertEquals(List.of(R.string.nogps_menu_profile, R.string.bookmarks, R.string.nogps_how_title),
                 groupStarts(items));
  }

  @Test
  public void donateOnlyWithADonateUrl()
  {
    final List<MenuBottomSheetItem> items = MainMenuItems.create(false, false, 0, new Taps());
    assertEquals(List.of(R.string.nogps_menu_profile, R.string.settings, R.string.share_my_location, R.string.bookmarks,
                         R.string.download_maps, R.string.start_track_recording, R.string.nogps_how_title,
                         R.string.nogps_about_title, R.string.nogps_about_om_menu, R.string.nogps_box_buy),
                 titles(items));
    assertEquals(List.of(R.string.nogps_menu_profile, R.string.bookmarks, R.string.nogps_how_title),
                 groupStarts(items));
  }

  @Test
  public void downloadMapsCarriesTheBadge()
  {
    final List<MenuBottomSheetItem> items = MainMenuItems.create(true, true, 7, new Taps());
    final MenuBottomSheetItem download = items.get(titles(items).indexOf(R.string.download_maps));
    assertEquals(7, download.badgeCount);
  }
}
