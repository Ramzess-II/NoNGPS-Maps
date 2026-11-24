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
import java.util.Collections;
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
  // A file ends at the first line that brings it to MAX_FILE_SIZE (iOS: that would pass it): not shorter than this.
  private static final long SPLIT_SLACK = 100_000;

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

  /// The log files of the days, "yyyy-MM-dd", of every phone of the folder, and the files they go on from. A file
  /// that was started the day before has the same name in the folder of the previous day, so a trip that crossed
  /// midnight travels with the file it began in. A file that reached MAX_FILE_SIZE ended there and the trip went on
  /// in the next file of the phone, so it travels with it as well. The files come in the order of the tree.
  @NonNull
  static List<File> ofDays(@NonNull File folder, @NonNull Collection<String> days)
  {
    final List<File> files = new ArrayList<>();
    for (File phone : sorted(folder.listFiles(File::isDirectory)))
    {
      final List<File> all = new ArrayList<>();
      for (File day : sorted(phone.listFiles(File::isDirectory)))
        Collections.addAll(all, sorted(day.listFiles(file -> file.isFile() && file.getName().endsWith(".log"))));
      // A file goes on into a later one, but a full after-midnight part into an earlier one: repeat until no file
      // is added.
      final boolean[] taken = new boolean[all.size()];
      for (int i = 0; i < taken.length; ++i)
        taken[i] = days.contains(all.get(i).getParentFile().getName());
      boolean added = true;
      while (added)
      {
        added = false;
        for (int i = all.size() - 1; i >= 0; --i)
        {
          if (!taken[i] && goesOnInto(all, i, taken))
            added = taken[i] = true;
        }
      }
      for (int i = 0; i < taken.length; ++i)
      {
        if (taken[i])
          files.add(all.get(i));
      }
    }
    return files;
  }

  /// Whether the file goes on into a taken one. A drive that began in the same second as another is
  /// "<HHmmss>-2.log", but goes on as "<HHmmss>.log" after midnight, so the files of the next day are matched by
  /// their time without the suffix. Both drives of that second go on then.
  private static boolean goesOnInto(@NonNull List<File> all, int i, @NonNull boolean[] taken)
  {
    final File file = all.get(i);
    final int split = sizeSplitInto(all, i);
    if (split >= 0 && taken[split])
      return true;
    final String stem = startOf(file.getName());
    final String next = dayAfter(file.getParentFile().getName(), 1);
    if (next == null)
      return false;
    for (int j = i + 1; j < all.size(); ++j)
    {
      final File other = all.get(j);
      if (other.getParentFile().getName().equals(next) && startOf(other.getName()).equals(stem) && taken[j])
        return true;
    }
    return false;
  }

  /// The index of the file a full file goes on in, -1 when it is not full or has none. It is the next file of the
  /// phone in the tree that is not an after-midnight part of the day before, except for the after-midnight part of a
  /// trip (the previous day has a file of the same start time, or the file was last written before the time of its own
  /// name: the file of the day before may be deleted by the size cap): that part keeps the start time of the day
  /// before, and the file opened by the split is named by a time on its own day, so it is the first file of the day,
  /// and the next in the tree is another trip.
  private static int sizeSplitInto(@NonNull List<File> all, int i)
  {
    final File file = all.get(i);
    if (file.length() < MAX_FILE_SIZE - SPLIT_SLACK)
      return -1;
    final String day = file.getParentFile().getName();
    if (!isAfterMidnightPart(all, file))
    {
      // The after-midnight parts of the day before, named by a time of this day, are other trips: skip them.
      for (int j = i + 1; j < all.size(); ++j)
      {
        final File other = all.get(j);
        if (!other.getParentFile().getName().equals(day) || !isAfterMidnightPart(all, other))
          return j;
      }
      return -1;
    }
    for (int j = 0; j < i; ++j)
    {
      if (all.get(j).getParentFile().getName().equals(day))
        return j;
    }
    return -1;
  }

  /// Whether the file is a part that began the day before: the previous day has a file of the same start time, or the
  /// file was last written before the time of its own name.
  private static boolean isAfterMidnightPart(@NonNull List<File> all, @NonNull File file)
  {
    if (writtenBeforeItsName(file))
      return true;
    final String previous = dayAfter(file.getParentFile().getName(), -1);
    final String stem = startOf(file.getName());
    for (File other : all)
    {
      if (other.getParentFile().getName().equals(previous) && startOf(other.getName()).equals(stem))
        return true;
    }
    return false;
  }

  /// Whether the file was last written before the time its name says on its own day: it is a part that began the day
  /// before. A file can't be written before it was started.
  private static boolean writtenBeforeItsName(@NonNull File file)
  {
    try
    {
      final Date named = new SimpleDateFormat("yyyy-MM-dd HHmmss", Locale.US)
                             .parse(file.getParentFile().getName() + " " + startOf(file.getName()));
      return named != null && file.lastModified() < named.getTime();
    }
    catch (ParseException e)
    {
      return false;
    }
  }

  /// The time a drive started at, "HHmmss", of the name of its file: without the ".log" and the "-N" of a second
  /// drive of the same second.
  @NonNull
  private static String startOf(@NonNull String fileName)
  {
    return fileName.replaceFirst("(-\\d+)?\\.log$", "");
  }

  /// The day shifted by days from the folder name of a day, null when it is not a day.
  @Nullable
  private static String dayAfter(@NonNull String day, int days)
  {
    final SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
    // No daylight saving: a day is always 24 hours.
    format.setTimeZone(TimeZone.getTimeZone("UTC"));
    try
    {
      final Date date = format.parse(day);
      return date == null ? null : format.format(new Date(date.getTime() + days * 24 * 60 * 60 * 1000L));
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
