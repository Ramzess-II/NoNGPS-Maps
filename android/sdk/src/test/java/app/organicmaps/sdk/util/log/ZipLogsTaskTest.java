package app.organicmaps.sdk.util.log;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.List;
import java.util.zip.ZipFile;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class ZipLogsTaskTest
{
  @Rule
  public TemporaryFolder mFolder = new TemporaryFolder();

  private static File write(File logs, String path, String text) throws IOException
  {
    final File file = new File(logs, path);
    file.getParentFile().mkdirs();
    try (FileOutputStream out = new FileOutputStream(file))
    {
      out.write(text.getBytes());
    }
    return file;
  }

  @Test
  public void zipFiles_skipsFileDeletedAfterListing() throws IOException
  {
    final File logs = mFolder.newFolder("logs");
    final File kept = write(logs, "p-0001/2026-11-01/100000.log", "kept");
    final File gone = write(logs, "p-0001/2026-11-01/090000.log", "gone");
    final List<File> listed = Arrays.asList(gone, kept);
    // The rotation deletes the oldest file while the zip is made without the writer lock.
    assertTrue(gone.delete());

    final File zip = new File(mFolder.getRoot(), "logs.zip");
    final ZipLogsTask task = new ZipLogsTask(logs.getPath(), zip.getPath(), null, (success, path) -> {});
    assertTrue(task.zipFiles(logs, listed, zip.getPath()));

    try (ZipFile zf = new ZipFile(zip))
    {
      assertEquals(1, zf.size());
      assertNotNull(zf.getEntry("logs/p-0001/2026-11-01/100000.log"));
    }
  }
}
