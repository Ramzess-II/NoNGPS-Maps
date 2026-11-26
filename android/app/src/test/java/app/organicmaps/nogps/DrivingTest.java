package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps.DrivingRating;
import app.organicmaps.sdk.location.NoGps.SpeedingTrip;
import java.lang.reflect.Constructor;
import java.text.DateFormat;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import org.junit.Test;

public class DrivingTest
{
  private static final Sprints.Text TEXT = (id, args) ->
  {
    final String format;
    if (id == R.string.nogps_driving_score)
      format = "Score";
    else if (id == R.string.nogps_driving_distance)
      format = "Rated driving";
    else if (id == R.string.nogps_driving_km)
      format = "%d km";
    else if (id == R.string.nogps_driving_band1)
      format = "20–40";
    else if (id == R.string.nogps_driving_band2)
      format = "40–60";
    else if (id == R.string.nogps_driving_band3)
      format = "60+";
    else if (id == R.string.nogps_driving_not_enough)
      format = "Not enough: %d km";
    else if (id == R.string.nogps_driving_trip_detail)
      format = "%1$d km · %2$d / %3$d / %4$d";
    else
      throw new AssertionError(id);
    return String.format(Locale.US, format, args);
  };

  @Test
  public void notEnoughDrivingShowsNoRows() throws ReflectiveOperationException
  {
    assertTrue(Driving.rows(TEXT, rating(false, 100, 12, new int[] {0, 0, 0})).isEmpty());
    assertEquals("Not enough: 20 km", Driving.note(TEXT));
  }

  @Test
  public void scoreDistanceAndBands() throws ReflectiveOperationException
  {
    final List<Profile.Row> rows = Driving.rows(TEXT, rating(true, 85, 411.6, new int[] {3, 1, 0}));
    assertEquals(List.of(new Profile.Row("Score", "85"), new Profile.Row("Rated driving", "412 km"),
                         new Profile.Row("20–40", "3"), new Profile.Row("40–60", "1"), new Profile.Row("60+", "0")),
                 rows);
  }

  @Test
  public void tripRowHasDateDistanceEpisodesAndScore() throws ReflectiveOperationException
  {
    final DateFormat format = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, Locale.US);
    format.setTimeZone(TimeZone.getTimeZone("UTC"));
    final Constructor<SpeedingTrip> constructor =
        SpeedingTrip.class.getDeclaredConstructor(long.class, double.class, double.class, int.class, int[].class);
    constructor.setAccessible(true);
    final SpeedingTrip trip = constructor.newInstance(1_700_000_000_000L, 31.6, 40.0, 72, new int[] {2, 1, 0});
    final Profile.Row row = Driving.tripRow(TEXT, format, trip);
    assertEquals(format.format(new java.util.Date(1_700_000_000_000L)) + "\n32 km · 2 / 1 / 0", row.title());
    assertEquals("72", row.value());
  }

  // The rating is made by JNI only.
  private static DrivingRating rating(boolean enough, int score, double km, int[] bands)
      throws ReflectiveOperationException
  {
    final Constructor<DrivingRating> constructor = DrivingRating.class.getDeclaredConstructor(
        boolean.class, int.class, double.class, int[].class, SpeedingTrip[].class);
    constructor.setAccessible(true);
    return constructor.newInstance(enough, score, km, bands, new SpeedingTrip[] {});
  }
}
