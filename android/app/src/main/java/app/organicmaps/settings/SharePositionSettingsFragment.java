package app.organicmaps.settings;

import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.widget.SwitchCompat;
import androidx.core.view.ViewCompat;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.sdk.location.MockLocationShare;
import app.organicmaps.util.WindowInsetUtils.ScrollableContentInsetsListener;

/**
 * Gives the position of the car to other apps as a mock location. The switch stays off until the app is picked as the
 * mock location app in Developer options.
 */
public class SharePositionSettingsFragment extends BaseMwmFragment
{
  private static final String STATE_ASKED = "asked";

  private SwitchCompat mSwitch;
  private View mNeedsMock;
  // The switch is turned on, the app isn't picked yet: the share starts when the user comes back with it picked.
  private boolean mAsked;

  @Nullable
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    return inflater.inflate(R.layout.fragment_share_position_settings, container, false);
  }

  @Override
  public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState)
  {
    super.onViewCreated(view, savedInstanceState);
    ViewCompat.setOnApplyWindowInsetsListener(view, new ScrollableContentInsetsListener(view));
    if (savedInstanceState != null)
      mAsked = savedInstanceState.getBoolean(STATE_ASKED);

    mSwitch = view.findViewById(R.id.share_position);
    mNeedsMock = view.findViewById(R.id.share_position_needs_mock);
    mSwitch.setOnClickListener(v -> {
      final boolean share = mSwitch.isChecked();
      mAsked = share && !MockLocationShare.isAllowed(requireContext());
      MockLocationShare.setEnabled(share && !mAsked);
      if (mAsked)
        openDeveloperOptions();
      update();
    });
    mNeedsMock.setOnClickListener(v -> openDeveloperOptions());
  }

  @Override
  public void onSaveInstanceState(@NonNull Bundle outState)
  {
    super.onSaveInstanceState(outState);
    outState.putBoolean(STATE_ASKED, mAsked);
  }

  @Override
  public void onResume()
  {
    super.onResume();
    update();
  }

  private void update()
  {
    final boolean allowed = MockLocationShare.isAllowed(requireContext());
    if (mAsked && allowed)
    {
      mAsked = false;
      MockLocationShare.setEnabled(true);
    }
    // Also unpicked since the share was turned on.
    mNeedsMock.setVisibility((mAsked || MockLocationShare.isEnabled()) && !allowed ? View.VISIBLE : View.GONE);
    mSwitch.setChecked(MockLocationShare.isEnabled() && allowed);
  }

  private void openDeveloperOptions()
  {
    try
    {
      startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));
    }
    catch (ActivityNotFoundException e)
    {
      // Developer options are turned on in About phone.
      startActivity(new Intent(Settings.ACTION_DEVICE_INFO_SETTINGS));
    }
  }
}
