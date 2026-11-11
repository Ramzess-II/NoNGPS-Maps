package app.organicmaps.nogps;

import android.Manifest;
import android.animation.Animator;
import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.activity.ComponentDialog;
import androidx.activity.OnBackPressedCallback;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.widget.SwitchCompat;
import androidx.core.content.ContextCompat;
import androidx.core.widget.ImageViewCompat;
import androidx.transition.Slide;
import androidx.transition.TransitionManager;
import androidx.transition.TransitionSet;
import app.organicmaps.R;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.Utils;
import com.google.android.material.bottomsheet.BottomSheetBehavior;
import com.google.android.material.bottomsheet.BottomSheetDialog;
import com.google.android.material.bottomsheet.BottomSheetDialogFragment;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The sensor box: its state, the car speed, the firmware and what the user does with the box. Without a box it is
 * searched while the sheet is open, step by step, and the sheet offers to buy one. On the top the box and GPS are side
 * by side, GPS opens its page. Under them GPS is turned off for the car.
 */
public class BoxBottomSheet extends BottomSheetDialogFragment
{
  public static final String TAG = BoxBottomSheet.class.getSimpleName();
  private static final long UPDATE_INTERVAL_MS = 500;
  private static final long RING_DURATION_MS = 2400;
  private static final String SHOP_URL = "https://non-gps.com";
  private static final String STATE_SEARCHING = "searching";
  private static final String STATE_SPEED_TABLE = "speed_table";
  private static final String STATE_GPS = "gps";
  private static final String BOX_NAME = "NonGPS-OBD";

  private enum StepState
  {
    WAITING,
    CURRENT,
    DONE,
    FAILED,
  }

  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mUpdater = new Runnable() {
    @Override
    public void run()
    {
      update();
      mHandler.postDelayed(this, UPDATE_INTERVAL_MS);
    }
  };

  private final ActivityResultLauncher<String[]> mBluetoothLauncher =
      registerForActivityResult(new ActivityResultContracts.RequestMultiplePermissions(), result -> update());
  // The user has been asked while the sheet is shown: asked again, the system doesn't show anything.
  private boolean mBluetoothAsked;

  // No box was set up when the sheet opened: it is searched until it is heard, and forgotten if the sheet is closed
  // before it is found.
  private boolean mSearching;
  // The speed table is shown on its own page of the sheet, Back returns from it.
  private boolean mSpeedTableShown;
  // The GPS details are shown on a page of their own too. The search goes on while it is shown.
  private boolean mGpsShown;
  private final OnBackPressedCallback mBackFromPage = new OnBackPressedCallback(false) {
    @Override
    public void handleOnBackPressed()
    {
      if (mGpsShown)
        showGps(false);
      else
        showSpeedTable(false);
    }
  };
  private ViewGroup mRoot;
  private View mTiles;
  private View mBox;
  private StatusBar.Button mTile;
  private View mGpsRow;
  private View mGpsGroup;
  private StatusBar.Button mGpsTile;
  private TextView mGpsState;
  private SwitchCompat mGpsUse;
  private View mGpsUseHint;
  private View mGpsUseNeedsBox;
  private View mGpsPage;
  private GpsSheetView mGpsView;
  private TextView mState;
  private ColorStateList mStateColors;
  private View mConnected;
  private TextView mName;
  private TextView mSpeed;
  private TextView mRpm;
  private View mSpeedTable;
  private TextView mSpeedTableState;
  private View mSpeedGroup;
  private TextView mSpeedLagValue;
  private TextView mSpeedLagSource;
  private TextView mFirmware;
  private View mCalibrate;
  private TextView mCalibration;
  private TextView mCalibrateAction;
  private TextView mInstallFirmware;
  private View mSpeedTablePage;
  private LinearLayout mSpeedTableRows;
  private View mSearch;
  private View mShop;
  private final ImageView[] mStepDots = new ImageView[4];
  private final TextView[] mSteps = new TextView[4];
  private TextView mStepAction;
  private TextView mBluetooth;
  private final View[] mRings = new View[3];
  @Nullable
  private AnimatorSet mRingsAnimator;

