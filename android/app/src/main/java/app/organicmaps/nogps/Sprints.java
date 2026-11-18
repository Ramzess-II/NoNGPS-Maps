package app.organicmaps.nogps;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.StringRes;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import java.util.Locale;

/**
 * The texts of the timed runs from a standing start (0-100 km/h, quarter mile): the alert on the map, see
 * maplayer.SprintView, and the rows of the Box sheet.
 */
public final class Sprints
{
  // A result is shown on the map this long, a record longer.
  public static final long ALERT_MS = 5000;
  public static final long RECORD_MS = 8000;

  private Sprints() {}

  /**
   * Context.getString().
   */
  public interface Text
  {
    @NonNull
    String get(@StringRes int id, Object... args);
  }

  /**
   * The lines of the alert. A result that is not a record has the big line only.
   */
  public record Card(@NonNull String small, @NonNull String big, @NonNull String was, boolean record)
  {
  }

  @StringRes
  public static int titleText(@NonNull NoGps.SprintKind kind)
  {
    return kind == NoGps.SprintKind.TO_100 ? R.string.nogps_sprint_to100 : R.string.nogps_sprint_quarter_mile;
  }

  public static long alertMs(boolean record)
  {
    return record ? RECORD_MS : ALERT_MS;
  }

  /**
   * Seconds in the format of the locale, e.g. "8.4".
   */
  @NonNull
  public static String secondsNumber(double sec, int decimals)
  {
    return String.format(Locale.getDefault(), "%." + decimals + "f", sec);
  }

  @NonNull
  public static String secondsText(@NonNull Text text, double sec, int decimals)
  {
    return text.get(R.string.nogps_sprint_seconds, secondsNumber(sec, decimals));
  }

  /**
   * The alert for the result in the status of Event.SPRINT_MEASURED.
   */
  @NonNull
  public static Card card(@NonNull Text text, @NonNull NoGps.Status status)
  {
    return card(text, status.getSprintKind(), status.sprintSec, status.sprintTrapKmh, status.sprintBestSec,
                status.sprintRecord);
  }

  @NonNull
  public static Card card(@NonNull Text text, @NonNull NoGps.SprintKind kind, double sec, int trapKmh, double bestSec,
                          boolean record)
  {
    final boolean quarter = kind == NoGps.SprintKind.QUARTER_MILE;
    final String title = text.get(titleText(kind));
    final String trap = text.get(R.string.nogps_speed_kmh, trapKmh);
    if (!record)
    {
      final String line = title + " · " + secondsText(text, sec, 1) + (quarter ? " · " + trap : "");
      return new Card("", line, "", false);
    }
    // The records that the same 1 decimal can't tell apart: both with 2.
    final int decimals = bestSec > 0 && secondsNumber(sec, 1).equals(secondsNumber(bestSec, 1)) ? 2 : 1;
    return new Card(quarter ? title + " · " + trap : title,
                    text.get(R.string.nogps_sprint_record) + " " + secondsText(text, sec, decimals),
                    bestSec > 0 ? text.get(R.string.nogps_sprint_was, secondsText(text, bestSec, decimals)) : "", true);
  }

  /**
   * A result of the list of the car: "8.43 s", for the quarter mile "15.21 s · 142 km/h".
   */
  @NonNull
  public static String resultText(@NonNull Text text, @NonNull NoGps.Sprint sprint)
  {
    final String sec = secondsText(text, sprint.sec, 2);
    return sprint.kind == NoGps.SprintKind.QUARTER_MILE
      ? sec + " · " + text.get(R.string.nogps_speed_kmh, sprint.trapKmh)
      : sec;
  }

  /**
   * The best result of the kind, the oldest one of equal times as the core keeps the record; null with none.
   */
  @Nullable
  public static NoGps.Sprint best(@NonNull NoGps.Sprint[] sprints, @NonNull NoGps.SprintKind kind)
  {
    NoGps.Sprint best = null;
    for (NoGps.Sprint sprint : sprints)
    {
      // The newest come first.
      if (sprint.kind == kind && (best == null || sprint.sec <= best.sec))
        best = sprint;
    }
    return best;
  }

  /**
   * The results of the kind in the order they come.
   */
  @NonNull
  public static NoGps.Sprint[] ofKind(@NonNull NoGps.Sprint[] sprints, @NonNull NoGps.SprintKind kind)
  {
    return java.util.Arrays.stream(sprints).filter(s -> s.kind == kind).toArray(NoGps.Sprint[] ::new);
  }

  /**
   * The best time of the kind for the row of the Box sheet, "—" with none.
   */
  @NonNull
  public static String bestText(@NonNull Text text, @NonNull NoGps.Sprint[] sprints, @NonNull NoGps.SprintKind kind)
  {
    final NoGps.Sprint best = best(sprints, kind);
    return best == null ? text.get(R.string.nogps_unknown) : resultText(text, best);
  }
}
