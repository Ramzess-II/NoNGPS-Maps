package app.organicmaps.nogps;

import androidx.annotation.NonNull;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;

/**
 * What the Profile screen shows for each car: the best time of each timed run.
 */
public final class Profile
{
  private Profile() {}

  public record Row(@NonNull String title, @NonNull String value)
  {
  }

  public record Group(@NonNull String carId, @NonNull String title, @NonNull List<Row> rows)
  {
  }

  /**
   * One group for each car in the order they were added: 0-100 km/h and quarter mile, each with the best time of the
   * car or "—" when the car has no run of that kind. No cars, no groups.
   */
  @NonNull
  public static List<Group> groups(@NonNull Sprints.Text text, @NonNull NoGps.Car[] cars,
                                   @NonNull Function<String, NoGps.Sprint[]> sprintsOfCar)
  {
    final List<Group> groups = new ArrayList<>(cars.length);
    for (NoGps.Car car : cars)
    {
      final NoGps.Sprint[] sprints = sprintsOfCar.apply(car.id);
      final List<Row> rows = new ArrayList<>(2);
      for (NoGps.SprintKind kind : new NoGps.SprintKind[] {NoGps.SprintKind.TO_100, NoGps.SprintKind.QUARTER_MILE})
        rows.add(new Row(text.get(Sprints.titleText(kind)), Sprints.bestText(text, sprints, kind)));
      final String title =
          car.name.isEmpty() ? text.get(app.organicmaps.sdk.R.string.nogps_car_default_name, car.id) : car.name;
      groups.add(new Group(car.id, title, rows));
    }
    return groups;
  }
}
