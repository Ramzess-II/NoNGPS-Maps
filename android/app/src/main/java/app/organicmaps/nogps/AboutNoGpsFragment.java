package app.organicmaps.nogps;

import android.os.Build;
import android.os.Bundle;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.method.LinkMovementMethod;
import android.text.style.ClickableSpan;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.activity.result.ActivityResultLauncher;
import androidx.annotation.IdRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.Graphics;
import app.organicmaps.util.SharingUtils;
import app.organicmaps.util.Utils;
import app.organicmaps.util.WindowInsetUtils.ScrollableContentInsetsListener;

/**
 * About NonGPS Maps: what the app is, which build it is and where it comes from. The about screen of Organic Maps,
 * the project it is based on, is HelpFragment.
 */
public class AboutNoGpsFragment extends BaseMwmFragment implements View.OnClickListener
{
  private static final String OSM_COPYRIGHT_URL = "https://www.openstreetmap.org/copyright";

  private ActivityResultLauncher<SharingUtils.SharingIntent> shareLauncher;

  private TextView setupItem(@IdRes int id, boolean tint, @NonNull View frame)
  {
    final TextView view = frame.findViewById(id);
    view.setOnClickListener(this);
    if (tint)
      Graphics.tint(view);
    return view;
  }

  @Override
  public View onCreateView(LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState)
  {
    final View root = inflater.inflate(R.layout.about_nogps, container, false);

    // NonGPS Maps and its version first, the Organic Maps it is based on below with less accent.
    setupItem(R.id.version, false, root).setText(getString(R.string.nogps_version, NoGps.getVersion()));
    setupItem(R.id.upstream_version, false, root)
        .setText(getString(R.string.nogps_based_on, NoGps.getUpstreamVersion()));

    // The map data is credited with clickable names, as Organic Maps and OpenStreetMap ask.
    linkNames(root.findViewById(R.id.map_data), "OpenStreetMap", OSM_COPYRIGHT_URL, "Organic Maps",
              NoGpsLinks.ORGANIC_MAPS_URL);
    setupItem(R.id.github, true, root);
    setupItem(R.id.box_buy, false, root);
    setupItem(R.id.report, true, root);

    final TextView sats = root.findViewById(R.id.globe_sats);
    final GlobeSceneView globe = root.findViewById(R.id.globe);
    globe.setListener((on, total) -> sats.setText(getString(R.string.nogps_about_globe_sats, on, total)));

    shareLauncher = SharingUtils.RegisterLauncher(this);

    ViewCompat.setOnApplyWindowInsetsListener(root, new ScrollableContentInsetsListener(root));

    return root;
  }

  /**
   * Makes the two names in the text clickable links.
   */
  private void linkNames(@NonNull TextView view, @NonNull String name, @NonNull String url, @NonNull String secondName,
                         @NonNull String secondUrl)
  {
    final SpannableString text = new SpannableString(view.getText());
    linkName(text, name, url);
    linkName(text, secondName, secondUrl);
    view.setText(text);
    view.setMovementMethod(LinkMovementMethod.getInstance());
  }

  private void linkName(@NonNull SpannableString text, @NonNull String name, @NonNull String url)
  {
    final int start = text.toString().indexOf(name);
    if (start < 0)
      return;
    text.setSpan(new ClickableSpan() {
      @Override
      public void onClick(@NonNull View widget)
      {
        Utils.openUrl(requireActivity(), url);
      }
    }, start, start + name.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
  }

  @Override
  public void onClick(View v)
  {
    final int id = v.getId();
    if (id == R.id.github)
      Utils.openUrl(requireActivity(), NoGpsLinks.SOURCE_CODE_URL);
    else if (id == R.id.box_buy)
      Utils.openUrl(requireActivity(), NoGpsLinks.SHOP_URL);
    else if (id == R.id.report)
      Utils.sendBugReport(shareLauncher, requireActivity(), "", "");
    else if (id == R.id.version)
      copyFullVersion(v);
    else if (id == R.id.upstream_version)
      Utils.openUrl(requireActivity(), NoGpsLinks.ORGANIC_MAPS_URL);
  }

  /// With the commit of the build: the line tells which build was tested.
  private void copyFullVersion(@NonNull View view)
  {
    final String text = "NonGPS Maps " + NoGps.getFullVersion();
    Utils.copyTextToClipboard(requireContext(), text);
    // Starting from API 33, the system shows the copied text itself.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU)
      Utils.showSnackbar(view, getString(R.string.copied_to_clipboard, text));
  }
}
