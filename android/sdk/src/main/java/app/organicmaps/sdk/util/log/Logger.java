package app.organicmaps.sdk.util.log;

import android.util.Log;
import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import app.organicmaps.sdk.BuildConfig;
import app.organicmaps.sdk.util.Assert;
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

/// Thread-safe
public final class Logger
{
  private static final String TAG = Logger.class.getSimpleName();
  private static final String CORE_TAG = "OMcore";
  private static final LogFileWriter FILE_WRITER = new LogFileWriter();

  public static void v(String tag)
  {
    logJava(Log.VERBOSE, tag, "", null);
  }

  public static void v(String tag, String msg)
  {
    logJava(Log.VERBOSE, tag, msg, null);
  }

  public static void v(String tag, String msg, Throwable tr)
  {
    logJava(Log.VERBOSE, tag, msg, tr);
  }

  public static void d(String tag)
  {
    logJava(Log.DEBUG, tag, "", null);
  }

  public static void d(String tag, String msg)
  {
    logJava(Log.DEBUG, tag, msg, null);
  }

  public static void d(String tag, String msg, Throwable tr)
  {
    logJava(Log.DEBUG, tag, msg, tr);
  }

  public static void i(String tag)
  {
    logJava(Log.INFO, tag, "", null);
  }

  public static void i(String tag, String msg)
  {
    logJava(Log.INFO, tag, msg, null);
  }

  public static void i(String tag, String msg, Throwable tr)
  {
    logJava(Log.INFO, tag, msg, tr);
  }

  public static void w(String tag, String msg)
  {
    logJava(Log.WARN, tag, msg, null);
  }

  public static void w(String tag, String msg, Throwable tr)
  {
    logJava(Log.WARN, tag, msg, tr);
  }

  public static void e(String tag, String msg)
  {
    logJava(Log.ERROR, tag, msg, null);
  }

  public static void e(String tag, String msg, Throwable tr)
  {
    logJava(Log.ERROR, tag, msg, tr);
  }

  @NonNull
  private static String getSourcePoint()
  {
    final StackTraceElement[] stackTrace = new Throwable().getStackTrace();
    // getSourcePoint() -> logImpl() -> logJava() -> Logger.x() -> caller.
    final int callerFrame = 4;
    if (stackTrace.length <= callerFrame)
      return "Unknown";
    final StackTraceElement st = stackTrace[callerFrame];
    StringBuilder sb = new StringBuilder(80);
    final String fileName = st.getFileName();
    if (fileName != null)
    {
      sb.append(fileName);
      final int lineNumber = st.getLineNumber();
      if (lineNumber >= 0)
        sb.append(':').append(lineNumber);
      sb.append(' ');
    }
    sb.append(st.getMethodName()).append("()");
    return sb.toString();
  }

  private static void logJava(int level, @Nullable String tag, @NonNull String msg, @Nullable Throwable tr)
  {
    logImpl(level, tag, msg, tr, true /* addJavaSourcePoint */);
  }

  // Also called from JNI to proxy native code logging (with tag == null).
  @Keep
  private static void log(int level, @Nullable String tag, @NonNull String msg, @Nullable Throwable tr)
  {
    logImpl(level, tag, msg, tr, false /* addJavaSourcePoint */);
  }

  private static void logImpl(int level, @Nullable String tag, @NonNull String msg, @Nullable Throwable tr,
                              boolean addJavaSourcePoint)
  {
    final String logsFolder = LogsManager.INSTANCE.getEnabledLogsFolder();

    if (logsFolder != null || BuildConfig.DEBUG || level >= Log.INFO)
    {
      final StringBuilder sb = new StringBuilder(180);
      // Add source point info for file logging, debug builds and ERRORs if its not from core.
      if (addJavaSourcePoint && tag != null && (logsFolder != null || BuildConfig.DEBUG || level == Log.ERROR))
        sb.append(getSourcePoint()).append(": ");
      sb.append(msg);
      if (tr != null)
        sb.append('\n').append(Log.getStackTraceString(tr));
      if (tag == null)
        tag = CORE_TAG;

      final String threadName = "(" + Thread.currentThread().getName() + ") ";
      if (logsFolder == null || BuildConfig.DEBUG)
        Log.println(level, tag, threadName + sb.toString());

      if (logsFolder != null)
      {
        sb.insert(0, String.valueOf(getLevelChar(level)) + '/' + tag + ": ");
        final String data = threadName + sb.toString();
        if (level >= Log.ERROR)
          FILE_WRITER.writeSync(logsFolder, data);
        else
          FILE_WRITER.writeAsync(logsFolder, level, data);
      }
    }
  }

