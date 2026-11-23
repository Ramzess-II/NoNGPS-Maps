package app.organicmaps.sdk.util.log;

import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.io.File;
import java.text.ParseException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.TimeZone;

/// The log files under the logs folder: "<phone>/<yyyy-MM-dd>/<HHmmss>.log", one per launch and per drive, so that
/// the folders of any phones and days merge into one tree.
final class LogFiles
{
  private static final String TAG = LogFiles.class.getSimpleName();

  // A day of driving, 20 hours and more at about 6.5 MB an hour: the log of a drive is analysed afterwards.
  static final long MAX_TOTAL_SIZE = 150_000_000;
  // About 4.5 hours at 6.5 MB an hour.
  static final long MAX_FILE_SIZE = 30_000_000;

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

  /// The path of a log file under the logs folder. A file is named by the time it was started at, and is in the
  /// folder of the day it is written on: over midnight it goes on in the next folder under the same name. Both are
  /// taken in the default time zone.
  @NonNull
  static String fileName(@NonNull String phoneId, @NonNull Date started, @NonNull Date now)
  {
    final String day = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now);
    final String name = new SimpleDateFormat("HHmmss", Locale.US).format(started);
    return phoneId + File.separator + day + File.separator + name + ".log";
  }

  /// The path of a log file that no drive has written yet: two drives started in the same second would share
  /// "<HHmmss>.log" and be read as one, so the second one gets "<HHmmss>-2.log".
  @NonNull
  static String freeFileName(@NonNull File logsFolder, @NonNull String phoneId, @NonNull Date started,
                             @NonNull Date now)
  {
    final String name = fileName(phoneId, started, now);
    if (!new File(logsFolder, name).exists())
      return name;
    final String base = name.substring(0, name.length() - ".log".length());
    // A file per second of a drive is far more than the app can start: the name is shared only if they all exist.
    for (int i = 2; i < 100; ++i)
    {
      final String next = base + "-" + i + ".log";
      if (!new File(logsFolder, next).exists())
        return next;
    }
    return name;
  }

  /// The log files of the days, "yyyy-MM-dd", of every phone of the folder, and the files they go on from: a file
  /// that was started the day before has the same name in the folder of the previous day, so a trip that crossed
  /// midnight travels with the file it began in. A trip whose file reached MAX_FILE_SIZE before midnight goes on
  /// under a new name, so the file with its CALIBRATION line is not taken. The files come in the order of the tree.
  @NonNull
  static List<File> ofDays(@NonNull File folder, @NonNull Collection<String> days)
  {
    final List<File> files = new ArrayList<>();
    for (File phone : sorted(folder.listFiles(File::isDirectory)))
    {
      for (File day : sorted(phone.listFiles(File::isDirectory)))
      {
        final String name = day.getName();
        for (File file : sorted(day.listFiles(file -> file.isFile() && file.getName().endsWith(".log"))))
        {
          if (days.contains(name) || goesOnInto(phone, name, file.getName(), days))
            files.add(file);
        }
      }
    }
    return files;
  }

  /// Whether the file goes on, over midnights, in the folder of one of the days.
  private static boolean goesOnInto(@NonNull File phone, @NonNull String day, @NonNull String fileName,
                                    @NonNull Collection<String> days)
  {
    for (String next = nextDay(day); next != null && new File(new File(phone, next), fileName).isFile();
         next = nextDay(next))
    {
      if (days.contains(next))
        return true;
    }
    return false;
  }

  /// The day after the folder name of a day, null when it is not a day.
  @Nullable
  private static String nextDay(@NonNull String day)
  {
    final SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
    // No daylight saving: a day is always 24 hours.
    format.setTimeZone(TimeZone.getTimeZone("UTC"));
    try
    {
      final Date date = format.parse(day);
      return date == null ? null : format.format(new Date(date.getTime() + 24 * 60 * 60 * 1000L));
    }
    catch (ParseException e)
    {
      return null;
    }
  }

  /// Every file of the folder and its subfolders: the files named as before the tree too.
  @NonNull
  static List<File> all(@NonNull File folder)
  {
    final List<File> files = new ArrayList<>();
    for (File file : sorted(folder.listFiles()))
    {
      if (file.isDirectory())
        files.addAll(all(file));
      else
        files.add(file);
    }
    return files;
  }

  /// Deletes the oldest files of the tree until all of them together take at most maxTotalSize, then the folders
  /// left empty.
  static void deleteOldest(@NonNull File folder, long maxTotalSize)
  {
    final List<File> files = all(folder);
    long total = 0;
    for (File file : files)
      total += file.length();

    files.sort(Comparator.comparingLong(File::lastModified));
    for (int i = 0; i < files.size() && total > maxTotalSize; ++i)
    {
      final long size = files.get(i).length();
      if (files.get(i).delete())
        total -= size;
      else
        Log.e(TAG, "Failed to delete old log file " + files.get(i).getPath());
    }
    deleteEmptyFolders(folder);
  }

  private static void deleteEmptyFolders(@NonNull File folder)
  {
    for (File subfolder : sorted(folder.listFiles(File::isDirectory)))
    {
      deleteEmptyFolders(subfolder);
      // Fails when the folder has files.
      subfolder.delete();
    }
  }

  @NonNull
  private static File[] sorted(@Nullable File[] files)
  {
    if (files == null)
      return new File[0];
    Arrays.sort(files);
    return files;
  }
}
