package app.organicmaps.nogps;

import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.location.Location;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.StringRes;
import androidx.core.location.GnssStatusCompat;
import androidx.core.location.LocationCompat;
import androidx.core.widget.ImageViewCompat;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.sdk.location.LocationHelper;
import app.organicmaps.sdk.location.NoGps;
import com.google.android.material.bottomsheet.BottomSheetDialogFragment;
import com.google.android.material.materialswitch.MaterialSwitch;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * What GPS is worth now and why, whether the car follows it, the details of its last position and the satellites.
 */
public class GpsBottomSheet extends BottomSheetDialogFragment
{
  public static final String TAG = GpsBottomSheet.class.getSimpleName();
  private static final long UPDATE_INTERVAL_MS = 1000;
  // An older position tells nothing about GPS now.
  private static final long MAX_FIX_AGE_NS = 10_000_000_000L;

  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mUpdater = new Runnable() {
    @Override
    public void run()
    {
      update();
      mHandler.postDelayed(this, UPDATE_INTERVAL_MS);
    }
  };

  private ImageView mIcon;
  private TextView mState;
  // A grey state is read as disabled: it is shown in the color of the text.
  private ColorStateList mStateColors;
  private TextView mWhy;
  private MaterialSwitch mUse;
  private TextView mLastFix;
  private TextView mAccuracy;
  private TextView mSpeedCourse;
  private View mNetworkRow;
  private TextView mNetwork;
  private TextView mSatellitesUsed;
  private TextView mSystems;
  private TextView mSignal;

