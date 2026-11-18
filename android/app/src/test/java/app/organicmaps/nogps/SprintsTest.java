package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;

import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps.Sprint;
import app.organicmaps.sdk.location.NoGps.SprintKind;
import java.lang.reflect.Constructor;
import java.util.Locale;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

public class SprintsTest
{
  private static final Sprints.Text TEXT = (id, args) ->
  {
    final String format;
    if (id == R.string.nogps_sprint_to100)
      format = "0–100 km/h";
    else if (id == R.string.nogps_sprint_quarter_mile)
      format = "¼ mile";
    else if (id == R.string.nogps_sprint_seconds)
      format = "%s s";
    else if (id == R.string.nogps_sprint_record)
      format = "New record!";
    else if (id == R.string.nogps_sprint_was)
      format = "Was %s";
    else if (id == R.string.nogps_speed_kmh)
      format = "%d km/h";
    else if (id == R.string.nogps_unknown)
      format = "—";
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
  public void resultThatIsNotRecordIsOneLine()
  {
    final Sprints.Card to100 = Sprints.card(TEXT, SprintKind.TO_100, 8.43, 0, 9.1, false);
    assertEquals(new Sprints.Card("", "0–100 km/h · 8.4 s", "", false), to100);
    final Sprints.Card quarter = Sprints.card(TEXT, SprintKind.QUARTER_MILE, 15.21, 142, 14.0, false);
    assertEquals(new Sprints.Card("", "¼ mile · 15.2 s · 142 km/h", "", false), quarter);
  }

  @Test
  public void recordWithBest()
  {
    final Sprints.Card to100 = Sprints.card(TEXT, SprintKind.TO_100, 8.43, 0, 9.1, true);
    assertEquals(new Sprints.Card("0–100 km/h", "New record! 8.4 s", "Was 9.1 s", true), to100);
    final Sprints.Card quarter = Sprints.card(TEXT, SprintKind.QUARTER_MILE, 15.21, 142, 15.8, true);
    assertEquals(new Sprints.Card("¼ mile · 142 km/h", "New record! 15.2 s", "Was 15.8 s", true), quarter);
  }

  @Test
  public void firstResultHasNoWas()
  {
    final Sprints.Card card = Sprints.card(TEXT, SprintKind.TO_100, 8.43, 0, 0, true);
    assertEquals(new Sprints.Card("0–100 km/h", "New record! 8.4 s", "", true), card);
  }

  // 8.43 and 8.38 are both "8.4": the record is shown with 2 decimals to tell them apart.
  @Test
  public void equalTextsGetTwoDecimals()
  {
    final Sprints.Card card = Sprints.card(TEXT, SprintKind.TO_100, 8.38, 0, 8.43, true);
    assertEquals("New record! 8.38 s", card.big());
    assertEquals("Was 8.43 s", card.was());
  }

  @Test
  public void secondsFollowTheLocale()
  {
    Locale.setDefault(Locale.GERMANY);
    assertEquals("8,4", Sprints.secondsNumber(8.43, 1));
    assertEquals("15,21", Sprints.secondsNumber(15.21, 2));
  }

  @Test
  public void bestOfKind() throws ReflectiveOperationException
  {
    // Newest first.
    final Sprint[] sprints = {sprint(SprintKind.QUARTER_MILE, 15.5, 140), sprint(SprintKind.TO_100, 8.9, 0),
                              sprint(SprintKind.QUARTER_MILE, 15.21, 142), sprint(SprintKind.TO_100, 8.9, 0),
                              sprint(SprintKind.QUARTER_MILE, 16.0, 135)};
    assertSame(sprints[2], Sprints.best(sprints, SprintKind.QUARTER_MILE));
    // The oldest of equal times: a run as fast is not a record.
    assertSame(sprints[3], Sprints.best(sprints, SprintKind.TO_100));
    assertEquals(3, Sprints.ofKind(sprints, SprintKind.QUARTER_MILE).length);
    assertEquals("15.21 s · 142 km/h", Sprints.bestText(TEXT, sprints, SprintKind.QUARTER_MILE));
    assertEquals("8.90 s", Sprints.bestText(TEXT, sprints, SprintKind.TO_100));
  }

  @Test
  public void noResults() throws ReflectiveOperationException
  {
    assertNull(Sprints.best(new Sprint[0], SprintKind.TO_100));
    assertEquals("—", Sprints.bestText(TEXT, new Sprint[0], SprintKind.TO_100));
    final Sprint[] onlyQuarter = {sprint(SprintKind.QUARTER_MILE, 15.2, 140)};
    assertEquals("—", Sprints.bestText(TEXT, onlyQuarter, SprintKind.TO_100));
    assertEquals(0, Sprints.ofKind(onlyQuarter, SprintKind.TO_100).length);
  }

  @Test
  public void recordsAreShownLonger()
  {
    assertEquals(5000, Sprints.alertMs(false));
    assertEquals(8000, Sprints.alertMs(true));
  }

  // The results are made by JNI only.
  private static Sprint sprint(SprintKind kind, double sec, int trapKmh) throws ReflectiveOperationException
  {
    final Constructor<Sprint> constructor =
        Sprint.class.getDeclaredConstructor(int.class, long.class, double.class, int.class);
    constructor.setAccessible(true);
    return constructor.newInstance(kind.ordinal(), 0L, sec, trapKmh);
  }
}