  @Override
  public void onCreate(@Nullable Bundle savedInstanceState)
  {
    super.onCreate(savedInstanceState);
    if (savedInstanceState != null)
    {
      mSearching = savedInstanceState.getBoolean(STATE_SEARCHING);
      mSpeedTableShown = savedInstanceState.getBoolean(STATE_SPEED_TABLE);
      mGpsShown = savedInstanceState.getBoolean(STATE_GPS);
      return;
    }
    if (!NoGps.getStatus().inertialEnabled)
    {
      mSearching = true;
      NoGps.nativeSetEsp32Source(true);
      NoGps.nativeSetInertialNavigationEnabled(true);
    }
  }

  @Override
  public void onSaveInstanceState(@NonNull Bundle outState)
  {
    super.onSaveInstanceState(outState);
    outState.putBoolean(STATE_SEARCHING, mSearching);
    outState.putBoolean(STATE_SPEED_TABLE, mSpeedTableShown);
    outState.putBoolean(STATE_GPS, mGpsShown);
  }

  @Nullable
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View view = inflater.inflate(R.layout.nogps_box_sheet, container, false);
    mRoot = (ViewGroup) ((ViewGroup) view).getChildAt(0);
    mTiles = view.findViewById(R.id.box_tiles);
    mBox = view.findViewById(R.id.box_box);
    mTile = new StatusBar.Button(view.findViewById(R.id.box_tile), view.findViewById(R.id.box_icon),
                                 view.findViewById(R.id.box_badge));
    mGpsGroup = view.findViewById(R.id.box_gps_group);
    mGpsTile = new StatusBar.Button(view.findViewById(R.id.box_gps_tile), view.findViewById(R.id.box_gps_icon),
                                    view.findViewById(R.id.box_gps_badge));
    mGpsState = view.findViewById(R.id.box_gps_state);
    mGpsUse = view.findViewById(R.id.box_gps_use);
    mGpsUseHint = view.findViewById(R.id.box_gps_use_hint);
    mGpsUseNeedsBox = view.findViewById(R.id.box_gps_use_needs_box);
    mGpsPage = view.findViewById(R.id.box_gps_page);
    mGpsView = view.findViewById(R.id.box_gps_view);
    mGpsRow = view.findViewById(R.id.box_gps_row);
    mGpsRow.setOnClickListener(v -> showGps(true));
    view.findViewById(R.id.box_gps_back).setOnClickListener(v -> showGps(false));
    mGpsUse.setOnClickListener(v -> {
      NoGps.nativeSetGpsDisabled(!mGpsUse.isChecked());
      update();
    });
    mState = view.findViewById(R.id.box_state);
    mStateColors = mState.getTextColors();
    mConnected = view.findViewById(R.id.box_connected);
    mName = view.findViewById(R.id.box_name);
    mSpeed = view.findViewById(R.id.box_speed);
    mRpm = view.findViewById(R.id.box_rpm);
    mSpeedTable = view.findViewById(R.id.box_speed_table);
    mSpeedTableState = view.findViewById(R.id.box_speed_table_state);
    mSpeedGroup = view.findViewById(R.id.box_speed_group);
    mSpeedLagValue = view.findViewById(R.id.box_speed_lag_value);
    mSpeedLagSource = view.findViewById(R.id.box_speed_lag_source);
    mFirmware = view.findViewById(R.id.box_firmware);
    mCalibrate = view.findViewById(R.id.box_calibrate);
    mCalibration = view.findViewById(R.id.box_calibration);
    mCalibrateAction = view.findViewById(R.id.box_calibrate_action);
    mInstallFirmware = view.findViewById(R.id.box_install_firmware);
    mSpeedTablePage = view.findViewById(R.id.box_speed_table_page);
    mSpeedTableRows = view.findViewById(R.id.box_speed_table_rows);
    mSearch = view.findViewById(R.id.box_search);
    mShop = view.findViewById(R.id.box_shop);
    final int[] dots = {R.id.box_step0_dot, R.id.box_step1_dot, R.id.box_step2_dot, R.id.box_step3_dot};
    final int[] steps = {R.id.box_step0, R.id.box_step1, R.id.box_step2, R.id.box_step3};
    for (int i = 0; i < mSteps.length; i++)
    {
      mStepDots[i] = view.findViewById(dots[i]);
      mSteps[i] = view.findViewById(steps[i]);
    }
    mStepAction = view.findViewById(R.id.box_step_action);
    mStepAction.setOnClickListener(v -> onStepAction());
    mBluetooth = view.findViewById(R.id.box_bluetooth);
    mBluetooth.setOnClickListener(v -> onStepAction());
    final int[] rings = {R.id.box_ring0, R.id.box_ring1, R.id.box_ring2};
    for (int i = 0; i < mRings.length; i++)
      mRings[i] = view.findViewById(rings[i]);

