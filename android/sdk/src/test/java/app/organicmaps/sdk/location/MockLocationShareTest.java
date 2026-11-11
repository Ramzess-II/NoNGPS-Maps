package app.organicmaps.sdk.location;

import static app.organicmaps.sdk.location.MockLocationShare.Schedule.kShareProbeIntervalMs;
import static app.organicmaps.sdk.location.MockLocationShare.Schedule.kShareProbeMaxMs;
import static app.organicmaps.sdk.location.MockLocationShare.Schedule.kShareProbeMs;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.organicmaps.sdk.location.MockLocationShare.Schedule;
import app.organicmaps.sdk.location.MockLocationShare.State;
import org.junit.Test;

public class MockLocationShareTest
{
  private static NoGps.Status status(boolean manualMode, boolean gpsDisabled, float workingGpsAccuracyM)
  {
    final NoGps.Status status = new NoGps.Status();
    status.manualMode = manualMode;
    status.gpsDisabled = gpsDisabled;
    status.workingGpsAccuracyM = workingGpsAccuracyM;
    return status;
  }

  private static final NoGps.Status FOLLOWS_GPS = status(false, false, 5);
  private static final NoGps.Status MANUAL_NO_GPS = status(true, false, -1);
  private static final NoGps.Status MANUAL_GOOD_GPS = status(true, false, 10);
  private static final NoGps.Status GPS_TURNED_OFF = status(false, true, 5);

  @Test
  public void off_whileTheCoreFollowsGps()
  {
    final Schedule schedule = new Schedule();
    assertEquals(State.OFF, schedule.update(FOLLOWS_GPS, true, 0));
    assertEquals(State.OFF, schedule.update(FOLLOWS_GPS, true, kShareProbeIntervalMs * 3));
  }

  @Test
  public void sharesInManualMode_andStopsWhenGpsIsBack()
  {
    final Schedule schedule = new Schedule();
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, 1000));
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, 2000));
    assertEquals(State.OFF, schedule.update(FOLLOWS_GPS, true, 3000));
  }

  @Test
  public void pausesEveryMinuteForTenSeconds()
  {
    final Schedule schedule = new Schedule();
    final long start = 1000;
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, start));
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, start + kShareProbeIntervalMs - 1));
    final long probe = start + kShareProbeIntervalMs;
    assertEquals(State.PROBING, schedule.update(MANUAL_NO_GPS, true, probe));
    assertEquals(State.PROBING, schedule.update(MANUAL_NO_GPS, true, probe + kShareProbeMs - 1));
    final long share = probe + kShareProbeMs;
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, share));
    // The next minute counts from the end of the pause.
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, share + kShareProbeIntervalMs - 1));
    assertEquals(State.PROBING, schedule.update(MANUAL_NO_GPS, true, share + kShareProbeIntervalMs));
  }

  @Test
  public void pauseGoesOnWhileGoodGpsComes_upToItsLimit()
  {
    final Schedule schedule = new Schedule();
    schedule.update(MANUAL_NO_GPS, true, 0);
    final long probe = kShareProbeIntervalMs;
    assertEquals(State.PROBING, schedule.update(MANUAL_NO_GPS, true, probe));
    assertEquals(State.PROBING, schedule.update(MANUAL_GOOD_GPS, true, probe + kShareProbeMs));
    assertEquals(State.PROBING, schedule.update(MANUAL_GOOD_GPS, true, probe + kShareProbeMaxMs - 1));
    assertEquals(State.SHARING, schedule.update(MANUAL_GOOD_GPS, true, probe + kShareProbeMaxMs));
  }

  @Test
  public void pauseEndsWhenGoodGpsStops()
  {
    final Schedule schedule = new Schedule();
    schedule.update(MANUAL_NO_GPS, true, 0);
    final long probe = kShareProbeIntervalMs;
    schedule.update(MANUAL_NO_GPS, true, probe);
    assertEquals(State.PROBING, schedule.update(MANUAL_GOOD_GPS, true, probe + kShareProbeMs + 5000));
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, true, probe + kShareProbeMs + 6000));
  }

  @Test
  public void inaccurateGpsDoesNotExtendThePause()
  {
    final Schedule schedule = new Schedule();
    schedule.update(MANUAL_NO_GPS, true, 0);
    final long probe = kShareProbeIntervalMs;
    schedule.update(MANUAL_NO_GPS, true, probe);
    final NoGps.Status coarse = status(true, false, Schedule.kShareProbeGoodGpsAccuracyM + 1);
    assertEquals(State.SHARING, schedule.update(coarse, true, probe + kShareProbeMs));
  }

  @Test
  public void gpsBackInThePause_endsTheShare()
  {
    final Schedule schedule = new Schedule();
    schedule.update(MANUAL_NO_GPS, true, 0);
    schedule.update(MANUAL_NO_GPS, true, kShareProbeIntervalMs);
    assertEquals(State.OFF, schedule.update(FOLLOWS_GPS, true, kShareProbeIntervalMs + 15_000));
  }

  @Test
  public void neverPauses_withGpsTurnedOffByTheUser()
  {
    final Schedule schedule = new Schedule();
    for (long t = 0; t <= kShareProbeIntervalMs * 5; t += 1000)
      assertEquals(State.SHARING, schedule.update(GPS_TURNED_OFF, true, t));
    // Also in the manual mode.
    assertEquals(State.SHARING, schedule.update(status(true, true, -1), true, kShareProbeIntervalMs * 6));
  }

  // The system location is paused while the box follows the car in the background: GPS can't be heard.
  @Test
  public void neverPauses_whileGpsIsNotHeard()
  {
    final Schedule schedule = new Schedule();
    for (long t = 0; t <= kShareProbeIntervalMs * 3; t += 1000)
      assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, false, t));
    // Back in the foreground: the pause comes, the minute has passed.
    assertEquals(State.PROBING, schedule.update(MANUAL_NO_GPS, true, kShareProbeIntervalMs * 3 + 1000));
    // Gone to the background in the pause: the share goes on.
    assertEquals(State.SHARING, schedule.update(MANUAL_NO_GPS, false, kShareProbeIntervalMs * 3 + 2000));
  }

  @Test
  public void dropsMockFixes_onlyWhileSharing()
  {
    final Schedule schedule = new Schedule();
    assertFalse(schedule.dropsFix(true));
    schedule.update(MANUAL_NO_GPS, true, 0);
    assertTrue(schedule.dropsFix(true));
    assertFalse(schedule.dropsFix(false));
    // Late fixes of the share in the pause.
    assertEquals(State.PROBING, schedule.update(MANUAL_NO_GPS, true, kShareProbeIntervalMs));
    assertTrue(schedule.dropsFix(true));
    schedule.update(FOLLOWS_GPS, true, kShareProbeIntervalMs + 1000);
    assertFalse(schedule.dropsFix(true));
    schedule.update(MANUAL_NO_GPS, true, kShareProbeIntervalMs + 2000);
    schedule.reset();
    assertFalse(schedule.dropsFix(true));
  }
}
