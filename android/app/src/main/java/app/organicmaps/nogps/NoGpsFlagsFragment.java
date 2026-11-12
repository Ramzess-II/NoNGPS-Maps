package app.organicmaps.nogps;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.text.TextUtils;
import android.text.format.Formatter;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.CheckBox;
import android.widget.ImageView;
import android.widget.ListView;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import app.organicmaps.BuildConfig;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.sdk.util.concurrency.UiThread;
import app.organicmaps.sdk.util.log.Logger;
import app.organicmaps.sdk.util.log.LogsManager;
import app.organicmaps.util.SharingUtils;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The flags of the test drives by day, newest first, see NoGpsFlags. The tester ticks some and sends them by email
 * with the logs of their days. A tap plays the voice note of a flag.
 */
public class NoGpsFlagsFragment extends BaseMwmFragment
{
  private static final String TAG = NoGpsFlagsFragment.class.getSimpleName();
  private static final int THUMBNAIL_HEIGHT_DP = 64;

  // A day as "dd.MM.yy" or a flag.
  private final List<Object> mRows = new ArrayList<>();
  private final Set<String> mSelected = new HashSet<>();
  private final Map<String, Bitmap> mThumbnails = new HashMap<>();
  private final Adapter mAdapter = new Adapter();
  @Nullable
  private MediaPlayer mPlayer;
  private String mPlaying = "";
  private View mEmpty;
  private View mList;
  private View mSend;

  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View root = inflater.inflate(R.layout.fragment_nogps_flags, container, false);
    mEmpty = root.findViewById(R.id.empty);
    mSend = root.findViewById(R.id.send);
    mSend.setOnClickListener((v) -> send());
    final ListView list = root.findViewById(R.id.list);
    mList = list;
    list.setAdapter(mAdapter);
    list.setOnItemClickListener((parent, view, position, id) -> {
      if (!(mRows.get(position) instanceof NoGpsFlags.Flag flag))
        return;
      if (flag.voiceS > 0)
        play(flag.name);
      else
        toggle(flag.name);
    });
    return root;
  }

  @Override
  public void onResume()
  {
    super.onResume();
    reload();
  }

  @Override
  public void onPause()
  {
    stopPlaying();
    super.onPause();
  }

  private void reload()
  {
    final Context context = requireContext().getApplicationContext();
    // After the flags still being saved.
    NoGpsFlags.EXECUTOR.execute(() -> {
      final List<NoGpsFlags.Flag> flags = NoGpsFlags.load(context);
      UiThread.run(() -> {
        if (isAdded())
          setFlags(flags);
      });
    });
  }

  private void setFlags(@NonNull List<NoGpsFlags.Flag> flags)
  {
    mRows.clear();
    final Set<String> names = new HashSet<>();
    String day = "";
    for (NoGpsFlags.Flag flag : flags)
    {
      if (!NoGpsFlags.mailDay(flag.name).equals(day))
      {
        day = NoGpsFlags.mailDay(flag.name);
        mRows.add(day);
      }
      mRows.add(flag);
      names.add(flag.name);
    }
    mSelected.retainAll(names);
    mEmpty.setVisibility(flags.isEmpty() ? View.VISIBLE : View.GONE);
    mList.setVisibility(flags.isEmpty() ? View.GONE : View.VISIBLE);
    mSend.setEnabled(!mSelected.isEmpty());
    mAdapter.notifyDataSetChanged();
  }

  private void toggle(@NonNull String name)
  {
    if (!mSelected.remove(name))
      mSelected.add(name);
    mSend.setEnabled(!mSelected.isEmpty());
    mAdapter.notifyDataSetChanged();
  }

  // A second tap stops the voice.
  private void play(@NonNull String name)
  {
    final boolean again = mPlayer != null && mPlayer.isPlaying() && mPlaying.equals(name);
    stopPlaying();
    if (again)
      return;
    final MediaPlayer player = new MediaPlayer();
    try
    {
      player.setDataSource(NoGpsFlags.file(requireContext(), name, NoGpsFlags.VOICE).getPath());
      player.prepare();
      player.start();
    }
    catch (IOException | RuntimeException e)
    {
      Logger.e(TAG, "Failed to play the voice of flag " + name, e);
      player.release();
      return;
    }
    mPlayer = player;
    mPlaying = name;
  }

  private void stopPlaying()
  {
    if (mPlayer == null)
      return;
    mPlayer.release();
    mPlayer = null;
  }

  @Nullable
  private Bitmap thumbnail(@NonNull String name)
  {
    if (mThumbnails.containsKey(name))
      return mThumbnails.get(name);
    final String path = NoGpsFlags.file(requireContext(), name, NoGpsFlags.PNG).getPath();
    final BitmapFactory.Options bounds = new BitmapFactory.Options();
    bounds.inJustDecodeBounds = true;
    BitmapFactory.decodeFile(path, bounds);
    final BitmapFactory.Options options = new BitmapFactory.Options();
    final float height = THUMBNAIL_HEIGHT_DP * getResources().getDisplayMetrics().density;
    options.inSampleSize = Math.max(1, Integer.highestOneBit((int) (bounds.outHeight / height)));
    final Bitmap thumbnail = BitmapFactory.decodeFile(path, options);
    mThumbnails.put(name, thumbnail);
    return thumbnail;
  }

  // Send

  private void send()
  {
    final List<NoGpsFlags.Flag> flags = new ArrayList<>();
    final Set<String> days = new HashSet<>();
    for (Object row : mRows)
    {
      if (row instanceof NoGpsFlags.Flag flag && mSelected.contains(flag.name))
      {
        flags.add(flag);
        days.add(NoGpsFlags.logDay(flag.name));
      }
    }
    if (flags.isEmpty())
      return;
    mSend.setEnabled(false);
    final Context context = requireContext().getApplicationContext();
    LogsManager.INSTANCE.zipLogs(days, (success, zipPath) -> UiThread.run(() -> {
      if (!isAdded())
        return;
      mSend.setEnabled(true);
      final List<File> files = NoGpsFlags.attachments(context, flags);
      if (success && zipPath != null)
        files.add(new File(zipPath));
      confirmSize(files, () -> compose(flags, files));
    }));
  }

  // A mail server may refuse big attachments.
  private void confirmSize(@NonNull List<File> files, @NonNull Runnable send)
  {
    long size = 0;
    for (File file : files)
      size += file.length();
    if (size <= NoGpsFlags.MAIL_MAX_MB * 1_000_000L)
    {
      send.run();
      return;
    }
    new MaterialAlertDialogBuilder(requireActivity(), R.style.MwmTheme_AlertDialog)
        .setMessage(getString(R.string.nogps_flags_too_big, Formatter.formatShortFileSize(requireContext(), size),
                              NoGpsFlags.MAIL_MAX_MB))
        .setNegativeButton(R.string.cancel, null)
        .setPositiveButton(R.string.nogps_flags_send, (dialog, which) -> send.run())
        .show();
  }

  // The mail app gives no result: the flags are marked sent once it opens.
  private void compose(@NonNull List<NoGpsFlags.Flag> flags, @NonNull List<File> files)
  {
    final Context context = requireContext();
    SharingUtils.sendFiles(context, BuildConfig.SUPPORT_MAIL, NoGpsFlags.mailSubject(BuildConfig.VERSION_NAME, flags),
                           NoGpsFlags.mailBody(flags), files);
    final Context app = context.getApplicationContext();
    NoGpsFlags.EXECUTOR.execute(() -> {
      for (NoGpsFlags.Flag flag : flags)
        NoGpsFlags.update(app, flag.name, (saved) -> saved.sent = true);
    });
  }

  private class Adapter extends BaseAdapter
  {
    private static final int DAY = 0;
    private static final int FLAG = 1;

    @Override
    public int getCount()
    {
      return mRows.size();
    }

    @Override
    public Object getItem(int position)
    {
      return mRows.get(position);
    }

    @Override
    public long getItemId(int position)
    {
      return position;
    }

    @Override
    public int getViewTypeCount()
    {
      return 2;
    }

    @Override
    public int getItemViewType(int position)
    {
      return mRows.get(position) instanceof NoGpsFlags.Flag ? FLAG : DAY;
    }

    @Override
    public boolean isEnabled(int position)
    {
      return getItemViewType(position) == FLAG;
    }

    @Override
    public View getView(int position, @Nullable View view, @NonNull ViewGroup parent)
    {
      final LayoutInflater inflater = LayoutInflater.from(parent.getContext());
      if (!(mRows.get(position) instanceof NoGpsFlags.Flag flag))
      {
        final TextView day =
            view != null ? (TextView) view : (TextView) inflater.inflate(R.layout.item_nogps_flag_day, parent, false);
        day.setText((String) mRows.get(position));
        return day;
      }
      if (view == null)
        view = inflater.inflate(R.layout.item_nogps_flag, parent, false);
      ((TextView) view.findViewById(R.id.title)).setText("FLAG " + flag.number + " · " + NoGpsFlags.time(flag.name));
      final List<String> details = new ArrayList<>();
      if (flag.voiceS > 0)
        details.add(getString(R.string.nogps_flag_voice, flag.voiceS));
      if (flag.sent)
        details.add(getString(R.string.nogps_flag_sent));
      final TextView detailsView = view.findViewById(R.id.details);
      detailsView.setText(TextUtils.join(" · ", details));
      detailsView.setVisibility(details.isEmpty() ? View.GONE : View.VISIBLE);
      ((ImageView) view.findViewById(R.id.screenshot)).setImageBitmap(thumbnail(flag.name));
      final CheckBox check = view.findViewById(R.id.check);
      check.setOnCheckedChangeListener(null);
      check.setChecked(mSelected.contains(flag.name));
      check.setOnCheckedChangeListener((button, checked) -> toggle(flag.name));
      return view;
    }
  }
}
