package app.organicmaps.nogps;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import app.organicmaps.sdk.util.log.Logger;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.text.ParseException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The flags of test drives: the moments the tester saw the car shown wrong, with the car position, a screenshot of
 * the app and maybe a voice note. They live in flags/ next to the logs: name.json, .png and .m4a, the name is the local
 * time yyyyMMdd-HHmmss. The settings send them by email, see NoGpsFlagsFragment.
 */
public final class NoGpsFlags
{
  private static final String TAG = NoGpsFlags.class.getSimpleName();
  // kFlagKeepDays: older flags are deleted at launch.
  static final int KEEP_DAYS = 7;
  // kFlagVoiceMaxS.
  static final int VOICE_MAX_S = 60;
  // kFlagMailMaxMB: a mail server may refuse bigger attachments, the user is warned.
  static final int MAIL_MAX_MB = 20;
  static final String JSON = ".json";
  static final String PNG = ".png";
  static final String VOICE = ".m4a";
  // Of a screenshot: the street names stay readable, the png stays small for the mail.
  private static final float SCREENSHOT_DENSITY = 2;
  // The file operations go one after another: the voice length is written after the flag.
  static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

  public static final class Flag
  {
    // The local time of the flag, yyyyMMdd-HHmmss: the name of its files.
    @NonNull
    final String name;
    // FLAG N in the log.
    final int number;
    // NaN without a position.
    final double lat;
    final double lon;
    // 0 without a voice note.
    int voiceS;
    boolean sent;

    public Flag(@NonNull String name, int number, double lat, double lon)
    {
      this.name = name;
      this.number = number;
      this.lat = lat;
      this.lon = lon;
    }
  }

  private NoGpsFlags() {}

  @NonNull
  public static String name(@NonNull Date date)
  {
    return new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(date);
  }

