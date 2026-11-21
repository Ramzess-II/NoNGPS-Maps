package app.organicmaps.nogps;

import androidx.fragment.app.Fragment;
import app.organicmaps.base.BaseToolbarActivity;

public class AboutNoGpsActivity extends BaseToolbarActivity
{
  @Override
  protected Class<? extends Fragment> getFragmentClass()
  {
    return AboutNoGpsFragment.class;
  }
}
