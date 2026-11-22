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
  private static final LogFileWriter FILE_WRITER = new LogFileWriter(new LogFileWriter.FileInfo() {
    @NonNull
    @Override
    public String phoneId()
    {
      return LogsManager.INSTANCE.getPhoneId();
    }

    @NonNull
    @Override
    public String header(@NonNull String fileName)
    {
      return LogsManager.INSTANCE.getLogFormatLine(fileName) + LogsManager.INSTANCE.getSystemInformation();
    }
  }, System::currentTimeMillis);

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
}
