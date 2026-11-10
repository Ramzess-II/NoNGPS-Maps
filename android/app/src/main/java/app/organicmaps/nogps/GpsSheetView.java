package app.organicmaps.nogps;

import android.content.Context;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.location.Location;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.AttributeSet;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.StringRes;
import androidx.core.location.GnssStatusCompat;
import androidx.core.location.LocationCompat;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.sdk.location.LocationHelper;
import app.organicmaps.sdk.location.NoGps;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * What GPS is worth now and why, the details of its last position and the satellites: the GPS page of the Box sheet.
 * The owner calls {@link #update} while it is shown.
 */
public class GpsSheetView extends LinearLayout
{
  // An older position tells nothing about GPS now.
  private static final long MAX_FIX_AGE_NS = 10_000_000_000L;

  private final StatusBar.Button mTile;
  private final TextView mState;
  // A grey state is read as disabled: it is shown in the color of the text.
  private final ColorStateList mStateColors;
  private final TextView mWhy;
  private final TextView mLastFix;
  private final TextView mAccuracy;
  private final TextView mSpeedCourse;
  private final View mNetworkRow;
  private final TextView mNetwork;
  private final TextView mSatellitesUsed;
  private final TextView mSystems;
  private final TextView mSignal;

  public GpsSheetView(@NonNull Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    setOrientation(VERTICAL);
    final LayoutInflater inflater = LayoutInflater.from(context);
    inflater.inflate(R.layout.nogps_gps_view, this);
    mTile =
        new StatusBar.Button(findViewById(R.id.gps_tile), findViewById(R.id.gps_icon), findViewById(R.id.gps_badge));
    mState = findViewById(R.id.gps_state);
    mStateColors = mState.getTextColors();
    mWhy = findViewById(R.id.gps_why);
    final LinearLayout details = findViewById(R.id.gps_details);
    mLastFix = addRow(inflater, details, R.string.nogps_gps_last_fix);
    mAccuracy = addRow(inflater, details, R.string.nogps_gps_accuracy);
    mSpeedCourse = addRow(inflater, details, R.string.nogps_gps_speed_course);
    mNetwork = addRow(inflater, details, R.string.nogps_gps_network);
    mNetworkRow = (View) mNetwork.getParent();
    final LinearLayout satellites = findViewById(R.id.gps_satellites);
    mSatellitesUsed = addRow(inflater, satellites, R.string.nogps_gps_sat_used);
    mSystems = addRow(inflater, satellites, R.string.nogps_gps_sat_systems);
    mSignal = addRow(inflater, satellites, R.string.nogps_gps_sat_signal);
    findViewById(R.id.gps_settings)
        .setOnClickListener(v -> context.startActivity(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)));
  }

  @NonNull
  private static TextView addRow(@NonNull LayoutInflater inflater, @NonNull LinearLayout parent, @StringRes int label)
  {
    final View row = inflater.inflate(R.layout.nogps_sheet_row, parent, false);
    ((TextView) row.findViewById(R.id.row_label)).setText(label);
    parent.addView(row);
    return row.findViewById(R.id.row_value);
  }

  /**
   * Stops the pulsing of the icon, the next update starts it again.
   */
  public void stop()
  {
    mTile.pulse(false);
  }

  public void update(@NonNull NoGps.Status status)
  {
    final Context context = getContext();
    final StatusBar.Look look = StatusBar.getGpsLook(context, status);
    mTile.show(look);
    mState.setText(StatusBar.getGpsStateText(context, status));
    if (look.color == R.color.source_sleeping)
      mState.setTextColor(mStateColors);
    else
      mState.setTextColor(look.getColor(context));
    final String why = StatusBar.getGpsWhyText(context, status);
    mWhy.setText(why);
    mWhy.setVisibility(why == null ? View.GONE : View.VISIBLE);

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
                        : context.getString(R.string.nogps_gps_db_hz, Math.round(satellites.meanCn0DbHz)));
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
}
