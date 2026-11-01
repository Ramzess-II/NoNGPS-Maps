package app.organicmaps.sdk.util.log;

import android.util.Log;
import androidx.annotation.NonNull;
import java.io.File;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Date;
import java.util.Locale;
import java.util.Random;

/// Names of the log files: one a day per phone, "log-dd-MM-yy-<phone>[.<part>].log".
final class LogFiles
{
  private static final String TAG = LogFiles.class.getSimpleName();

  // A day of driving, 20 hours and more at about 6.5 MB an hour: the log of a drive is analysed afterwards.
  static final long MAX_TOTAL_SIZE = 150_000_000;

  private LogFiles() {}

  @NonNull
  static String sanitizeModel(@NonNull String model)
  {
    return model.replaceAll("[^A-Za-z0-9]", "_");
  }

  @NonNull
  static String makePhoneId(@NonNull String model, @NonNull Random random)
  {
    return sanitizeModel(model) + String.format(Locale.US, "-%04x", random.nextInt(0x10000));
  }

  /// The day is taken in the default time zone.
  @NonNull
  static String fileName(@NonNull Date day, @NonNull String phoneId, int part)
  {
    final String name = "log-" + new SimpleDateFormat("dd-MM-yy", Locale.US).format(day) + "-" + phoneId;
    return part == 0 ? name + ".log" : name + "." + part + ".log";
  }

  /// Deletes the oldest files of the folder until all of them together take at most maxTotalSize.
  static void deleteOldest(@NonNull File folder, long maxTotalSize)
  {
    final File[] files = folder.listFiles(File::isFile);
    if (files == null)
      return;

    long total = 0;
    for (File file : files)
      total += file.length();

    Arrays.sort(files, Comparator.comparingLong(File::lastModified));
    for (int i = 0; i < files.length && total > maxTotalSize; ++i)
    {
      final long size = files[i].length();
      if (files[i].delete())
        total -= size;
      else
        Log.e(TAG, "Failed to delete old log file " + files[i].getPath());
    }
  }
}
