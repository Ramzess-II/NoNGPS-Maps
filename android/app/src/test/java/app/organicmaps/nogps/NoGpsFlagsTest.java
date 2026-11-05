package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Calendar;
import java.util.Date;
import java.util.GregorianCalendar;
import org.junit.Test;

public class NoGpsFlagsTest
{
  private static final long DAY_MS = 24L * 60 * 60 * 1000;

  @Test
  public void name_isLocalTime()
  {
    final Date date = new GregorianCalendar(2026, Calendar.NOVEMBER, 2, 9, 5, 7).getTime();
    assertEquals("20261102-090507", NoGpsFlags.name(date));
    assertEquals(date, NoGpsFlags.date("20261102-090507"));
    assertEquals("09:05:07", NoGpsFlags.time("20261102-090507"));
    assertEquals("02-11-26", NoGpsFlags.logDay("20261102-090507"));
    assertEquals("02.11.26", NoGpsFlags.mailDay("20261102-090507"));
  }

  @Test
  public void isExpired_afterSevenDays()
  {
    final long flag = NoGpsFlags.date("20261102-090507").getTime();
    assertFalse(NoGpsFlags.isExpired("20261102-090507", new Date(flag + 7 * DAY_MS - 1000)));
    assertTrue(NoGpsFlags.isExpired("20261102-090507", new Date(flag + 7 * DAY_MS + 1000)));
    // Not a flag of this app: left alone.
    assertFalse(NoGpsFlags.isExpired("notes", new Date(flag + 30 * DAY_MS)));
  }

  @Test
  public void mail_listsFlagsOldestFirst()
  {
    final NoGpsFlags.Flag voice = new NoGpsFlags.Flag("20261102-140509", 3, 50.450123, 30.523456);
    voice.voiceS = 12;
    final NoGpsFlags.Flag noPosition = new NoGpsFlags.Flag("20261101-235959", 7, Double.NaN, Double.NaN);
    final NoGpsFlags.Flag plain = new NoGpsFlags.Flag("20261102-090000", 1, 50.1, 30.2);
    final java.util.List<NoGpsFlags.Flag> flags = Arrays.asList(voice, noPosition, plain);

    assertEquals("[2026.11.01-74-Google] Flags 01.11.26, 02.11.26",
                 NoGpsFlags.mailSubject("2026.11.01-74-Google", flags));
    assertEquals("FLAG 7 23:59:59 no position\n"
                     + "FLAG 1 09:00:00 50.10000,30.20000\n"
                     + "FLAG 3 14:05:09 50.45012,30.52346 voice 12 s",
                 NoGpsFlags.mailBody(flags));
  }
}
