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
import java.util.List;

/**
 * The records of every car of the user, opened from the Profile row of the main menu. The full list of runs of the
 * car driven now stays on its page of the Box sheet.
 */
public class ProfileFragment extends BaseMwmFragment
{
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View root = inflater.inflate(R.layout.nogps_profile, container, false);
    final LinearLayout content = root.findViewById(R.id.profile_content);
    final List<Profile.Group> groups =
        Profile.groups(requireContext()::getString, NoGps.nativeGetCars(), NoGps::nativeGetSprints);
    // No cars: the note stands where the groups would be.
    root.findViewById(R.id.profile_none).setVisibility(groups.isEmpty() ? View.VISIBLE : View.GONE);
    for (Profile.Group group : groups)
    {
      final View section = inflater.inflate(R.layout.nogps_profile_group, content, false);
      ((TextView) section.findViewById(R.id.group_title)).setText(group.title());
      final ViewGroup rows = section.findViewById(R.id.group_rows);
      for (Profile.Row row : group.rows())
      {
        final View view = inflater.inflate(R.layout.nogps_sheet_row, rows, false);
        ((TextView) view.findViewById(R.id.row_label)).setText(row.title());
        ((TextView) view.findViewById(R.id.row_value)).setText(row.value());
        rows.addView(view);
      }
      content.addView(section, content.indexOfChild(root.findViewById(R.id.profile_footer)));
    }
    ViewCompat.setOnApplyWindowInsetsListener(root, new ScrollableContentInsetsListener(root));
    return root;
  }
}