  private static char getLevelChar(int level)
  {
    switch (level)
    {
    case Log.VERBOSE: return 'V';
    case Log.DEBUG: return 'D';
    case Log.INFO: return 'I';
    case Log.WARN: return 'W';
    case Log.ERROR: return 'E';
    }
    Assert.always(false, "Unknown log level " + level);
    return '_';
  }

  static void flushFileLogs()
  {
    FILE_WRITER.flush();
  }

  static void closeFileLogs()
  {
    FILE_WRITER.close();
  }

  /// The lines logged after this go to a new file.
  static void startFile()
  {
    FILE_WRITER.startFile();
  }

  /// Runs the action while holding the file writer lock and with the buffer flushed to disk,
  /// so no log line is appended and no log file is switched or deleted concurrently.
  /// Used to safely read/zip the log files.
  static void runExclusively(@NonNull Runnable action)
  {
    FILE_WRITER.runExclusively(action);
  }

  private static class LogEntry
  {
    @Nullable
    final String mLogsFolder;
    @NonNull
    private final String mData;
    @Nullable
    private final CountDownLatch mFlushLatch;
    // Not a line: the lines after it go to a new file.
    private final boolean mStartsFile;

    private LogEntry(@NonNull String logsFolder, @NonNull String data)
    {
      mLogsFolder = logsFolder;
      mData = data;
      mFlushLatch = null;
      mStartsFile = false;
    }

    private LogEntry(@NonNull CountDownLatch flushLatch)
    {
      mLogsFolder = null;
      mData = "";
      mFlushLatch = flushLatch;
      mStartsFile = false;
    }

    private LogEntry()
    {
      mLogsFolder = null;
      mData = "";
      mFlushLatch = null;
      mStartsFile = true;
    }

    boolean isFlush()
    {
      return mFlushLatch != null;
    }
  }

  private static class LogFileWriter
  {
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

    LogFileWriter()
    {
      final Thread thread = new Thread(this::loop, "LoggerFileWriter");
      thread.setDaemon(true);
      thread.start();
    }

    void writeAsync(@NonNull String logsFolder, int level, @NonNull String data)
    {
      final LogEntry entry = new LogEntry(logsFolder, data);
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
        // before aborting, even if older debug/info logs are still waiting in the queue.
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
      // In the queue: the lines logged before it are of the file before.
      final LogEntry entry = new LogEntry();
      if (mQueue.offer(entry))
        return;
      if (mQueue.poll() != null)
        mDroppedCount.incrementAndGet();
      if (mQueue.offer(entry))
        return;
      synchronized (mWriteLock)
      {
        startFileLocked();
      }
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

        if (entry.mStartsFile)
        {
          startFileLocked();
          return;
        }

        if (entry.mLogsFolder == null)
          return;

        writeDroppedCountLocked(entry.mLogsFolder);
        writeLineLocked(entry.mLogsFolder, entry.mData);
      }
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
      final String line = mDateFormat.format(new Date()) + " " + data + "\n";
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
        mRetryOpenMs = System.currentTimeMillis() + OPEN_RETRY_MS;
        Log.e(TAG, "Failed to write to " + mFilePath + ": " + data, e);
        closeWriterLocked();
      }
    }

    private void ensureWriterLocked(@NonNull String logsFolder) throws IOException
    {
      final long now = System.currentTimeMillis();
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
        mFileName =
            LogFiles.freeFileName(new File(logsFolder), LogsManager.INSTANCE.getPhoneId(), mStarted, new Date(now));
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
        final String info = LogsManager.INSTANCE.getLogFormatLine(mFileName) + LogsManager.INSTANCE.getSystemInformation();
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
}
