package app.organicmaps.nogps;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.WindowInsetUtils.ScrollableContentInsetsListener;
import java.text.DateFormat;

/**
 * The trips of the phone with their driving scores, newest first, opened from the Driving section of the Profile.
 */
public class DrivingTripsFragment extends BaseMwmFragment
{
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View root = inflater.inflate(R.layout.nogps_driving_trips, container, false);
    final LinearLayout content = root.findViewById(R.id.trips_content);
    final NoGps.SpeedingTrip[] trips = NoGps.nativeGetDrivingRating().trips;
    root.findViewById(R.id.trips_none).setVisibility(trips.length == 0 ? View.VISIBLE : View.GONE);
    final DateFormat dateFormat = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT);
    for (NoGps.SpeedingTrip trip : trips)
    {
      final Profile.Row row = Driving.tripRow(requireContext()::getString, dateFormat, trip);
      final View view = inflater.inflate(R.layout.nogps_sheet_row, content, false);
      ((TextView) view.findViewById(R.id.row_label)).setText(row.title());
      ((TextView) view.findViewById(R.id.row_value)).setText(row.value());
      content.addView(view);
    }
    ViewCompat.setOnApplyWindowInsetsListener(root, new ScrollableContentInsetsListener(root));
    return root;
  }
}
