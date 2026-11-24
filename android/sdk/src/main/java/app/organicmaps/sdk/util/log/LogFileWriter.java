package app.organicmaps.sdk.util.log;

import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.LongSupplier;

/// The log file of a launch or a drive, written by a thread of its own, see Logger.
final class LogFileWriter
{
  /// What the writer takes from the app: the phone id and the head of a new file.
  interface FileInfo
  {
    @NonNull
    String phoneId();
    /// The lines a new file begins with.
    @NonNull
    String header(@NonNull String fileName);
  }

  private static final class LogEntry
  {
    @Nullable
    final String mLogsFolder;
    @NonNull
    private final String mData;
    @Nullable
    private final CountDownLatch mFlushLatch;
    // How many times the file was switched when the line was logged: it goes to the file of that switch.
    private final int mStartFileSeq;

    private LogEntry(@NonNull String logsFolder, @NonNull String data, int startFileSeq)
    {
      mLogsFolder = logsFolder;
      mData = data;
      mFlushLatch = null;
      mStartFileSeq = startFileSeq;
    }

    private LogEntry(@NonNull CountDownLatch flushLatch)
    {
      mLogsFolder = null;
      mData = "";
      mFlushLatch = flushLatch;
      mStartFileSeq = 0;
    }

    boolean isFlush()
    {
      return mFlushLatch != null;
    }
  }

  private static final String TAG = Logger.class.getSimpleName();
  private static final int QUEUE_CAPACITY = 4096;
  private static final int MAX_BATCH_SIZE = 256;
  private static final int FLUSH_TIMEOUT_SECONDS = 2;
  // Opening a file walks the whole log tree to keep it under the limit, so a failure is not retried at once.
  private static final long OPEN_RETRY_MS = 5000;
  // A file that reaches it ends, the lines after go to a new file: a long session is not one huge file.
  private static final long MAX_FILE_SIZE = LogFiles.MAX_FILE_SIZE;

