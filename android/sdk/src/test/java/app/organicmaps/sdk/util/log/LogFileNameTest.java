package app.organicmaps.sdk.util.log;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.Arrays;
import java.util.Calendar;
import java.util.GregorianCalendar;
import java.util.Random;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class LogFileNameTest
{
  @Rule
  public TemporaryFolder mFolder = new TemporaryFolder();

  @Test
  public void fileName_hasDayPhoneAndPart()
  {
    final GregorianCalendar day = new GregorianCalendar(2026, Calendar.NOVEMBER, 1, 23, 59);
    assertEquals("log-01-11-26-Pixel_7-a3f9.log", LogFiles.fileName(day.getTime(), "Pixel_7-a3f9", 0));
    assertEquals("log-01-11-26-Pixel_7-a3f9.2.log", LogFiles.fileName(day.getTime(), "Pixel_7-a3f9", 2));
  }

  @Test
  public void sanitizeModel_keepsOnlyLettersAndDigits()
  {
    assertEquals("Pixel_7", LogFiles.sanitizeModel("Pixel 7"));
    assertEquals("iPhone15_2", LogFiles.sanitizeModel("iPhone15,2"));
    assertEquals("SM_S918B", LogFiles.sanitizeModel("SM-S918B"));
  }

  @Test
  public void makePhoneId_addsFourHexDigits()
  {
    final String id = LogFiles.makePhoneId("SM-S918B", new Random(1));
    assertTrue(id, id.matches("SM_S918B-[0-9a-f]{4}"));
  }

  @Test
  public void deleteOldest_deletesOldestUntilUnderTheCap() throws IOException
  {
    // Made in this order, but aged differently: app.log is the oldest, as after an update.
    makeFile("log-01-11-26-Pixel_7-a3f9.log", 40, 3000);
    makeFile("app.log", 30, 1000);
    makeFile("log-01-11-26-Pixel_7-a3f9.1.log", 30, 4000);
    makeFile("log-31-10-26-Pixel_7-a3f9.log", 30, 2000);

    LogFiles.deleteOldest(mFolder.getRoot(), 100);
    assertFiles("log-01-11-26-Pixel_7-a3f9.1.log", "log-01-11-26-Pixel_7-a3f9.log", "log-31-10-26-Pixel_7-a3f9.log");

    LogFiles.deleteOldest(mFolder.getRoot(), 70);
    assertFiles("log-01-11-26-Pixel_7-a3f9.1.log", "log-01-11-26-Pixel_7-a3f9.log");
  }

  @Test
  public void deleteOldest_keepsFilesUnderTheCap() throws IOException
  {
    makeFile("log-01-11-26-Pixel_7-a3f9.log", 50, 2000);
    makeFile("log-31-10-26-Pixel_7-a3f9.log", 50, 1000);

    LogFiles.deleteOldest(mFolder.getRoot(), 100);
    assertFiles("log-01-11-26-Pixel_7-a3f9.log", "log-31-10-26-Pixel_7-a3f9.log");
  }

  private void makeFile(String name, int size, long modifiedSeconds) throws IOException
  {
    final File file = mFolder.newFile(name);
    try (RandomAccessFile f = new RandomAccessFile(file, "rw"))
    {
      f.setLength(size);
    }
    assertTrue(file.setLastModified(modifiedSeconds * 1000));
  }

  private void assertFiles(String... names)
  {
    final String[] left = mFolder.getRoot().list();
    Arrays.sort(left);
    assertEquals(Arrays.asList(names), Arrays.asList(left));
  }
}
