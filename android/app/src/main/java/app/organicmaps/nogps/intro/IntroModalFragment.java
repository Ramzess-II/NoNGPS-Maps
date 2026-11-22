package app.organicmaps.nogps.intro;

import android.app.Dialog;
import android.content.DialogInterface;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;
import androidx.fragment.app.FragmentManager;
import app.organicmaps.R;
import app.organicmaps.nogps.NoGpsLinks;
import app.organicmaps.util.Utils;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

/**
 * The first step of the intro of the first start: what the app is and that it needs the sensor box. The secondary
 * buttons open the shop and the video and leave the modal open; the accent button closes it and the balloons follow,
 * see IntroOverlay.
 */
public class IntroModalFragment extends DialogFragment
{
  public static final String TAG = IntroModalFragment.class.getSimpleName();
  /**
   * Told when the modal is closed, by its accent button or otherwise.
   */
  public static final String RESULT_CLOSED = TAG + ".closed";

  public static void show(@NonNull FragmentManager manager)
  {
    if (manager.findFragmentByTag(TAG) == null)
      new IntroModalFragment().show(manager, TAG);
  }

  @NonNull
  @Override
  public Dialog onCreateDialog(@Nullable Bundle savedInstanceState)
  {
    final View view = LayoutInflater.from(requireContext()).inflate(R.layout.nogps_intro_modal, null);
    view.findViewById(R.id.nogps_intro_buy)
        .setOnClickListener(v -> Utils.openUrl(requireContext(), NoGpsLinks.SHOP_URL));
    view.findViewById(R.id.nogps_intro_video)
        .setOnClickListener(v -> Utils.openUrl(requireContext(), NoGpsLinks.VIDEO_URL));
    view.findViewById(R.id.nogps_intro_understand).setOnClickListener(v -> dismiss());
    return new MaterialAlertDialogBuilder(requireActivity(), R.style.MwmTheme_AlertDialog).setView(view).create();
  }

  @Override
  public void onDismiss(@NonNull DialogInterface dialog)
  {
    super.onDismiss(dialog);
    if (isAdded())
      getParentFragmentManager().setFragmentResult(RESULT_CLOSED, new Bundle());
  }
}
