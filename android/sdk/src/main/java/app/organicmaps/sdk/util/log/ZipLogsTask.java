package app.organicmaps.sdk.util.log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

class ZipLogsTask implements Runnable
{
  private static final String TAG = ZipLogsTask.class.getSimpleName();

  @NonNull
  private final String mLogsPath;
  @NonNull
  private final String mZipPath;
  @Nullable
  private final LogsManager.OnZipCompletedListener mOnCompletedListener;
  // Only the files of these days, "yyyy-MM-dd", without the logcat. All files when null.
  @Nullable
  private final Collection<String> mDays;

  ZipLogsTask(@NonNull String logsPath, @NonNull String zipPath, @Nullable Collection<String> days,
              @NonNull LogsManager.OnZipCompletedListener onCompletedListener)
  {
    mLogsPath = logsPath;
    mZipPath = zipPath;
    mDays = days;
    mOnCompletedListener = onCompletedListener;
  }

  @Override
  public void run()
  {
    // Drain the queue so pending lines are on disk, capture the system logcat (a separate file),
    // then list the files while the file writer is locked, so no rotation races with the listing. The zip is made
    // after the lock is released: it takes seconds, and an ERROR line waits for the lock.
    Logger.flushFileLogs();
    if (mDays == null)
      saveSystemLogcat(mLogsPath);
    final File sourceFile = new File(mLogsPath);
    final List<File> files = new ArrayList<>();
    if (sourceFile.isDirectory())
      Logger.runExclusively(() -> files.addAll(listFiles(sourceFile)));
    final boolean success = sourceFile.isDirectory() && zipFiles(sourceFile, files, mZipPath);
    if (mOnCompletedListener != null)
      mOnCompletedListener.onCompleted(success, mZipPath);
  }

  @NonNull
  private List<File> listFiles(@NonNull File sourceFile)
  {
    return mDays == null ? LogFiles.all(sourceFile) : LogFiles.ofDays(sourceFile, mDays);
  }

  // The writer goes on while the files are read: a line appended after the entry is read is not in the zip, and a
  // file the rotation deleted meanwhile is left out.
  boolean zipFiles(@NonNull File sourceFile, @NonNull List<File> files, @NonNull String toLocation)
  {
    final String sourcePath = sourceFile.getPath();
    try (FileOutputStream dest = new FileOutputStream(toLocation, false);
         ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(dest)))
    {
      final int bufSize = 8 * 1024;
      final byte[] data = new byte[bufSize];
      for (File file : files)
      {
        // As the zip of iOS: unpacked into one folder, the zips of any phones and days make one tree.
        final String relativePath = file.getPath().substring(sourceFile.getPath().length() + 1);
        // Opened before the entry is put: a file the rotation deleted meanwhile leaves no empty entry.
        final FileInputStream fi;
        try
        {
          fi = new FileInputStream(file);
        }
        catch (FileNotFoundException e)
        {
          continue;
        }
        try (fi; BufferedInputStream origin = new BufferedInputStream(fi, bufSize))
        {
          out.putNextEntry(new ZipEntry("logs/" + relativePath.replace(File.separatorChar, '/')));
          int count;
          while ((count = origin.read(data, 0, bufSize)) != -1)
            out.write(data, 0, count);
        }
      }
    }
    catch (Exception e)
    {
      Logger.e(TAG, "Failed to zip file '" + sourcePath + "' to location '" + toLocation + "'", e);
      return false;
    }
    return true;
  }

  private void saveSystemLogcat(String path)
  {
    Process process;
    try
    {
      process = new ProcessBuilder("logcat", "-b", "main", "-b", "system", "-b", "crash", "-d", "-v", "threadtime")
                    .redirectErrorStream(true)
                    .start();
    }
    catch (IOException e)
    {
      Logger.e(TAG, "Failed to get system logcat", e);
      return;
    }

    // The one saved before the phones had their folders: it would be sent as of now.
    new File(path, "logcat.log").delete();
    // In the folder of the phone: unpacked together, the logcats of several phones don't replace each other.
    final File folder = new File(path, LogsManager.INSTANCE.getPhoneId());
    folder.mkdirs();
    final File file = new File(folder, "logcat.log");
    path = file.getPath();
    try (InputStreamReader reader = new InputStreamReader(process.getInputStream());
         FileWriter writer = new FileWriter(file))
    {
      writer.write(LogsManager.INSTANCE.getSystemInformation());
      char[] buffer = new char[10000];
      do
      {
        int n = reader.read(buffer, 0, buffer.length);
        if (n == -1)
          break;
        writer.write(buffer, 0, n);
      }
      while (true);

      final int exitCode = process.waitFor();
      if (exitCode != 0)
        Logger.e(TAG, "logcat finished with code " + exitCode);
    }
    catch (InterruptedException e)
    {
      Thread.currentThread().interrupt();
      Logger.e(TAG, "Interrupted while saving system logcat to " + path, e);
    }
    catch (Throwable e)
    {
      Logger.e(TAG, "Failed to save system logcat to " + path, e);
    }
  }
}