    mSpeedTable.setOnClickListener(v -> showSpeedTable(true));
    view.findViewById(R.id.box_clear_speed)
        .setOnClickListener(v -> SensorsBottomSheet.confirmClearSpeed(requireContext(), this::update));
    view.findViewById(R.id.box_speed_table_back).setOnClickListener(v -> showSpeedTable(false));
    mCalibrate.setOnClickListener(v -> {
      // The row shows how the calibration goes.
      if (calibrateActionText(NoGps.getStatus()) == 0)
        return;
      NoGps.nativeCalibrate();
      update();
    });
    mInstallFirmware.setOnClickListener(v -> {
      // The box may have gone on since the button was drawn.
      if (SensorsBottomSheet.canInstallFirmware(NoGps.getStatus()))
        NoGps.nativeStartFirmwareUpdate();
      update();
    });
    view.findViewById(R.id.box_forget).setOnClickListener(v -> {
      NoGps.nativeSetInertialNavigationEnabled(false);
      dismiss();
    });
    view.findViewById(R.id.box_buy).setOnClickListener(v -> Utils.openUrl(requireContext(), SHOP_URL));
    view.findViewById(R.id.box_buy_another).setOnClickListener(v -> Utils.openUrl(requireContext(), SHOP_URL));
    return view;
  }

  @Override
  public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState)
  {
    super.onViewCreated(view, savedInstanceState);
    ((ComponentDialog) requireDialog())
        .getOnBackPressedDispatcher()
        .addCallback(getViewLifecycleOwner(), mBackFromPage);
    if (fitsRows() && !mGpsShown)
      getBehavior().setState(BottomSheetBehavior.STATE_EXPANDED);
  }

  @Override
  public void onStart()
  {
    super.onStart();
    mHandler.post(mUpdater);
    // Once: the user may have refused.
    if (NoGps.getStatus().inertialEnabled && !mBluetoothAsked)
      askBluetooth();
  }

  @Override
  public void onStop()
  {
    super.onStop();
    mHandler.removeCallbacks(mUpdater);
    animateRings(false);
    mTile.pulse(false);
    mGpsTile.pulse(false);
    mGpsView.stop();
  }

  private void update()
  {
    final NoGps.Status status = NoGps.getStatus();
    // The box connected while it was searched: the sheet shows it as any other.
    if (mSearching && isBoxHeard(status))
    {
      mSearching = false;
      // As with a box set up: the sheet goes down to its height, its rows go on below.
      if (!mGpsShown)
        getBehavior().setState(BottomSheetBehavior.STATE_COLLAPSED);
    }
    final boolean speedTable = mSpeedTableShown && !mGpsShown && !mSearching && status.inertialEnabled;
    final boolean page = speedTable || mGpsShown;
    mBackFromPage.setEnabled(page);
    mTiles.setVisibility(page ? View.GONE : View.VISIBLE);
    mGpsGroup.setVisibility(page ? View.GONE : View.VISIBLE);
    mGpsPage.setVisibility(mGpsShown ? View.VISIBLE : View.GONE);
    mSpeedTablePage.setVisibility(speedTable ? View.VISIBLE : View.GONE);
    mSearch.setVisibility(mSearching && !page ? View.VISIBLE : View.GONE);
    mConnected.setVisibility(!mSearching && status.inertialEnabled && !page ? View.VISIBLE : View.GONE);
    // Forgotten in the sensors sheet, or being searched.
    mShop.setVisibility((mSearching || !status.inertialEnabled) && !page ? View.VISIBLE : View.GONE);
    updateGps(status);
    if (mGpsShown)
      mGpsView.update(status);
    else if (mSearching)
      updateSearch(status);
    else if (speedTable)
      updateSpeedTable(status);
    else
      updateBox(status);
  }

  private void updateGps(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final StatusBar.Look look = StatusBar.getGpsLook(context, status);
    mGpsTile.show(look);
    final String state = StatusBar.getGpsStateText(context, status);
    showState(mGpsState, look, state);
    mGpsRow.setContentDescription(getString(R.string.nogps_status_gps) + ": " + state);
    // GPS is turned off for the car only while the box can drive it: nothing would move the mark otherwise.
    final boolean canSwitch = status.gpsDisabled || isBoxHeard(status);
    mGpsUse.setEnabled(canSwitch);
    if (!mGpsUse.isPressed())
      mGpsUse.setChecked(!status.gpsDisabled);
    mGpsUseHint.setVisibility(canSwitch ? View.VISIBLE : View.INVISIBLE);
    mGpsUseNeedsBox.setVisibility(canSwitch ? View.INVISIBLE : View.VISIBLE);
  }

  /**
   * Before the box tells its sensor.
   */
  @NonNull
  static String boxName(@NonNull NoGps.Status status)
  {
    return status.inertialStarted && !status.deviceName.isEmpty() ? status.deviceName : BOX_NAME;
  }

  /**
   * The box sends its data: it is connected, whatever it tells.
   */
  static boolean isBoxHeard(@NonNull NoGps.Status status)
  {
    final NoGps.SourceState state = status.getSourceState();
    return status.inertialStarted && state != NoGps.SourceState.DISCONNECTED && state != NoGps.SourceState.CONNECTING;
  }

  /**
   * The phone can't look for the box until the user turns Bluetooth on or allows it in the settings.
   */
  private static boolean isBluetoothFailed(@NonNull NoGps.Status status)
  {
    final NoGps.BleState ble = status.getBleState();
    return ble == NoGps.BleState.OFF || ble == NoGps.BleState.DISABLED || ble == NoGps.BleState.NO_PERMISSION;
  }

  private boolean isLocationOff(@NonNull NoGps.Status status)
  {
    return NoGps.isLocationOffForBox(requireContext(), status);
  }

  private int bluetoothActionText(@NonNull NoGps.Status status)
  {
    if (isLocationOff(status))
      return R.string.nogps_box_turn_on_location;
    if (status.getBleState() != NoGps.BleState.NO_PERMISSION)
      return R.string.nogps_box_turn_on;
    // Named as in the settings: Android before 12 finds Bluetooth devices with the location permission.
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? R.string.nogps_box_allow_nearby
                                                          : R.string.nogps_box_allow_location;
  }

  private void updateBox(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    animateRings(false);
    final StatusBar.Look look = StatusBar.getBoxLook(status);
    showBox(look, status.inertialEnabled ? SensorsBottomSheet.boxStateText(context, status)
                                         : getString(R.string.nogps_box_buy_title));
    if (!status.inertialEnabled)
      return;
    final boolean bluetoothFailed = isBluetoothFailed(status);
    mBluetooth.setVisibility(bluetoothFailed ? View.VISIBLE : View.GONE);
    if (bluetoothFailed)
      mBluetooth.setText(bluetoothActionText(status));
    mName.setText(getString(R.string.nogps_sensors_box, boxName(status)));
    // The box tells the car data and its calibration: there is nothing to show while it is out of reach.
    final boolean connected = isBoxHeard(status) && status.getBleState() == NoGps.BleState.CONNECTED;
    mSpeed.setVisibility(connected ? View.VISIBLE : View.GONE);
    mSpeed.setText(getString(R.string.nogps_sensors_speed, status.speedKmh >= 0
                                                               ? getString(R.string.nogps_speed_kmh, status.speedKmh)
                                                               : getString(R.string.nogps_unknown)));
    final boolean rpm = connected && status.rpm >= 0;
    mRpm.setVisibility(rpm ? View.VISIBLE : View.GONE);
    if (rpm)
      mRpm.setText(getString(R.string.nogps_box_rpm, getString(R.string.nogps_rpm, status.rpm)));
    mSpeedGroup.setVisibility(status.inertialStarted ? View.VISIBLE : View.GONE);
    mSpeedTableState.setText(speedTableText(context, status));
    mSpeedLagValue.setText(
        getString(R.string.nogps_speed_lag_value, String.format(Locale.US, "%.1f", status.speedLagSec)));
    mSpeedLagSource.setText(status.speedLagMeasured ? R.string.nogps_speed_lag_measured
                                                    : R.string.nogps_speed_lag_usual);
    final boolean firmware = !status.boxFirmware.isEmpty() || status.getFirmwareUpdate() != NoGps.FirmwareUpdate.NONE;
    mFirmware.setVisibility(firmware ? View.VISIBLE : View.GONE);
    mFirmware.setText(getString(R.string.nogps_sensors_firmware, SensorsBottomSheet.firmwareText(context, status)));
    mCalibrate.setVisibility(connected ? View.VISIBLE : View.GONE);
    if (connected)
    {
      final int action = calibrateActionText(status);
      mCalibration.setText(calibrationText(context, status));
      mCalibrateAction.setVisibility(action != 0 ? View.VISIBLE : View.GONE);
      if (action != 0)
        mCalibrateAction.setText(action);
      mCalibrate.setClickable(action != 0);
    }
    final boolean install = SensorsBottomSheet.canInstallFirmware(status);
    mInstallFirmware.setVisibility(install ? View.VISIBLE : View.GONE);
    if (install)
      mInstallFirmware.setText(getString(R.string.nogps_firmware_install, status.bundledFirmware));
  }

  @NonNull
  private static String calibrationText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    final NoGps.CalibrationState calibration = status.getCalibration();
    if (calibration == NoGps.CalibrationState.NONE)
      return context.getString(R.string.nogps_box_sensors_not_calibrated);
    if (calibration == NoGps.CalibrationState.DONE && !status.boxCalibrationAdvised)
      return context.getString(R.string.nogps_box_sensors_calibrated);
    return context.getString(R.string.nogps_sensors_box_sensors,
                             SensorsBottomSheet.boxCalibrationText(context, status, calibration));
  }

  /**
   * @return 0 while the box calibrates: the user has nothing to do.
   */
  private static int calibrateActionText(@NonNull NoGps.Status status)
  {
    return switch (status.getCalibration())
    {
      case CALIBRATING -> 0;
      case DONE -> status.boxCalibrationAdvised ? R.string.nogps_sensors_calibrate_box : R.string.nogps_box_recalibrate;
      case NONE, FAILED_MOVING, MOUNT_MOVED, LINK_LOST -> R.string.nogps_sensors_calibrate_box;
    };
  }

  private void showSpeedTable(boolean shown)
  {
    mSpeedTableShown = shown;
    switchPage(shown, mSpeedTablePage);
  }

  private void showGps(boolean shown)
  {
    mGpsShown = shown;
    switchPage(shown, mGpsPage);
  }

  // Without a box the sheet is at the height of its rows, as on iOS: the search and the offer to buy one.
  private boolean fitsRows()
  {
    return mSearching || !NoGps.getStatus().inertialEnabled;
  }

  @NonNull
  private BottomSheetBehavior<?> getBehavior()
  {
    return ((BottomSheetDialog) requireDialog()).getBehavior();
  }

  private void switchPage(boolean shown, @NonNull View page)
  {
    // The page opens at the height of the sheet, as on iOS, and is swiped up to see all of it.
    final BottomSheetBehavior<?> behavior = getBehavior();
    behavior.setPeekHeight(shown ? ((View) requireView().getParent()).getHeight()
                                 : BottomSheetBehavior.PEEK_HEIGHT_AUTO);
    behavior.setState(!shown && fitsRows() ? BottomSheetBehavior.STATE_EXPANDED : BottomSheetBehavior.STATE_COLLAPSED);
    // The page comes from the end as a new screen does, and goes back there.
    final TransitionSet transition = new TransitionSet()
                                         .addTransition(new Slide(Gravity.END).addTarget(page))
                                         .addTransition(new Slide(Gravity.START)
                                                            .addTarget(mTiles)
                                                            .addTarget(mGpsGroup)
                                                            .addTarget(mConnected)
                                                            .addTarget(mSearch)
                                                            .addTarget(mShop));
    TransitionManager.beginDelayedTransition(mRoot, transition);
    update();
  }

  private void updateSpeedTable(@NonNull NoGps.Status status)
  {
    final int ranges = status.inertialStarted ? status.speedTableCarM.length : 0;
    while (mSpeedTableRows.getChildCount() < ranges)
    {
      final TextView row = new TextView(requireContext());
      row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
      row.setFontFeatureSettings("tnum");
      row.setMinHeight(
          (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 28, getResources().getDisplayMetrics()));
      row.setGravity(Gravity.CENTER_VERTICAL);
      mSpeedTableRows.addView(row);
    }
    for (int i = 0; i < mSpeedTableRows.getChildCount(); ++i)
    {
      final TextView row = (TextView) mSpeedTableRows.getChildAt(i);
      row.setVisibility(i < ranges ? View.VISIBLE : View.GONE);
      if (i < ranges)
        row.setText(SensorsBottomSheet.speedTableRowText(requireContext(), status, i));
    }
  }

  /**
   * How many ranges of the car speed GPS has measured. The rough table by the roads doesn't count: it is only a guess.
   */
  @NonNull
  private static String speedTableText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    final int all = status.speedTableCarM.length;
    if (status.speedTableRanges == 0)
      return context.getString(R.string.nogps_speed_table_not_calibrated);
    if (status.speedTableRanges >= all)
      return context.getString(R.string.nogps_speed_table_calibrated);
    return context.getString(R.string.nogps_speed_table_calibrating, status.speedTableRanges, all);
  }

  private void updateSearch(@NonNull NoGps.Status status)
  {
    final NoGps.BleState ble = status.getBleState();
    final boolean bluetoothFailed = isBluetoothFailed(status);
    showBox(new StatusBar.Look(R.drawable.ic_nogps_box, 0), getString(R.string.nogps_box_searching));
    final boolean searched = ble == NoGps.BleState.SEARCHING || ble == NoGps.BleState.PAIRING_CLOSED;
    final boolean connecting = ble == NoGps.BleState.CONNECTING || ble == NoGps.BleState.PAIRING;
    final boolean connected = ble == NoGps.BleState.CONNECTED;
    showStep(0, bluetoothFailed ? StepState.FAILED : StepState.DONE);
    showStep(1, connecting || connected ? StepState.DONE : searched ? StepState.CURRENT : StepState.WAITING);
    showStep(2, connected ? StepState.DONE : connecting ? StepState.CURRENT : StepState.WAITING);
    showStep(3, connected ? StepState.CURRENT : StepState.WAITING);
    mSteps[0].setText(ble == NoGps.BleState.NO_PERMISSION
                          ? (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? R.string.nogps_box_step_nearby_denied
                                                                            : R.string.nogps_box_step_location_denied)
                      : isLocationOff(status) ? R.string.nogps_box_step_location_off
                      : bluetoothFailed       ? R.string.nogps_box_step_bluetooth_off
                                              : R.string.nogps_box_step_bluetooth);
    mStepAction.setVisibility(bluetoothFailed ? View.VISIBLE : View.GONE);
    mStepAction.setText(bluetoothActionText(status));
    animateRings(!bluetoothFailed);
  }

  private void showBox(@NonNull StatusBar.Look look, @NonNull String text)
  {
    mTile.show(look);
    showState(mState, look, text);
    mBox.setContentDescription(getString(R.string.nogps_box_title) + ": " + mState.getText());
  }

  private void showState(@NonNull TextView state, @NonNull StatusBar.Look look, @NonNull String text)
  {
    // The states follow "Box: name ·" on the sensors screen, here they start the line.
    state.setText(text.isEmpty() ? text : text.substring(0, 1).toUpperCase(Locale.getDefault()) + text.substring(1));
    // A grey state is read as disabled: it is shown in the color of the text.
    if (look.color == 0 || look.color == R.color.source_sleeping)
      state.setTextColor(mStateColors);
    else
      state.setTextColor(look.getColor(requireContext()));
  }

  private void showStep(int i, @NonNull StepState state)
  {
    final Context context = requireContext();
    final ImageView dot = mStepDots[i];
    switch (state)
    {
    case WAITING, CURRENT ->
    {
      dot.setImageResource(R.drawable.ic_nogps_step_waiting);
      final int color = state == StepState.CURRENT ? R.color.source_connecting : R.color.source_sleeping;
      ImageViewCompat.setImageTintList(dot, ColorStateList.valueOf(ContextCompat.getColor(context, color)));
    }
    case DONE ->
    {
      dot.setImageResource(R.drawable.ic_nogps_step_done);
      ImageViewCompat.setImageTintList(dot, null);
    }
    case FAILED ->
    {
      dot.setImageResource(R.drawable.ic_nogps_step_failed);
      ImageViewCompat.setImageTintList(dot, null);
    }
    }
    final TextView step = mSteps[i];
    if (state == StepState.FAILED)
      step.setTextColor(ContextCompat.getColor(context, R.color.source_bad));
    else
      step.setTextColor(mStateColors);
    step.setAlpha(state == StepState.WAITING ? 0.5f : 1f);
    step.setTypeface(null,
                     state == StepState.CURRENT ? android.graphics.Typeface.BOLD : android.graphics.Typeface.NORMAL);
  }

  /**
   * Waves go out from the phone while it looks for the box.
   */
  private void animateRings(boolean on)
  {
    if (on == (mRingsAnimator != null))
      return;
    if (mRingsAnimator != null)
    {
      mRingsAnimator.cancel();
      mRingsAnimator = null;
      for (View ring : mRings)
        ring.setAlpha(0f);
      return;
    }
    final List<Animator> animators = new ArrayList<>();
    for (int i = 0; i < mRings.length; i++)
    {
      final long delay = RING_DURATION_MS * i / mRings.length;
      animators.add(ring(ObjectAnimator.ofFloat(mRings[i], View.SCALE_X, 0.4f, 1f), delay));
      animators.add(ring(ObjectAnimator.ofFloat(mRings[i], View.SCALE_Y, 0.4f, 1f), delay));
      animators.add(ring(ObjectAnimator.ofFloat(mRings[i], View.ALPHA, 0.7f, 0f), delay));
    }
    mRingsAnimator = new AnimatorSet();
    mRingsAnimator.playTogether(animators);
    mRingsAnimator.setInterpolator(new DecelerateInterpolator());
    mRingsAnimator.start();
  }

  @NonNull
  private static ObjectAnimator ring(@NonNull ObjectAnimator animator, long delayMs)
  {
    animator.setDuration(RING_DURATION_MS);
    animator.setStartDelay(delayMs);
    animator.setRepeatCount(ValueAnimator.INFINITE);
    return animator;
  }

  /**
   * Bluetooth or the location is turned on in the settings, or allowed to the app.
   */
  private void onStepAction()
  {
    final NoGps.Status status = NoGps.getStatus();
    if (isLocationOff(status))
    {
      startActivity(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS));
      return;
    }
    if (status.getBleState() != NoGps.BleState.NO_PERMISSION)
    {
      startActivity(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS));
      return;
    }
    if (!mBluetoothAsked)
    {
      askBluetooth();
      return;
    }
    // Refused already: the system doesn't ask again.
    startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                             Uri.fromParts("package", requireContext().getPackageName(), null)));
  }

  /**
   * The sensor box is searched and connected over Bluetooth LE. Without the permission its state tells so.
   * Before Android 12 a Bluetooth scan needs the location permission.
   */
  private void askBluetooth()
  {
    final String[] permissions =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            ? new String[] {Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT}
            : new String[] {Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION};
    for (String permission : permissions)
    {
      if (ContextCompat.checkSelfPermission(requireContext(), permission) == PackageManager.PERMISSION_GRANTED)
        continue;
      mBluetoothAsked = true;
      mBluetoothLauncher.launch(permissions);
      return;
    }
  }

  @Override
  public void onDismiss(@NonNull DialogInterface dialog)
  {
    super.onDismiss(dialog);
    if (requireActivity().isChangingConfigurations())
      return;
    // Closed before a box was found: the phone stops looking for it.
    if (mSearching && NoGps.getStatus().getBleState() != NoGps.BleState.CONNECTED)
      NoGps.nativeSetInertialNavigationEnabled(false);
    // The bottom bar shows the box at once.
    getParentFragmentManager().setFragmentResult(SensorsBottomSheet.RESULT_CLOSED, Bundle.EMPTY);
  }
}
