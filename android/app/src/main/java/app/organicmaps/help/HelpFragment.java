package app.organicmaps.help;

import android.os.Build;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.annotation.IdRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import app.organicmaps.BuildConfig;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.nogps.NoGpsLinks;
import app.organicmaps.sdk.Framework;
import app.organicmaps.sdk.util.Constants;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.util.DateUtils;
import app.organicmaps.util.Graphics;
import app.organicmaps.util.Utils;
import app.organicmaps.util.WindowInsetUtils.ScrollableContentInsetsListener;
import app.organicmaps.widget.DonationView;

/**
 * About Organic Maps: the project NonGPS Maps is based on, with its own channels, documents and support.
 * What NonGPS Maps itself is lives in AboutNoGpsFragment.
 */
public class HelpFragment extends BaseMwmFragment implements View.OnClickListener
{
  private String mDonateUrl;

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
    mDonateUrl = Utils.getDonateUrl(requireContext());
    View root = inflater.inflate(R.layout.about, container, false);

    // The Organic Maps version the build is based on, not the fork's: that one is on About NonGPS Maps.
    setupItem(R.id.version, false, root).setText(getString(R.string.version, NoGps.getUpstreamVersion()));

    final String dataVersion = DateUtils.getShortDateFormatter().format(Framework.getDataVersion());
    final TextView osmPresentationView = root.findViewById(R.id.osm_presentation);
    if (osmPresentationView != null)
      osmPresentationView.setText(getString(R.string.osm_presentation, dataVersion));

    setupItem(R.id.news, true, root);
    setupItem(R.id.web, true, root);
    setupItem(R.id.email, true, root);
    setupItem(R.id.github, true, root);
    setupItem(R.id.telegram, false, root);
    setupItem(R.id.instagram, false, root);
    setupItem(R.id.facebook, false, root);
    setupItem(R.id.twitter, true, root);
    setupItem(R.id.matrix, true, root);
    setupItem(R.id.mastodon, false, root);
    setupItem(R.id.openstreetmap, true, root);
    setupItem(R.id.faq, true, root);

    final TextView supportUsView = root.findViewById(R.id.support_us);
    if (BuildConfig.FLAVOR.equals("google") && !TextUtils.isEmpty(mDonateUrl))
      supportUsView.setVisibility(View.GONE);
    else
      setupItem(R.id.support_us, true, root);

    DonationView donationView = root.findViewById(R.id.donate);
    if (TextUtils.isEmpty(mDonateUrl))
    {
      donationView.setVisibility(View.GONE);
      donationView.setOnDonateClickListener(null);
    }
    else
    {
      donationView.setVisibility(View.VISIBLE);
      donationView.setOnDonateClickListener(() -> {
        Utils.openUrl(requireActivity(), mDonateUrl);
        Framework.nativeDidShowDonationPage();
      });
    }

    setupItem(R.id.rate, true, root);

    setupItem(R.id.copyright, false, root);
    View termOfUseView = root.findViewById(R.id.term_of_use_link);
    View privacyPolicyView = root.findViewById(R.id.privacy_policy);
    termOfUseView.setOnClickListener(
        v -> Utils.openUrl(requireActivity(), getResources().getString(R.string.translated_om_site_url) + "terms/"));
    privacyPolicyView.setOnClickListener(
        v -> Utils.openUrl(requireActivity(), getResources().getString(R.string.translated_om_site_url) + "privacy/"));

    ViewCompat.setOnApplyWindowInsetsListener(root, new ScrollableContentInsetsListener(root));

    return root;
  }

  @Override
  public void onClick(View v)
  {
    final int id = v.getId();
    if (id == R.id.web)
      Utils.openUrl(requireActivity(), getResources().getString(R.string.translated_om_site_url));
    else if (id == R.id.news)
      Utils.openUrl(requireActivity(), getResources().getString(R.string.translated_om_site_url) + "news/");
    else if (id == R.id.email)
      Utils.sendTo(requireContext(), NoGpsLinks.ORGANIC_MAPS_EMAIL, "Organic Maps");
    else if (id == R.id.github)
      Utils.openUrl(requireActivity(), Constants.Url.GITHUB);
    else if (id == R.id.telegram)
      Utils.openUrl(requireActivity(), getString(R.string.telegram_url));
    else if (id == R.id.instagram)
      Utils.openUrl(requireActivity(), getString(R.string.instagram_url));
    else if (id == R.id.facebook)
      Utils.showFacebookPage(requireActivity());
    else if (id == R.id.twitter)
      Utils.openUrl(requireActivity(), Constants.Url.TWITTER);
    else if (id == R.id.matrix)
      Utils.openUrl(requireActivity(), Constants.Url.MATRIX);
    else if (id == R.id.mastodon)
      Utils.openUrl(requireActivity(), Constants.Url.MASTODON);
    else if (id == R.id.openstreetmap)
      Utils.openUrl(requireActivity(), getString(R.string.osm_wiki_about_url));
    else if (id == R.id.faq)
      ((HelpActivity) requireActivity()).stackFragment(FaqFragment.class, getString(R.string.faq), null);
    else if (id == R.id.version)
      copyVersion(v);
    else if (id == R.id.support_us)
      Utils.openUrl(requireActivity(), getResources().getString(R.string.translated_om_site_url) + "support-us/");
    else if (id == R.id.rate)
      Utils.openAppInMarket(requireActivity(), NoGpsLinks.ORGANIC_MAPS_STORE_URL);
    else if (id == R.id.copyright)
      ((HelpActivity) requireActivity()).stackFragment(CopyrightFragment.class, getString(R.string.copyright), null);
  }

  private void copyVersion(@NonNull View view)
  {
    final String text = getString(R.string.version, NoGps.getUpstreamVersion());
    Utils.copyTextToClipboard(requireContext(), text);
    // Starting from API 33, the system shows the copied text itself.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU)
      Utils.showSnackbar(view, getString(R.string.copied_to_clipboard, text));
  }
}
