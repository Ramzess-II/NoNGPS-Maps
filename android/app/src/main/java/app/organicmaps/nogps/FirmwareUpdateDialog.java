package app.organicmaps.nogps;

import android.app.Dialog;
import android.content.DialogInterface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AlertDialog;
import androidx.fragment.app.DialogFragment;
import androidx.fragment.app.FragmentManager;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.progressindicator.LinearProgressIndicator;

/**
 * A modal window over the app while the sensor box takes a new firmware: the stage, the progress and, at the end,
 * the result. It reads everything from the status, so it is the same after the activity is recreated.
 */
public class FirmwareUpdateDialog extends DialogFragment
{
  private static final String TAG = FirmwareUpdateDialog.class.getSimpleName();
  private static final long UPDATE_INTERVAL_MS = 500;

  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mUpdater = new Runnable() {
    @Override
    public void run()
    {
      if (update())
        mHandler.postDelayed(this, UPDATE_INTERVAL_MS);
    }
  };

  private TextView mStage;
  private LinearProgressIndicator mProgress;
  private View mNote;

  /**
   * Opens the dialog if the update runs and it is not open yet. A start that the core refused leaves nothing to show.
   */
  public static void show(@NonNull FragmentManager manager)
  {
    if (isShown(manager) || manager.isStateSaved() || !BoxTexts.isUpdating(NoGps.getStatus().getFirmwareUpdate()))
      return;
    new FirmwareUpdateDialog().show(manager, TAG);
  }

  public static boolean isShown(@NonNull FragmentManager manager)
  {
    return manager.findFragmentByTag(TAG) != null;
  }

  @NonNull
  @Override
  public Dialog onCreateDialog(@Nullable Bundle savedInstanceState)
  {
    setCancelable(false);
    final View view = LayoutInflater.from(requireContext()).inflate(R.layout.dialog_nogps_firmware_update, null);
    mStage = view.findViewById(R.id.firmware_stage);
    mProgress = view.findViewById(R.id.firmware_progress);
    mNote = view.findViewById(R.id.firmware_note);
    // The listeners are set in onStart(): the dialog must not close on Cancel, the result comes in its place.
    return new MaterialAlertDialogBuilder(requireContext())
        .setTitle(R.string.nogps_firmware_title)
        .setView(view)
        .setNegativeButton(R.string.cancel, null)
        .setPositiveButton(R.string.ok, null)
        .create();
  }

  @Override
  public void onStart()
  {
    super.onStart();
    final AlertDialog dialog = (AlertDialog) requireDialog();
    dialog.getButton(DialogInterface.BUTTON_NEGATIVE).setOnClickListener(v -> {
      if (BoxTexts.canCancelFirmware(NoGps.getStatus()))
        NoGps.nativeCancelFirmwareUpdate();
      update();
    });
    dialog.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener(v -> dismiss());
    mHandler.post(mUpdater);
  }

  @Override
  public void onStop()
  {
    mHandler.removeCallbacks(mUpdater);
    super.onStop();
  }

  /**
   * @return false when there is nothing more to follow. A failed update is still followed: the core takes a late
   * timeout to Done when the box comes back.
   */
  private boolean update()
  {
    final NoGps.Status status = NoGps.getStatus();
    final NoGps.FirmwareUpdate state = status.getFirmwareUpdate();
    final AlertDialog dialog = (AlertDialog) requireDialog();
    final boolean updating = BoxTexts.isUpdating(state);
    final boolean ended = state == NoGps.FirmwareUpdate.DONE || state == NoGps.FirmwareUpdate.FAILED;
    // The dialog is restored for an update that is gone, e.g. after the process was killed.
    if (!updating && !ended)
    {
      dismissAllowingStateLoss();
      return false;
    }

    final boolean cancel = BoxTexts.canCancelFirmware(status);
    dialog.getButton(DialogInterface.BUTTON_NEGATIVE).setVisibility(cancel ? View.VISIBLE : View.GONE);
    dialog.getButton(DialogInterface.BUTTON_POSITIVE).setVisibility(ended ? View.VISIBLE : View.GONE);
    mNote.setVisibility(updating ? View.VISIBLE : View.GONE);
    mProgress.setVisibility(updating ? View.VISIBLE : View.GONE);
    if (ended)
    {
      mStage.setText(state == NoGps.FirmwareUpdate.DONE
                         ? getString(R.string.nogps_firmware_done, status.boxFirmware)
                         : getString(R.string.nogps_firmware_failed,
                                     BoxTexts.firmwareError(requireContext(), status.firmwareUpdateError)));
      return state == NoGps.FirmwareUpdate.FAILED;
    }

    mStage.setText(BoxTexts.capitalize(BoxTexts.firmwareText(requireContext(), status)));
    final boolean sending = state == NoGps.FirmwareUpdate.SENDING;
    if (sending)
    {
      mProgress.setIndeterminate(false);
      mProgress.setProgressCompat(status.firmwareUpdateProgress, true);
    }
    else
    {
      mProgress.setIndeterminate(true);
    }
    return true;
  }
}