  @Nullable
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View view = inflater.inflate(R.layout.nogps_gps_sheet, container, false);
    mIcon = view.findViewById(R.id.gps_icon);
    mState = view.findViewById(R.id.gps_state);
    mWhy = view.findViewById(R.id.gps_why);
    mUse = view.findViewById(R.id.gps_use);
    mStateColors = mState.getTextColors();
    mUse.setOnClickListener(v -> {
      NoGps.nativeSetGpsDisabled(!mUse.isChecked());
      update();
    });
    final LinearLayout details = view.findViewById(R.id.gps_details);
    mLastFix = addRow(inflater, details, R.string.nogps_gps_last_fix);
    mAccuracy = addRow(inflater, details, R.string.nogps_gps_accuracy);
    mSpeedCourse = addRow(inflater, details, R.string.nogps_gps_speed_course);
    mNetwork = addRow(inflater, details, R.string.nogps_gps_network);
    mNetworkRow = (View) mNetwork.getParent();
    final LinearLayout satellites = view.findViewById(R.id.gps_satellites);
    mSatellitesUsed = addRow(inflater, satellites, R.string.nogps_gps_sat_used);
    mSystems = addRow(inflater, satellites, R.string.nogps_gps_sat_systems);
    mSignal = addRow(inflater, satellites, R.string.nogps_gps_sat_signal);
    view.findViewById(R.id.gps_settings)
        .setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)));
    return view;
  }

  @NonNull
  private static TextView addRow(@NonNull LayoutInflater inflater, @NonNull LinearLayout parent, @StringRes int label)
  {
    final View row = inflater.inflate(R.layout.nogps_sheet_row, parent, false);
    ((TextView) row.findViewById(R.id.row_label)).setText(label);
    parent.addView(row);
    return row.findViewById(R.id.row_value);
  }

  @Override
  public void onStart()
  {
    super.onStart();
    mHandler.post(mUpdater);
  }

  @Override
  public void onStop()
  {
    super.onStop();
    mHandler.removeCallbacks(mUpdater);
  }

  private void update()
  {
    final Context context = requireContext();
    final NoGps.Status status = NoGps.getStatus();
    final StatusBar.Look look = StatusBar.getGpsLook(context, status);
    mIcon.setImageResource(look.icon);
    final int color = look.getColor(context);
    ImageViewCompat.setImageTintList(mIcon, ColorStateList.valueOf(color));
    mState.setText(StatusBar.getGpsStateText(context, status));
    if (look.color == R.color.source_sleeping)
      mState.setTextColor(mStateColors);
    else
      mState.setTextColor(color);
    final String why = StatusBar.getGpsWhyText(context, status);
    mWhy.setText(why);
    mWhy.setVisibility(why == null ? View.GONE : View.VISIBLE);
    // GPS is turned off for the car only while the box can drive it: nothing would move the mark otherwise.
    mUse.setEnabled(status.gpsDisabled || BoxBottomSheet.isBoxHeard(status));
    if (!mUse.isPressed())
      mUse.setChecked(!status.gpsDisabled);

    mLastFix.setText(status.lastGoodGpsAgeMs < 0 ? "—" : agoText(context, status.lastGoodGpsAgeMs));
    final LocationHelper locationHelper = MwmApplication.from(context).getLocationHelper();
    Location location = locationHelper.getLastPlatformLocation();
    if (location != null && SystemClock.elapsedRealtimeNanos() - location.getElapsedRealtimeNanos() > MAX_FIX_AGE_NS)
      location = null;
    mAccuracy.setText(location == null ? "—" : accuracyText(context, location));
    mSpeedCourse.setText(location == null ? "—" : speedCourseText(context, location));
    mNetworkRow.setVisibility(status.workingNetworkAccuracyM >= 0 ? View.VISIBLE : View.GONE);
    if (status.workingNetworkAccuracyM >= 0)
      mNetwork.setText("±" + StatusBar.formatAccuracy(context, status.workingNetworkAccuracyM));

    final LocationHelper.Satellites satellites = locationHelper.getSatellites();
    mSatellitesUsed.setText(satellites == null ? "—" : satellites.used + " / " + satellites.inView);
    mSystems.setText(satellites == null || satellites.used == 0 ? "—" : systemsText(satellites.usedBySystem));
    mSignal.setText(satellites == null || satellites.used == 0
                        ? "—"
                        : getString(R.string.nogps_gps_db_hz, Math.round(satellites.meanCn0DbHz)));
  }

  @NonNull
  private static String agoText(@NonNull Context context, long ageMs)
  {
    final long seconds = Math.round(ageMs / 1000.0);
    if (seconds < 60)
      return context.getString(R.string.nogps_gps_ago_s, (int) seconds);
    if (seconds < 3600)
      return context.getString(R.string.nogps_gps_ago_min, (int) (seconds / 60));
    return context.getString(R.string.nogps_gps_ago_h, (int) (seconds / 3600));
  }

  @NonNull
  private static String accuracyText(@NonNull Context context, @NonNull Location location)
  {
    String text = location.hasAccuracy() ? "±" + StatusBar.formatAccuracy(context, location.getAccuracy()) : "—";
    if (LocationCompat.hasVerticalAccuracy(location))
      text += " · "
            + context.getString(R.string.nogps_gps_height,
                                StatusBar.formatAccuracy(context, LocationCompat.getVerticalAccuracyMeters(location)));
    return text;
  }

  @NonNull
  private static String speedCourseText(@NonNull Context context, @NonNull Location location)
  {
    final String speed =
        location.hasSpeed() ? context.getString(R.string.nogps_speed_kmh, Math.round(location.getSpeed() * 3.6f)) : "—";
    final String course = location.hasBearing() ? Math.round(location.getBearing()) + "°" : "—";
    return speed + " · " + course;
  }

  /**
   * The satellites used by system: "GPS 5 · Galileo 2".
   */
  @NonNull
  private static String systemsText(@NonNull Map<Integer, Integer> usedBySystem)
  {
    final List<String> parts = new ArrayList<>();
    for (Map.Entry<Integer, Integer> system : usedBySystem.entrySet())
      parts.add(systemName(system.getKey()) + " " + system.getValue());
    return String.join(" · ", parts);
  }

  @NonNull
  private static String systemName(int constellation)
  {
    return switch (constellation)
    {
      case GnssStatusCompat.CONSTELLATION_GPS -> "GPS";
      case GnssStatusCompat.CONSTELLATION_SBAS -> "SBAS";
      case GnssStatusCompat.CONSTELLATION_GLONASS -> "GLONASS";
      case GnssStatusCompat.CONSTELLATION_QZSS -> "QZSS";
      case GnssStatusCompat.CONSTELLATION_BEIDOU -> "BeiDou";
      case GnssStatusCompat.CONSTELLATION_GALILEO -> "Galileo";
      case GnssStatusCompat.CONSTELLATION_IRNSS -> "NavIC";
      default -> "?";
    };
  }

  @Override
  public void onDismiss(@NonNull DialogInterface dialog)
  {
    super.onDismiss(dialog);
    // The bottom bar shows the choice at once.
    if (!requireActivity().isChangingConfigurations())
      getParentFragmentManager().setFragmentResult(SensorsBottomSheet.RESULT_CLOSED, Bundle.EMPTY);
  }
}
