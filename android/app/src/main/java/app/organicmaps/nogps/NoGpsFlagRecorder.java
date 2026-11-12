package app.organicmaps.nogps;

import android.content.Context;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.SystemClock;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import app.organicmaps.sdk.util.log.Logger;
import java.io.File;
import java.io.IOException;

/**
 * Records the voice note of a flag after a tap of the voice flag button, see NoGpsFlags.
 */
public final class NoGpsFlagRecorder
{
  private static final String TAG = NoGpsFlagRecorder.class.getSimpleName();

  @Nullable
  private MediaRecorder mRecorder;
  @Nullable
  private Context mContext;
  private String mName = "";
  private long mStart;
  @Nullable
  private Runnable mOnStop;

  /**
   * Called when a recording is over, at VOICE_MAX_S too.
   */
  public void setOnStop(@Nullable Runnable onStop)
  {
    mOnStop = onStop;
  }

  public boolean isRecording()
  {
    return mRecorder != null;
  }

  /**
   * Records to the flag up to VOICE_MAX_S. The app must have the microphone.
   */
  @SuppressWarnings("deprecation")
  public boolean start(@NonNull Context context, @NonNull String name)
  {
    stop();
    final File file = NoGpsFlags.file(context, name, NoGpsFlags.VOICE);
    // noinspection ResultOfMethodCallIgnored
    NoGpsFlags.folder(context).mkdirs();
    final MediaRecorder recorder =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? new MediaRecorder(context) : new MediaRecorder();
    try
    {
      recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
      recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
      recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
      recorder.setAudioChannels(1);
      recorder.setAudioSamplingRate(22050);
      recorder.setAudioEncodingBitRate(32000);
      recorder.setMaxDuration(NoGpsFlags.VOICE_MAX_S * 1000);
      recorder.setOutputFile(file.getPath());
      recorder.setOnInfoListener((r, what, extra) -> {
        if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED)
          stop();
      });
      recorder.prepare();
      recorder.start();
    }
    catch (IOException | RuntimeException e)
    {
      Logger.e(TAG, "Failed to record the voice of flag " + name, e);
      recorder.release();
      // noinspection ResultOfMethodCallIgnored
      file.delete();
      return false;
    }
    mRecorder = recorder;
    mContext = context.getApplicationContext();
    mName = name;
    mStart = SystemClock.elapsedRealtime();
    return true;
  }

  public void stop()
  {
    final MediaRecorder recorder = mRecorder;
    final Context context = mContext;
    if (recorder == null || context == null)
      return;
    mRecorder = null;
    final String name = mName;
    final long ms = Math.min(SystemClock.elapsedRealtime() - mStart, NoGpsFlags.VOICE_MAX_S * 1000L);
    final int seconds = Math.round(ms / 1000f);
    boolean recorded = true;
    try
    {
      recorder.stop();
    }
    catch (RuntimeException e)
    {
      // Nothing was recorded yet.
      recorded = false;
    }
    recorder.release();
    Logger.i(TAG, "FLAG voice " + name + " " + seconds + " s");
    if (mOnStop != null)
      mOnStop.run();
    final boolean kept = recorded && seconds > 0;
    NoGpsFlags.EXECUTOR.execute(() -> {
      // A second tap right after the first has nothing to hear.
      if (!kept)
      {
        // noinspection ResultOfMethodCallIgnored
        NoGpsFlags.file(context, name, NoGpsFlags.VOICE).delete();
        return;
      }
      NoGpsFlags.update(context, name, flag -> flag.voiceS = seconds);
    });
  }
}
