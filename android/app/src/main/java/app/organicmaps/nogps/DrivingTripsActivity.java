package app.organicmaps.nogps;

import androidx.fragment.app.Fragment;
import app.organicmaps.base.BaseToolbarActivity;

public class DrivingTripsActivity extends BaseToolbarActivity
{
  @Override
  protected Class<? extends Fragment> getFragmentClass()
  {
    return DrivingTripsFragment.class;
  }
}
