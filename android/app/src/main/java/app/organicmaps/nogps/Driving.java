package app.organicmaps.nogps;

import androidx.annotation.NonNull;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

/**
 * What the Profile screen shows of how the driver drives: the score by the speeding and the trips it comes from.
 */
public final class Driving
{
  // The rated driving the score is shown from, as SpeedingMeter::kScoreMinKm.
  public static final int MIN_KM = 20;

  private Driving() {}

  /**
   * The rows of the Driving section. Before there is enough rated driving the score is not shown, only the note.
   *
   * @return the rows, empty for the note: see {@link #note}.
   */
  @NonNull
  public static List<Profile.Row> rows(@NonNull Sprints.Text text, @NonNull NoGps.DrivingRating rating)
  {
    final List<Profile.Row> rows = new ArrayList<>(5);
    if (!rating.enough)
      return rows;
    rows.add(new Profile.Row(text.get(R.string.nogps_driving_score), String.valueOf(rating.score)));
    rows.add(new Profile.Row(text.get(R.string.nogps_driving_distance),
                             text.get(R.string.nogps_driving_km, Math.round(rating.ratedKm))));
    final int[] bands = {R.string.nogps_driving_band1, R.string.nogps_driving_band2, R.string.nogps_driving_band3};
    for (int i = 0; i < bands.length; ++i)
      rows.add(new Profile.Row(text.get(bands[i]), String.valueOf(rating.bandCounts[i])));
    return rows;
  }

  /**
   * The note under the section while the score is not shown.
   */
  @NonNull
  public static String note(@NonNull Sprints.Text text)
  {
    return text.get(R.string.nogps_driving_not_enough, MIN_KM);
  }

  /**
   * A trip of the list: the date and the rated driving with the episodes, then its score.
   */
  @NonNull
  public static Profile.Row tripRow(@NonNull Sprints.Text text, @NonNull DateFormat dateFormat,
                                    @NonNull NoGps.SpeedingTrip trip)
  {
    final String title = dateFormat.format(new Date(trip.unixTimeMs)) + "\n"
                       + text.get(R.string.nogps_driving_trip_detail, Math.round(trip.ratedKm), trip.bandCounts[0],
                                  trip.bandCounts[1], trip.bandCounts[2]);
    return new Profile.Row(title, String.valueOf(trip.score));
  }
}
