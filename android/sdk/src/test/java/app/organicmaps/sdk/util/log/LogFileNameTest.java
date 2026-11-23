package app.organicmaps.sdk.util.log;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Calendar;
import java.util.Collections;
import java.util.Date;
import java.util.GregorianCalendar;
import java.util.List;
import java.util.Random;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class LogFileNameTest
{
  @Rule
  public TemporaryFolder mFolder = new TemporaryFolder();

  @Test
  public void fileName_hasPhoneDayAndStartTime()
  {
    final Date started = new GregorianCalendar(2026, Calendar.NOVEMBER, 1, 23, 59, 7).getTime();
    assertEquals(path("Pixel_7-a3f9", "2026-11-01", "235907.log"), LogFiles.fileName("Pixel_7-a3f9", started, started));
  }

  @Test
  public void fileName_goesOnInTheFolderOfTheNextDay()
  {
    final Date started = new GregorianCalendar(2026, Calendar.NOVEMBER, 1, 23, 59, 7).getTime();
    final Date now = new GregorianCalendar(2026, Calendar.NOVEMBER, 2, 0, 0, 1).getTime();
    assertEquals(path("Pixel_7-a3f9", "2026-11-02", "235907.log"), LogFiles.fileName("Pixel_7-a3f9", started, now));
  }

  @Test
  public void freeFileName_takesTheNameWhileNoDriveHasWrittenIt() throws IOException
  {
    final Date started = new GregorianCalendar(2026, Calendar.NOVEMBER, 1, 23, 59, 7).getTime();
    final String name = path("Pixel_7-a3f9", "2026-11-01", "235907.log");
    assertEquals(name, LogFiles.freeFileName(mFolder.getRoot(), "Pixel_7-a3f9", started, started));
  }

  @Test
  public void freeFileName_givesASecondDriveOfTheSameSecondItsOwnFile() throws IOException
  {
    final Date started = new GregorianCalendar(2026, Calendar.NOVEMBER, 1, 23, 59, 7).getTime();
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "235907.log"), 10, 1);
    assertEquals(path("Pixel_7-a3f9", "2026-11-01", "235907-2.log"),
                 LogFiles.freeFileName(mFolder.getRoot(), "Pixel_7-a3f9", started, started));
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "235907-2.log"), 10, 1);
    assertEquals(path("Pixel_7-a3f9", "2026-11-01", "235907-3.log"),
                 LogFiles.freeFileName(mFolder.getRoot(), "Pixel_7-a3f9", started, started));
  }

  @Test
  public void freeFileName_takesTheNextDayFolderOfAFileThatGoesOn() throws IOException
  {
    final Date started = new GregorianCalendar(2026, Calendar.NOVEMBER, 1, 23, 59, 7).getTime();
    final Date now = new GregorianCalendar(2026, Calendar.NOVEMBER, 2, 0, 0, 1).getTime();
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "235907.log"), 10, 1);
    // The file of the day before does not take the name of the continuation in the new day's folder.
    assertEquals(path("Pixel_7-a3f9", "2026-11-02", "235907.log"),
                 LogFiles.freeFileName(mFolder.getRoot(), "Pixel_7-a3f9", started, now));
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
  public void ofDays_takesEveryFileAndPhoneOfTheDays() throws IOException
  {
    makeTree();
    assertEquals(Arrays.asList(path("Pixel_7-a3f9", "2026-11-02", "081500.log"),
                               path("Pixel_7-a3f9", "2026-11-02", "173000.log"),
                               path("SM_S918B-0b12", "2026-11-02", "090000.log")),
                 relative(LogFiles.ofDays(mFolder.getRoot(), Collections.singleton("2026-11-02"))));
    assertEquals(Arrays.asList(path("Pixel_7-a3f9", "2026-11-01", "235907.log"),
                               path("Pixel_7-a3f9", "2026-11-03", "070000.log")),
                 relative(LogFiles.ofDays(mFolder.getRoot(), Arrays.asList("2026-11-03", "2026-11-01"))));
    // A day before the tree: its files are not in a folder of a day.
    assertEquals(Collections.emptyList(), LogFiles.ofDays(mFolder.getRoot(), Collections.singleton("2026-10-31")));
  }

  @Test
  public void ofDays_takesTheFileATripGoesOnFrom() throws IOException
  {
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "235907.log"), 10, 1);
    makeFile(path("Pixel_7-a3f9", "2026-11-02", "235907.log"), 10, 1);
    makeFile(path("Pixel_7-a3f9", "2026-11-03", "235907.log"), 10, 1);
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "081500.log"), 10, 1);
    makeFile(path("Pixel_7-a3f9", "2026-11-02", "081500.log"), 10, 1);
    makeFile(path("SM_S918B-0b12", "2026-11-01", "235907.log"), 10, 1);
    // The trip started on the first and went on over two midnights: the day of its end takes its first file too.
    assertEquals(Arrays.asList(path("Pixel_7-a3f9", "2026-11-01", "235907.log"),
                               path("Pixel_7-a3f9", "2026-11-02", "235907.log"),
                               path("Pixel_7-a3f9", "2026-11-03", "235907.log")),
                 relative(LogFiles.ofDays(mFolder.getRoot(), Collections.singleton("2026-11-03"))));
    // The day it started on has no file of the days before: only its own.
    assertEquals(Arrays.asList(path("Pixel_7-a3f9", "2026-11-01", "081500.log"),
                               path("Pixel_7-a3f9", "2026-11-01", "235907.log"),
                               path("SM_S918B-0b12", "2026-11-01", "235907.log")),
                 relative(LogFiles.ofDays(mFolder.getRoot(), Collections.singleton("2026-11-01"))));
    // Over a month end.
    makeFile(path("Pixel_7-a3f9", "2026-10-31", "230000.log"), 10, 1);
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "230000.log"), 10, 1);
    assertTrue(relative(LogFiles.ofDays(mFolder.getRoot(), Collections.singleton("2026-11-01")))
                   .contains(path("Pixel_7-a3f9", "2026-10-31", "230000.log")));
  }

  @Test
  public void all_takesTheTreeAndTheFilesNamedAsBefore() throws IOException
  {
    makeTree();
    assertEquals(Arrays.asList(
                     path("Pixel_7-a3f9", "2026-11-01", "235907.log"), path("Pixel_7-a3f9", "2026-11-02", "081500.log"),
                     path("Pixel_7-a3f9", "2026-11-02", "173000.log"), path("Pixel_7-a3f9", "2026-11-02", "notes.txt"),
                     path("Pixel_7-a3f9", "2026-11-03", "070000.log"), path("Pixel_7-a3f9", "logcat.log"),
                     path("SM_S918B-0b12", "2026-11-02", "090000.log"), "log-31-10-26-Pixel_7-a3f9.log"),
                 relative(LogFiles.all(mFolder.getRoot())));
  }

  @Test
  public void deleteOldest_deletesOldestUntilUnderTheCap() throws IOException
  {
    // Made in this order, but aged differently: the file named as before the tree is the oldest, as after an update.
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "081500.log"), 40, 3000);
    makeFile("log-31-10-26-Pixel_7-a3f9.log", 30, 1000);
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "173000.log"), 30, 4000);
    makeFile(path("Pixel_7-a3f9", "2026-10-31", "120000.log"), 30, 2000);

    LogFiles.deleteOldest(mFolder.getRoot(), 100);
    assertFiles(path("Pixel_7-a3f9", "2026-10-31", "120000.log"), path("Pixel_7-a3f9", "2026-11-01", "081500.log"),
                path("Pixel_7-a3f9", "2026-11-01", "173000.log"));

    // The folder of the day is left empty: removed.
    LogFiles.deleteOldest(mFolder.getRoot(), 70);
    assertFiles(path("Pixel_7-a3f9", "2026-11-01", "081500.log"), path("Pixel_7-a3f9", "2026-11-01", "173000.log"));
    assertFalse(new File(mFolder.getRoot(), path("Pixel_7-a3f9", "2026-10-31")).exists());

    // The folder of the phone too.
    LogFiles.deleteOldest(mFolder.getRoot(), 0);
    assertEquals(0, mFolder.getRoot().list().length);
  }

  @Test
  public void deleteOldest_keepsFilesUnderTheCap() throws IOException
  {
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "081500.log"), 50, 2000);
    makeFile(path("SM_S918B-0b12", "2026-10-31", "120000.log"), 50, 1000);

    LogFiles.deleteOldest(mFolder.getRoot(), 100);
    assertFiles(path("Pixel_7-a3f9", "2026-11-01", "081500.log"), path("SM_S918B-0b12", "2026-10-31", "120000.log"));
  }

  // Two phones, three days, a file that is not a log and a file named as before the tree.
  private void makeTree() throws IOException
  {
    makeFile(path("Pixel_7-a3f9", "2026-11-02", "173000.log"), 1, 1000);
    makeFile(path("Pixel_7-a3f9", "2026-11-02", "081500.log"), 1, 1000);
    makeFile(path("Pixel_7-a3f9", "2026-11-02", "notes.txt"), 1, 1000);
    makeFile(path("Pixel_7-a3f9", "2026-11-01", "235907.log"), 1, 1000);
    makeFile(path("Pixel_7-a3f9", "2026-11-03", "070000.log"), 1, 1000);
    makeFile(path("Pixel_7-a3f9", "logcat.log"), 1, 1000);
    makeFile(path("SM_S918B-0b12", "2026-11-02", "090000.log"), 1, 1000);
    makeFile("log-31-10-26-Pixel_7-a3f9.log", 1, 1000);
  }

  private static String path(String... parts)
  {
    return String.join(File.separator, parts);
  }

  private List<String> relative(List<File> files)
  {
    final List<String> paths = new ArrayList<>();
    for (File file : files)
      paths.add(file.getPath().substring(mFolder.getRoot().getPath().length() + 1));
    return paths;
  }

  private void makeFile(String name, int size, long modifiedSeconds) throws IOException
  {
    final File file = new File(mFolder.getRoot(), name);
    assertTrue(file.getParentFile().isDirectory() || file.getParentFile().mkdirs());
    try (RandomAccessFile f = new RandomAccessFile(file, "rw"))
    {
      f.setLength(size);
    }
    assertTrue(file.setLastModified(modifiedSeconds * 1000));
  }

  private void assertFiles(String... names)
  {
    assertEquals(Arrays.asList(names), relative(LogFiles.all(mFolder.getRoot())));
  }
}
