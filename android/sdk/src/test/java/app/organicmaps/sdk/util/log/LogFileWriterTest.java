package app.organicmaps.sdk.util.log;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import androidx.annotation.NonNull;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.GregorianCalendar;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class LogFileWriterTest
{
  private static final String PHONE = "Pixel_7-a3f9";
  private static final String HEADER = "HEAD\n";

  @Rule
  public TemporaryFolder mFolder = new TemporaryFolder();

  private final AtomicLong mNow = new AtomicLong();
  private LogFileWriter mWriter;
  private String mLogs;

  @Before
  public void setUp()
  {
    mNow.set(time(2026, Calendar.NOVEMBER, 1, 12, 0, 0));
    mLogs = mFolder.getRoot().getPath();
    mWriter = new LogFileWriter(new LogFileWriter.FileInfo() {
      @NonNull
      @Override
      public String phoneId()
      {
        return PHONE;
      }

      @NonNull
      @Override
      public String header(@NonNull String fileName)
      {
        return HEADER;
      }
    }, mNow::get);
  }

  @After
  public void tearDown()
  {
    mWriter.close();
  }

  @Test
  public void firstLine_opensAFileOfTheLaunchWithTheHeader() throws IOException
  {
    mWriter.writeSync(mLogs, "hello");
    assertEquals(List.of(path("2026-11-01", "120000.log")), files());
    final List<String> lines = lines(path("2026-11-01", "120000.log"));
    assertEquals("HEAD", lines.get(0));
    assertEquals(2, lines.size());
    assertTrue(lines.get(1), lines.get(1).endsWith(" hello"));
  }

  @Test
  public void nextLines_goToTheSameFileWithoutANewHeader() throws IOException
  {
    mWriter.writeSync(mLogs, "one");
    mNow.addAndGet(5000);
    mWriter.writeSync(mLogs, "two");
    assertEquals(List.of(path("2026-11-01", "120000.log")), files());
    assertEquals(3, lines(path("2026-11-01", "120000.log")).size());
  }

  @Test
  public void midnight_continuesTheFileInTheFolderOfTheNextDay() throws IOException
  {
    mNow.set(time(2026, Calendar.NOVEMBER, 1, 23, 59, 50));
    mWriter.writeSync(mLogs, "before");
    mNow.set(time(2026, Calendar.NOVEMBER, 1, 23, 59, 59) + 999);
    mWriter.writeSync(mLogs, "last of the day");
    mNow.set(time(2026, Calendar.NOVEMBER, 2, 0, 0, 0));
    mWriter.writeSync(mLogs, "after");
    mWriter.writeSync(mLogs, "after too");

    // The same name, the time of the start, in both folders.
    assertEquals(List.of(path("2026-11-01", "235950.log"), path("2026-11-02", "235950.log")), files());
    final List<String> first = lines(path("2026-11-01", "235950.log"));
    assertEquals(3, first.size());
    assertTrue(first.get(2).endsWith(" last of the day"));
    final List<String> second = lines(path("2026-11-02", "235950.log"));
    assertEquals(HEADER.trim(), second.get(0));
    assertEquals(3, second.size());
    assertTrue(second.get(1).endsWith(" after"));
    assertTrue(second.get(2).endsWith(" after too"));
  }

  @Test
  public void midnight_happensOncePerDay() throws IOException
  {
    mNow.set(time(2026, Calendar.NOVEMBER, 1, 23, 0, 0));
    mWriter.writeSync(mLogs, "a");
    mNow.set(time(2026, Calendar.NOVEMBER, 3, 1, 0, 0));
    mWriter.writeSync(mLogs, "b");
    // A day with no lines has no folder.
    assertEquals(List.of(path("2026-11-01", "230000.log"), path("2026-11-03", "230000.log")), files());
  }

  @Test
  public void startFile_putsTheLinesAfterItInANewFile() throws IOException
  {
    mWriter.writeSync(mLogs, "drive 1");
    mNow.addAndGet(3000);
    mWriter.startFile();
    // Not before the line queued after it: flush() is ordered with the queue.
    mWriter.flush();
    mWriter.writeSync(mLogs, "drive 2");

    assertEquals(List.of(path("2026-11-01", "120000.log"), path("2026-11-01", "120003.log")), files());
    assertEquals(2, lines(path("2026-11-01", "120000.log")).size());
    final List<String> second = lines(path("2026-11-01", "120003.log"));
    assertEquals(HEADER.trim(), second.get(0));
    assertTrue(second.get(1).endsWith(" drive 2"));
  }

  @Test
  public void startFile_keepsTheLinesQueuedBeforeItInTheFileBefore() throws IOException
  {
    mWriter.writeSync(mLogs, "opens the file");
    mWriter.writeAsync(mLogs, android.util.Log.INFO, "queued before");
    mNow.addAndGet(2000);
    mWriter.startFile();
    mWriter.writeAsync(mLogs, android.util.Log.INFO, "queued after");
    mWriter.flush();

    final List<String> first = lines(path("2026-11-01", "120000.log"));
    assertEquals(3, first.size());
    assertTrue(first.get(2).endsWith(" queued before"));
    final List<String> second = lines(path("2026-11-01", "120002.log"));
    assertEquals(2, second.size());
    assertTrue(second.get(1).endsWith(" queued after"));
  }

  @Test
  public void startFile_inTheSameSecondTakesAFreeName() throws IOException
  {
    mWriter.writeSync(mLogs, "drive 1");
    mWriter.startFile();
    mWriter.flush();
    mWriter.writeSync(mLogs, "drive 2");

    assertEquals(List.of(path("2026-11-01", "120000-2.log"), path("2026-11-01", "120000.log")), files());
    assertTrue(lines(path("2026-11-01", "120000.log")).get(1).endsWith(" drive 1"));
    assertTrue(lines(path("2026-11-01", "120000-2.log")).get(1).endsWith(" drive 2"));
  }

  @Test
  public void startFile_withoutLinesOpensNoFile()
  {
    mWriter.startFile();
    mWriter.flush();
    assertTrue(files().isEmpty());
  }

  @Test
  public void concurrentWrites_keepEveryLineWhole() throws Exception
  {
    final int threads = 8;
    final int perThread = 300;
    final CountDownLatch go = new CountDownLatch(1);
    final List<Thread> workers = new ArrayList<>();
    for (int t = 0; t < threads; ++t)
    {
      final int id = t;
      final Thread worker = new Thread(() -> {
        try
        {
          go.await();
        }
        catch (InterruptedException e)
        {
          return;
        }
        for (int i = 0; i < perThread; ++i)
        {
          // Both paths: the queue and the direct one of errors.
          if (i % 3 == 0)
            mWriter.writeSync(mLogs, "line " + id + " " + i + " end");
          else
            mWriter.writeAsync(mLogs, android.util.Log.INFO, "line " + id + " " + i + " end");
        }
      });
      workers.add(worker);
      worker.start();
    }
    go.countDown();
    for (Thread worker : workers)
      worker.join();
    mWriter.flush();

    final List<String> lines = lines(path("2026-11-01", "120000.log"));
    assertEquals(HEADER.trim(), lines.get(0));
    assertEquals(1 + threads * perThread, lines.size());
    final boolean[][] seen = new boolean[threads][perThread];
    for (String line : lines.subList(1, lines.size()))
    {
      // "MM-dd HH:mm:ss.SSS line <id> <i> end"
      final String[] parts = line.split(" ");
      assertEquals(line, 6, parts.length);
      assertEquals(line, "line", parts[2]);
      assertEquals(line, "end", parts[5]);
      final boolean[] mine = seen[Integer.parseInt(parts[3])];
      final int i = Integer.parseInt(parts[4]);
      assertFalse(line, mine[i]);
      mine[i] = true;
    }
  }

  @Test
  public void runExclusively_holdsOffTheWritersAndFlushesTheBuffer() throws Exception
  {
    mWriter.writeSync(mLogs, "before");
    final AtomicBoolean written = new AtomicBoolean();
    final AtomicBoolean sawFlushed = new AtomicBoolean();
    final CountDownLatch inside = new CountDownLatch(1);
    final Thread writer = new Thread(() -> {
      try
      {
        inside.await();
      }
      catch (InterruptedException e)
      {
        return;
      }
      mWriter.writeSync(mLogs, "during");
      written.set(true);
    });
    writer.start();

    mWriter.runExclusively(() -> {
      inside.countDown();
      try
      {
        // Long enough for the writer to be in its line if the lock did not hold it.
        Thread.sleep(300);
        sawFlushed.set(lines(path("2026-11-01", "120000.log")).size() == 2 && !written.get());
      }
      catch (Exception e)
      {
        throw new RuntimeException(e);
      }
    });
    writer.join(TimeUnit.SECONDS.toMillis(10));

    assertTrue(sawFlushed.get());
    assertTrue(written.get());
    assertEquals(3, lines(path("2026-11-01", "120000.log")).size());
  }

  @Test
  public void close_endsTheFileAndTheNextLineReopensIt() throws IOException
  {
    mWriter.writeSync(mLogs, "one");
    mWriter.close();
    mWriter.writeSync(mLogs, "two");
    assertEquals(List.of(path("2026-11-01", "120000.log")), files());
    // The file of the launch goes on, with no second header.
    assertEquals(3, lines(path("2026-11-01", "120000.log")).size());
  }

  private static long time(int year, int month, int day, int hour, int minute, int second)
  {
    return new GregorianCalendar(year, month, day, hour, minute, second).getTimeInMillis();
  }

  private static String path(String day, String name)
  {
    return PHONE + File.separator + day + File.separator + name;
  }

  @NonNull
  private List<String> lines(@NonNull String name) throws IOException
  {
    return Files.readAllLines(new File(mLogs, name).toPath(), StandardCharsets.UTF_8);
  }

  /// The log files of the folder by their paths in it, sorted.
  @NonNull
  private List<String> files()
  {
    final List<String> result = new ArrayList<>();
    collect(new File(mLogs), "", result);
    result.sort(null);
    return result;
  }

  private static void collect(File dir, String prefix, List<String> result)
  {
    final File[] children = dir.listFiles();
    if (children == null)
      return;
    for (File child : children)
    {
      final String name = prefix.isEmpty() ? child.getName() : prefix + File.separator + child.getName();
      if (child.isDirectory())
        collect(child, name, result);
      else
        result.add(name);
    }
  }
}
