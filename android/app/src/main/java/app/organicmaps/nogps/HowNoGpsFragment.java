package app.organicmaps.nogps;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.util.WindowInsetUtils.ScrollableContentInsetsListener;

/**
 * How NonGPS works: what the app is and what the three panels of the map do, with a button that plays the intro of
 * the first start again. The intro itself is nogps.intro.IntroOverlay; MwmActivity starts it when this screen closes
 * with RESULT_OK.
 */
public class HowNoGpsFragment extends BaseMwmFragment
{
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View root = inflater.inflate(R.layout.how_nogps, container, false);
    ((TextView) root.findViewById(R.id.nogps_how_right)).setText(rightText(requireContext()));
    root.findViewById(R.id.nogps_how_intro_again).setOnClickListener(v -> {
      final Activity activity = requireActivity();
      activity.setResult(Activity.RESULT_OK);
      activity.finish();
    });
    ViewCompat.setOnApplyWindowInsetsListener(root, new ScrollableContentInsetsListener(root));
    return root;
  }

  /**
   * The line of the right panel: it tells about the zoom slide of the zoom buttons too, as the balloon of the intro
   * does (nogps.intro.IntroStep) and as the same page on iOS does.
   */
  @NonNull
  static String rightText(@NonNull Context context)
  {
    return context.getString(R.string.nogps_how_right) + " " + context.getString(R.string.nogps_intro_right_swipe);
  }
}
