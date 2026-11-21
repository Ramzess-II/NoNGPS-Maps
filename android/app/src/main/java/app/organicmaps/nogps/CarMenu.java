package app.organicmaps.nogps;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import app.organicmaps.sdk.location.NoGps;
import java.util.ArrayList;
import java.util.List;

/**
 * The entries of the drop-down of the car page: every car with its state, and Add a car while the user may add one.
 */
public final class CarMenu
{
  private CarMenu() {}

  /**
   * Under the name of a car in the drop-down. A car whose box was never heard has no state.
   */
  public enum State
  {
    /** The car driven now, its box connected. */
    CONNECTED,
    /** The car driven now, its box out of reach. */
    CURRENT,
    /** The box of another car is awake near the phone. */
    NEARBY,
    /** When its box was connected the last time, see NoGps.Car.lastSeenUnixMs. */
    LAST_SEEN,
  }

  /**
   * The box of a car other than the one driven now is awake near the phone.
   */
  public interface Nearby
  {
    boolean isNearby(@NonNull String carId);
  }

  /**
   * A car to drive, or Add a car with no car and no state.
   */
  public record Entry(@Nullable NoGps.Car car, @Nullable State state)
  {
    /**
     * The car driven now, marked in the drop-down.
     */
    public boolean current()
    {
      return state == State.CONNECTED || state == State.CURRENT;
    }
  }

  /**
   * The cars in the order they were added, the car driven now in its place, then Add a car under the limit.
   */
  @NonNull
  public static List<Entry> entries(@NonNull NoGps.Car[] cars, @NonNull String currentId, boolean connected,
                                    @NonNull Nearby nearby, int maxCars)
  {
    final List<Entry> entries = new ArrayList<>(cars.length + 1);
    for (NoGps.Car car : cars)
      entries.add(new Entry(car, state(car, currentId, connected, nearby)));
    if (cars.length < maxCars)
      entries.add(new Entry(null, null));
    return entries;
  }

  @Nullable
  private static State state(@NonNull NoGps.Car car, @NonNull String currentId, boolean connected,
                             @NonNull Nearby nearby)
  {
    if (car.id.equals(currentId))
      return connected ? State.CONNECTED : State.CURRENT;
    if (nearby.isNearby(car.id))
      return State.NEARBY;
    return car.lastSeenUnixMs > 0 ? State.LAST_SEEN : null;
  }
}