  @NonNull
  private final ArrayBlockingQueue<LogEntry> mQueue = new ArrayBlockingQueue<>(QUEUE_CAPACITY);
  @NonNull
  private final AtomicInteger mDroppedCount = new AtomicInteger();
  // How many times startFile() was called: every line carries the number it was logged at, so whoever writes it
  // puts it into the file it belongs to.
  @NonNull
  private final AtomicInteger mStartFileSeq = new AtomicInteger();
  @NonNull
  private final Object mWriteLock = new Object();
  @NonNull
  private final SimpleDateFormat mDateFormat = new SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US);
  @Nullable
  private BufferedWriter mWriter;
  @Nullable
  private String mFilePath;
  // When the file was started, its name: at the first line since the launch or since startFile().
  @Nullable
  private Date mStarted;
  // The file under the logs folder, see LogFiles.fileName().
  @NonNull
  private String mFileName = "";
  // The first moment of the next day: a line written at it or later goes on in the folder of that day.
  private long mDayEndMs;
  // When a failed open may be tried again, 0 when the last one worked.
  private long mRetryOpenMs;
  // The size of the open file in chars, which are bytes for the ASCII log.
  private long mFileSize;
  // The number of the last applied file switch, guarded by mWriteLock.
  private int mAppliedStartFileSeq;

  @NonNull
  private final FileInfo mInfo;
  @NonNull
  private final LongSupplier mClock;

  LogFileWriter(@NonNull FileInfo info, @NonNull LongSupplier clock)
  {
    mInfo = info;
    mClock = clock;
    final Thread thread = new Thread(this::loop, "LoggerFileWriter");
    thread.setDaemon(true);
    thread.start();
  }

  void writeAsync(@NonNull String logsFolder, int level, @NonNull String data)
  {
    final LogEntry entry = new LogEntry(logsFolder, data, mStartFileSeq.get());
    if (mQueue.offer(entry))
      return;

    if (level >= Log.WARN)
    {
      if (mQueue.poll() != null)
        mDroppedCount.incrementAndGet();
      if (mQueue.offer(entry))
        return;
    }

    mDroppedCount.incrementAndGet();
  }

  void writeSync(@NonNull String logsFolder, @NonNull String data)
  {
    synchronized (mWriteLock)
    {
      // Error logs bypass the async queue so native CHECK/ASSERT messages are persisted
      // before aborting, even if older debug/info logs are still waiting in the queue. A file switch since the
      // last written line is the exception: the queued lines are written first, each one into the file it was
      // logged for, so this line goes to the new file and not to the one before it.
      final int startFileSeq = mStartFileSeq.get();
      if (startFileSeq > mAppliedStartFileSeq)
      {
        drainQueueLocked();
        applyStartFileLocked(startFileSeq);
      }
      writeDroppedCountLocked(logsFolder);
      writeLineLocked(logsFolder, data);
      flushLocked();
    }
  }

  void flush()
  {
    final CountDownLatch flushLatch = new CountDownLatch(1);
    final LogEntry flushEntry = new LogEntry(flushLatch);
    try
    {
      boolean enqueued = mQueue.offer(flushEntry);
      if (!enqueued)
      {
        if (mQueue.poll() != null)
          mDroppedCount.incrementAndGet();
        enqueued = mQueue.offer(flushEntry, FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS);
      }

      // Max wait time here is 2 * FLUSH_TIMEOUT_SECONDS = 4 seconds + time for flushLocked.
      // Still reasonable for UI Settings.
      if (!enqueued || !flushLatch.await(FLUSH_TIMEOUT_SECONDS, TimeUnit.SECONDS))
      {
        Log.e(TAG, "Timed out waiting for the file logger flush request");
        synchronized (mWriteLock)
        {
          flushLocked();
        }
      }
    }
    catch (InterruptedException e)
    {
      Thread.currentThread().interrupt();
      Log.e(TAG, "Interrupted while flushing file logs", e);
    }
  }

  void close()
  {
    synchronized (mWriteLock)
    {
      mQueue.clear();
      closeWriterLocked();
    }
  }

  void startFile()
  {
    // Neither the write lock nor the queue: a drive starts on the UI thread, the lock may be held by a slow
    // write, and a full queue would drop the switch. Raising the number is enough: every line
    // logged after this carries it and opens the new file, whichever thread writes the line.
    mStartFileSeq.incrementAndGet();
  }

  void runExclusively(@NonNull Runnable action)
  {
    synchronized (mWriteLock)
    {
      flushLocked();
      action.run();
    }
  }

  private void loop()
  {
    while (true)
    {
      try
      {
        processEntry(mQueue.take());
        for (int i = 0; i < MAX_BATCH_SIZE; ++i)
        {
          final LogEntry entry = mQueue.poll();
          if (entry == null)
            break;
          processEntry(entry);
          if (entry.isFlush())
            break;
        }
        synchronized (mWriteLock)
        {
          flushLocked();
        }
      }
      catch (InterruptedException e)
      {
        Thread.currentThread().interrupt();
        return;
      }
    }
  }

  private void processEntry(@NonNull LogEntry entry)
  {
    synchronized (mWriteLock)
    {
      if (entry.isFlush())
      {
        flushLocked();
        entry.mFlushLatch.countDown();
        return;
      }

      if (entry.mLogsFolder == null)
        return;

      applyStartFileLocked(entry.mStartFileSeq);
      writeDroppedCountLocked(entry.mLogsFolder);
      writeLineLocked(entry.mLogsFolder, entry.mData);
    }
  }

  // The queued entries in their order, each into the file it was logged for.
  private void drainQueueLocked()
  {
    LogEntry entry;
    while ((entry = mQueue.poll()) != null)
      processEntry(entry);
  }

  // Switches the file if the line to write was logged after a switch that is not applied yet. A line logged
  // before it is not written back to the file before: the file switches forward only.
  private void applyStartFileLocked(int startFileSeq)
  {
    if (startFileSeq <= mAppliedStartFileSeq)
      return;

    startFileLocked();
    mAppliedStartFileSeq = startFileSeq;
  }

  private void writeDroppedCountLocked(@NonNull String logsFolder)
  {
    final int droppedCount = mDroppedCount.getAndSet(0);
    if (droppedCount == 0)
      return;

    writeLineLocked(logsFolder, "(LoggerFileWriter) W/" + TAG + ": Dropped " + droppedCount
                                    + " log lines because the file logger queue was full");
  }

  private void writeLineLocked(@NonNull String logsFolder, @NonNull String data)
  {
    final String line = mDateFormat.format(new Date(mClock.getAsLong())) + " " + data + "\n";
    try
    {
      ensureWriterLocked(logsFolder);
      if (mWriter == null)
        return;

      mWriter.write(line);
      mFileSize += line.length();
      // Like on iOS: the file that reached the limit ends, the next line opens a new one.
      if (mFileSize >= MAX_FILE_SIZE)
        startFileLocked();
    }
    catch (IOException e)
    {
      // Opening the file walks the whole tree to keep it under the limit: a full disk or a folder that can't be
      // made would do it for every line until the writer opens again.
      mRetryOpenMs = mClock.getAsLong() + OPEN_RETRY_MS;
      Log.e(TAG, "Failed to write to " + mFilePath + ": " + data, e);
      closeWriterLocked();
    }
  }

  private void ensureWriterLocked(@NonNull String logsFolder) throws IOException
  {
    final long now = mClock.getAsLong();
    if (mWriter == null && now < mRetryOpenMs)
      return;
    if (mStarted == null)
    {
      mStarted = new Date(now);
      mDayEndMs = 0;
    }
    if (now >= mDayEndMs)
    {
      final Calendar calendar = Calendar.getInstance();
      calendar.setTimeInMillis(now);
      calendar.set(Calendar.HOUR_OF_DAY, 0);
      calendar.set(Calendar.MINUTE, 0);
      calendar.set(Calendar.SECOND, 0);
      calendar.set(Calendar.MILLISECOND, 0);
      calendar.add(Calendar.DAY_OF_MONTH, 1);
      mDayEndMs = calendar.getTimeInMillis();
      mFileName = LogFiles.freeFileName(new File(logsFolder), mInfo.phoneId(), mStarted, new Date(now));
    }

    final File file = new File(logsFolder, mFileName);
    if (!file.getPath().equals(mFilePath))
      closeWriterLocked();
    if (mWriter != null)
      return;

    final boolean isNewFile = file.length() == 0;
    if (isNewFile)
    {
      // Before the folder of the file is made: it is empty yet.
      LogFiles.deleteOldest(new File(logsFolder), LogFiles.MAX_TOTAL_SIZE);
      final File folder = file.getParentFile();
      if (folder != null && !folder.isDirectory() && !folder.mkdirs())
        throw new IOException("Can't create the folder " + folder.getPath());
    }

    mWriter = new BufferedWriter(new FileWriter(file, true));
    mFilePath = file.getPath();
    mRetryOpenMs = 0;
    mFileSize = file.length();

    if (isNewFile)
    {
      final String info = mInfo.header(mFileName);
      mWriter.write(info);
      mFileSize += info.length();
    }
  }

  private void startFileLocked()
  {
    closeWriterLocked();
    mStarted = null;
    // A new drive is worth an attempt even if the last open failed.
    mRetryOpenMs = 0;
  }

  private void flushLocked()
  {
    if (mWriter == null)
      return;

    try
    {
      mWriter.flush();
    }
    catch (IOException e)
    {
      Log.e(TAG, "Failed to flush file " + mFilePath, e);
      closeWriterLocked();
    }
  }

  private void closeWriterLocked()
  {
    if (mWriter == null)
      return;

    try
    {
      mWriter.close();
    }
    catch (IOException e)
    {
      Log.e(TAG, "Failed to close file " + mFilePath, e);
    }
    finally
    {
      mWriter = null;
      mFilePath = null;
    }
  }
}
