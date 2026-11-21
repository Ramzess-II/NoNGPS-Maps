package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import app.organicmaps.sdk.location.NoGps;
import java.lang.reflect.Constructor;
import java.util.List;
import java.util.Set;
import org.junit.Test;

public class CarMenuTest
{
  private static final long SEEN_MS = 1767225600000L;

  @Test
  public void oneCarAndAdd() throws ReflectiveOperationException
  {
    final NoGps.Car car = car("C47D", 0);
    final List<CarMenu.Entry> entries = CarMenu.entries(new NoGps.Car[] {car}, "C47D", false, id -> false, 3);
    assertEquals(2, entries.size());
    assertSame(car, entries.get(0).car());
    assertEquals(CarMenu.State.CURRENT, entries.get(0).state());
    assertTrue(entries.get(0).current());
    assertNull(entries.get(1).car());
    assertNull(entries.get(1).state());
  }

  @Test
  public void currentCarKeepsItsPlaceAndIsMarked() throws ReflectiveOperationException
  {
    final NoGps.Car[] cars = {car("A111", SEEN_MS), car("C47D", SEEN_MS), car("B222", 0)};
    final List<CarMenu.Entry> entries = CarMenu.entries(cars, "C47D", true, id -> false, 4);
    assertEquals(4, entries.size());
    assertSame(cars[0], entries.get(0).car());
    assertSame(cars[1], entries.get(1).car());
    assertSame(cars[2], entries.get(2).car());
    assertEquals(CarMenu.State.CONNECTED, entries.get(1).state());
    assertEquals(List.of(false, true, false, false), entries.stream().map(CarMenu.Entry::current).toList());
  }

  @Test
  public void states() throws ReflectiveOperationException
  {
    final NoGps.Car[] cars = {car("C47D", 0), car("B222", 0), car("A111", SEEN_MS), car("D444", 0)};
    final Set<String> nearby = Set.of("B222");
    final List<CarMenu.Entry> entries = CarMenu.entries(cars, "C47D", false, nearby::contains, 4);
    assertEquals(4, entries.size());
    assertEquals(CarMenu.State.CURRENT, entries.get(0).state());
    assertEquals(CarMenu.State.NEARBY, entries.get(1).state());
    assertEquals(CarMenu.State.LAST_SEEN, entries.get(2).state());
    // Its box was never heard: nothing is known about it.
    assertNull(entries.get(3).state());
    // The car driven now is never nearby, even with a box awake next to the phone.
    assertEquals(CarMenu.State.CONNECTED, CarMenu.entries(cars, "C47D", true, id -> true, 4).get(0).state());
  }

  @Test
  public void noAddAtTheLimit() throws ReflectiveOperationException
  {
    final NoGps.Car[] cars = {car("C47D", 0), car("B222", 0)};
    final List<CarMenu.Entry> entries = CarMenu.entries(cars, "C47D", false, id -> false, 2);
    assertEquals(2, entries.size());
    assertSame(cars[1], entries.get(1).car());
  }

  private static NoGps.Car car(String id, long lastSeenUnixMs) throws ReflectiveOperationException
  {
    final Constructor<NoGps.Car> constructor =
        NoGps.Car.class.getDeclaredConstructor(String.class, String.class, String.class, long.class);
    constructor.setAccessible(true);
    return constructor.newInstance(id, "", "", lastSeenUnixMs);
  }
}
