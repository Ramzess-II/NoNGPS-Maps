package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps.Car;
import app.organicmaps.sdk.location.NoGps.Sprint;
import app.organicmaps.sdk.location.NoGps.SprintKind;
import java.lang.reflect.Constructor;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

public class ProfileTest
{
  private static final Sprint[] NONE = {};

  private static final Sprints.Text TEXT = (id, args) ->
  {
    final String format;
    if (id == R.string.nogps_sprint_to100)
      format = "0–100 km/h";
    else if (id == R.string.nogps_sprint_quarter_mile)
      format = "¼ mile";
    else if (id == R.string.nogps_sprint_seconds)
      format = "%s s";
    else if (id == R.string.nogps_speed_kmh)
      format = "%d km/h";
    else if (id == R.string.nogps_unknown)
      format = "—";
    else if (id == app.organicmaps.sdk.R.string.nogps_car_default_name)
      format = "Car %s";
    else
      throw new AssertionError(id);
    return String.format(Locale.US, format, args);
  };

  private Locale mLocale;

  @Before
  public void setUp()
  {
    mLocale = Locale.getDefault();
    Locale.setDefault(Locale.US);
  }

  @After
  public void tearDown()
  {
    Locale.setDefault(mLocale);
  }

  @Test
  public void noCarsNoGroups() throws ReflectiveOperationException
  {
    assertTrue(Profile.groups(TEXT, new Car[] {}, id -> NONE).isEmpty());
  }

  @Test
  public void carsInTheOrderTheyWereAdded() throws ReflectiveOperationException
  {
    final List<Profile.Group> groups =
        Profile.groups(TEXT, new Car[] {car("B222", ""), car("A111", "Mine")}, id -> NONE);
    assertEquals(List.of("B222", "A111"), groups.stream().map(Profile.Group::carId).toList());
    assertEquals(List.of("Car B222", "Mine"), groups.stream().map(Profile.Group::title).toList());
  }

  @Test
  public void carWithoutRunsHasUnknownInBothRows() throws ReflectiveOperationException
  {
    final Profile.Group group = Profile.groups(TEXT, new Car[] {car("C47D", "")}, id -> NONE).get(0);
    assertEquals(List.of(new Profile.Row("0–100 km/h", "—"), new Profile.Row("¼ mile", "—")), group.rows());
  }

  @Test
  public void bestOfSeveralRunsOfAKind() throws ReflectiveOperationException
  {
    // Newest first, as the core gives them.
    final Sprint[] runs = {sprint(SprintKind.TO_100, 9.5, 0), sprint(SprintKind.QUARTER_MILE, 15.21, 142),
                           sprint(SprintKind.TO_100, 8.4, 0), sprint(SprintKind.TO_100, 10, 0)};
    final Profile.Group group = Profile.groups(TEXT, new Car[] {car("C47D", "")}, id -> runs).get(0);
    assertEquals(List.of(new Profile.Row("0–100 km/h", "8.40 s"), new Profile.Row("¼ mile", "15.21 s · 142 km/h")),
                 group.rows());
  }

  @Test
  public void theRunsOfACarDoNotGoToAnother() throws ReflectiveOperationException
  {
    final Map<String, Sprint[]> runs = Map.of("A111", new Sprint[] {sprint(SprintKind.TO_100, 9, 0)});
    final List<Profile.Group> groups =
        Profile.groups(TEXT, new Car[] {car("A111", ""), car("B222", "")}, id -> runs.getOrDefault(id, NONE));
    assertEquals("9.00 s", groups.get(0).rows().get(0).value());
    assertEquals("—", groups.get(0).rows().get(1).value());
    assertEquals(List.of("—", "—"), groups.get(1).rows().stream().map(Profile.Row::value).toList());
  }

  // The cars and the results are made by JNI only.
  private static Car car(String id, String name) throws ReflectiveOperationException
  {
    final Constructor<Car> constructor =
        Car.class.getDeclaredConstructor(String.class, String.class, String.class, long.class);
    constructor.setAccessible(true);
    return constructor.newInstance(id, name, "", 0L);
  }

  private static Sprint sprint(SprintKind kind, double sec, int trapKmh) throws ReflectiveOperationException
  {
    final Constructor<Sprint> constructor =
        Sprint.class.getDeclaredConstructor(int.class, long.class, double.class, int.class);
    constructor.setAccessible(true);
    return constructor.newInstance(kind.ordinal(), 0L, sec, trapKmh);
  }
}