  @Nullable
  static Date date(@NonNull String name)
  {
    try
    {
      return new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).parse(name);
    }
    catch (ParseException e)
    {
      return null;
    }
  }

  // "dd-MM-yy" of the log file names, see LogFiles.
  @NonNull
  static String logDay(@NonNull String name)
  {
    if (name.length() < 8)
      return "";
    return name.substring(6, 8) + "-" + name.substring(4, 6) + "-" + name.substring(2, 4);
  }

  // "dd.MM.yy" for the mail subject.
  @NonNull
  static String mailDay(@NonNull String name)
  {
    return logDay(name).replace('-', '.');
  }

  // "HH:mm:ss" as the log tools take it.
  @NonNull
  public static String time(@NonNull String name)
  {
    if (name.length() < 15)
      return "";
    return name.substring(9, 11) + ":" + name.substring(11, 13) + ":" + name.substring(13, 15);
  }

  static boolean isExpired(@NonNull String name, @NonNull Date now)
  {
    final Date date = date(name);
    return date != null && now.getTime() - date.getTime() > KEEP_DAYS * 24L * 60 * 60 * 1000;
  }

  // "FLAG N HH:mm:ss lat,lon voice 12 s": the mail body has one per flag.
  @NonNull
  static String mailLine(@NonNull Flag flag)
  {
    final StringBuilder line = new StringBuilder("FLAG ").append(flag.number).append(' ').append(time(flag.name));
    if (Double.isNaN(flag.lat))
      line.append(" no position");
    else
      line.append(String.format(Locale.US, " %.5f,%.5f", flag.lat, flag.lon));
    if (flag.voiceS > 0)
      line.append(" voice ").append(flag.voiceS).append(" s");
    return line.toString();
  }

  @NonNull
  static String mailSubject(@NonNull String version, @NonNull List<Flag> flags)
  {
    final List<String> days = new ArrayList<>();
    for (Flag flag : oldestFirst(flags))
    {
      final String day = mailDay(flag.name);
      if (!days.contains(day))
        days.add(day);
    }
    return "[" + version + "] Flags " + join(days, ", ");
  }

  // Oldest first, as the mail lists them.
  @NonNull
  static String mailBody(@NonNull List<Flag> flags)
  {
    final List<String> lines = new ArrayList<>();
    for (Flag flag : oldestFirst(flags))
      lines.add(mailLine(flag));
    return join(lines, "\n");
  }

  // String.join() needs Android 8.
  @NonNull
  private static String join(@NonNull List<String> parts, @NonNull String separator)
  {
    final StringBuilder joined = new StringBuilder();
    for (String part : parts)
    {
      if (joined.length() > 0)
        joined.append(separator);
      joined.append(part);
    }
    return joined.toString();
  }

  @NonNull
  private static List<Flag> oldestFirst(@NonNull List<Flag> flags)
  {
    final List<Flag> sorted = new ArrayList<>(flags);
    Collections.sort(sorted, (a, b) -> a.name.compareTo(b.name));
    return sorted;
  }

  // Files

  @NonNull
  static File folder(@NonNull Context context)
  {
    // As the logs folder of LogsManager.
    final File dir = context.getExternalFilesDir(null);
    return new File(dir != null ? dir : context.getFilesDir(), "flags");
  }

  @NonNull
  static File file(@NonNull Context context, @NonNull String name, @NonNull String ext)
  {
    return new File(folder(context), name + ext);
  }

  // Newest first.
  @NonNull
  static List<Flag> load(@NonNull Context context)
  {
    final String[] files = folder(context).list();
    final List<Flag> flags = new ArrayList<>();
    if (files == null)
      return flags;
    Arrays.sort(files, Collections.reverseOrder());
    for (String file : files)
    {
      if (!file.endsWith(JSON))
        continue;
      final Flag flag = load(context, file.substring(0, file.length() - JSON.length()));
      if (flag != null)
        flags.add(flag);
    }
    return flags;
  }

  @Nullable
  private static Flag load(@NonNull Context context, @NonNull String name)
  {
    try
    {
      final File file = file(context, name, JSON);
      final byte[] data = new byte[(int) file.length()];
      try (DataInputStream in = new DataInputStream(new FileInputStream(file)))
      {
        in.readFully(data);
      }
      final JSONObject json = new JSONObject(new String(data, StandardCharsets.UTF_8));
      final Flag flag = new Flag(name, json.getInt("n"), json.optDouble("lat"), json.optDouble("lon"));
      flag.voiceS = json.optInt("voice_s");
      flag.sent = json.optBoolean("sent");
      return flag;
    }
    catch (IOException | JSONException e)
    {
      Logger.e(TAG, "Failed to read flag " + name, e);
      return null;
    }
  }

  private static void save(@NonNull Context context, @NonNull Flag flag)
  {
    try
    {
      final JSONObject json = new JSONObject().put("n", flag.number).put("voice_s", flag.voiceS).put("sent", flag.sent);
      if (!Double.isNaN(flag.lat))
        json.put("lat", flag.lat).put("lon", flag.lon);
      // noinspection ResultOfMethodCallIgnored
      folder(context).mkdirs();
      try (FileOutputStream out = new FileOutputStream(file(context, flag.name, JSON)))
      {
        out.write(json.toString().getBytes(StandardCharsets.UTF_8));
      }
    }
    catch (IOException | JSONException e)
    {
      Logger.e(TAG, "Failed to save flag " + flag.name, e);
    }
  }

  interface Change
  {
    void apply(@NonNull Flag flag);
  }

  // On EXECUTOR.
  static void update(@NonNull Context context, @NonNull String name, @NonNull Change change)
  {
    final Flag flag = load(context, name);
    if (flag == null)
      return;
    change.apply(flag);
    save(context, flag);
  }

  // Saves a new flag on EXECUTOR.
  public static void add(@NonNull Context context, @NonNull Flag flag)
  {
    final Context app = context.getApplicationContext();
    EXECUTOR.execute(() -> save(app, flag));
  }

  // Saves the screenshot of a flag on EXECUTOR.
  public static void saveScreenshot(@NonNull Context context, @NonNull String name, @Nullable Bitmap screenshot)
  {
    if (screenshot == null)
      return;
    final Context app = context.getApplicationContext();
    EXECUTOR.execute(() -> {
      try (FileOutputStream out = new FileOutputStream(file(app, name, PNG)))
      {
        screenshot.compress(Bitmap.CompressFormat.PNG, 100, out);
      }
      catch (IOException e)
      {
        Logger.e(TAG, "Failed to save the screenshot of flag " + name, e);
      }
    });
  }

  public static void deleteExpired(@NonNull Context context)
  {
    final Context app = context.getApplicationContext();
    EXECUTOR.execute(() -> {
      final File[] files = folder(app).listFiles();
      if (files == null)
        return;
      final Date now = new Date();
      for (File file : files)
      {
        final String name = file.getName();
        final int dot = name.indexOf('.');
        if (isExpired(dot < 0 ? name : name.substring(0, dot), now) && !file.delete())
          Logger.e(TAG, "Failed to delete expired flag file " + name);
      }
    });
  }

  // The screenshot and the voice note of the flags.
  @NonNull
  static List<File> attachments(@NonNull Context context, @NonNull List<Flag> flags)
  {
    final List<File> files = new ArrayList<>();
    for (Flag flag : flags)
    {
      for (String ext : new String[] {PNG, VOICE})
      {
        final File file = file(context, flag.name, ext);
        if (file.exists())
          files.add(file);
      }
    }
    return files;
  }

  public interface ScreenshotListener
  {
    void onScreenshot(@Nullable Bitmap screenshot);
  }

  /**
   * The app as the tester sees it. The map is a SurfaceView: a copy of the window leaves its place transparent, the
   * map is copied on its own and put under the window.
   */
  public static void takeScreenshot(@NonNull Activity activity, @Nullable SurfaceView map,
                                    @NonNull ScreenshotListener listener)
  {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O)
    {
      listener.onScreenshot(null);
      return;
    }
    Screenshot.take(activity, map, listener);
  }

  @RequiresApi(Build.VERSION_CODES.O)
  private static final class Screenshot
  {
    static void take(@NonNull Activity activity, @Nullable SurfaceView map, @NonNull ScreenshotListener listener)
    {
      final View decor = activity.getWindow().getDecorView();
      if (decor.getWidth() == 0 || decor.getHeight() == 0)
      {
        listener.onScreenshot(null);
        return;
      }
      final Handler handler = new Handler(Looper.getMainLooper());
      final Bitmap window = Bitmap.createBitmap(decor.getWidth(), decor.getHeight(), Bitmap.Config.ARGB_8888);
      PixelCopy.request(activity.getWindow(), window, (windowResult) -> {
        if (windowResult != PixelCopy.SUCCESS)
        {
          Logger.e(TAG, "Failed to copy the window: " + windowResult);
          listener.onScreenshot(null);
          return;
        }
        if (map == null || map.getWidth() == 0 || map.getHeight() == 0 || !map.getHolder().getSurface().isValid())
        {
          listener.onScreenshot(scale(activity, window));
          return;
        }
        final Bitmap mapBitmap = Bitmap.createBitmap(map.getWidth(), map.getHeight(), Bitmap.Config.ARGB_8888);
        PixelCopy.request(map, mapBitmap, (mapResult) -> {
          if (mapResult != PixelCopy.SUCCESS)
          {
            Logger.e(TAG, "Failed to copy the map: " + mapResult);
            listener.onScreenshot(scale(activity, window));
            return;
          }
          final int[] place = new int[2];
          map.getLocationInWindow(place);
          final Bitmap screen = Bitmap.createBitmap(window.getWidth(), window.getHeight(), Bitmap.Config.ARGB_8888);
          final Canvas canvas = new Canvas(screen);
          canvas.drawBitmap(mapBitmap, place[0], place[1], null);
          canvas.drawBitmap(window, 0, 0, null);
          listener.onScreenshot(scale(activity, screen));
        }, handler);
      }, handler);
    }

    @NonNull
    private static Bitmap scale(@NonNull Context context, @NonNull Bitmap bitmap)
    {
      final float scale = SCREENSHOT_DENSITY / context.getResources().getDisplayMetrics().density;
      if (scale >= 1)
        return bitmap;
      return Bitmap.createScaledBitmap(bitmap, Math.round(bitmap.getWidth() * scale),
                                       Math.round(bitmap.getHeight() * scale), true);
    }
  }
}
