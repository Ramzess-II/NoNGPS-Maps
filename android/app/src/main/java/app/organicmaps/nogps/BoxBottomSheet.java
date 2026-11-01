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
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.ImageView;
import android.widget.TextView;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.core.widget.ImageViewCompat;
import app.organicmaps.R;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.Utils;
import com.google.android.material.bottomsheet.BottomSheetDialogFragment;
import java.util.ArrayList;
import java.util.List;

/**
 * The sensor box: its state, the car speed, the firmware and what the user does with the box. Without a box it is
 * searched while the sheet is open, step by step, and the sheet offers to buy one.
 */
public class BoxBottomSheet extends BottomSheetDialogFragment
{
  public static final String TAG = BoxBottomSheet.class.getSimpleName();
  private static final long UPDATE_INTERVAL_MS = 500;
  private static final long RING_DURATION_MS = 2400;
  private static final String SHOP_URL = "https://non-gps.com";
  private static final String STATE_SEARCHING = "searching";

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
  private ImageView mIcon;
  private TextView mState;
  private ColorStateList mStateColors;
  private View mConnected;
  private TextView mName;
  private TextView mSpeed;
  private TextView mSpeedTable;
  private TextView mFirmware;
  private TextView mCalibrate;
  private TextView mInstallFirmware;
  private View mSearch;
  private View mShop;
  private final ImageView[] mStepDots = new ImageView[4];
  private final TextView[] mSteps = new TextView[4];
  private TextView mStepAction;
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
  }

  @Nullable
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View view = inflater.inflate(R.layout.nogps_box_sheet, container, false);
    mIcon = view.findViewById(R.id.box_icon);
    mState = view.findViewById(R.id.box_state);
    mStateColors = mState.getTextColors();
    mConnected = view.findViewById(R.id.box_connected);
    mName = view.findViewById(R.id.box_name);
    mSpeed = view.findViewById(R.id.box_speed);
    mSpeedTable = view.findViewById(R.id.box_speed_table);
    mFirmware = view.findViewById(R.id.box_firmware);
    mCalibrate = view.findViewById(R.id.box_calibrate);
    mInstallFirmware = view.findViewById(R.id.box_install_firmware);
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
    final int[] rings = {R.id.box_ring0, R.id.box_ring1, R.id.box_ring2};
    for (int i = 0; i < mRings.length; i++)
      mRings[i] = view.findViewById(rings[i]);

    mCalibrate.setOnClickListener(v -> {
      NoGps.nativeCalibrate();
      // It shows how the calibration goes.
      showSensors();
    });
    mInstallFirmware.setOnClickListener(v -> {
      // The box may have gone on since the button was drawn.
      if (SensorsBottomSheet.canInstallFirmware(NoGps.getStatus()))
        NoGps.nativeStartFirmwareUpdate();
      update();
    });
    view.findViewById(R.id.box_details).setOnClickListener(v -> showSensors());
    view.findViewById(R.id.box_forget).setOnClickListener(v -> {
      NoGps.nativeSetInertialNavigationEnabled(false);
      dismiss();
    });
    view.findViewById(R.id.box_buy).setOnClickListener(v -> Utils.openUrl(requireContext(), SHOP_URL));
    return view;
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
  }

  private void update()
  {
    final NoGps.Status status = NoGps.getStatus();
    // The box connected while it was searched: the sheet shows it as any other.
    if (mSearching && isBoxHeard(status))
      mSearching = false;
    mSearch.setVisibility(mSearching ? View.VISIBLE : View.GONE);
    mConnected.setVisibility(!mSearching && status.inertialEnabled ? View.VISIBLE : View.GONE);
    // Forgotten in the sensors sheet, or being searched.
    mShop.setVisibility(mSearching || !status.inertialEnabled ? View.VISIBLE : View.GONE);
    if (mSearching)
      updateSearch(status);
    else
      updateBox(status);
  }

  /**
   * The box sends its data: it is connected, whatever it tells.
   */
  static boolean isBoxHeard(@NonNull NoGps.Status status)
  {
    final NoGps.SourceState state = status.getSourceState();
    return status.inertialStarted && state != NoGps.SourceState.DISCONNECTED && state != NoGps.SourceState.CONNECTING;
  }

  private void updateBox(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    animateRings(false);
    final StatusBar.Look look = StatusBar.getBoxLook(status);
    showState(look, status.inertialEnabled ? getString(SensorsBottomSheet.boxStateText(status)) : "");
    if (!status.inertialEnabled)
      return;
    final String name = status.inertialStarted && !status.deviceName.isEmpty() ? status.deviceName : "ESP32";
    mName.setText(getString(R.string.nogps_sensors_box, name));
    mSpeed.setText(getString(R.string.nogps_sensors_speed, status.inertialStarted && status.speedKmh >= 0
                                                               ? getString(R.string.nogps_speed_kmh, status.speedKmh)
                                                               : getString(R.string.nogps_unknown)));
    mSpeedTable.setVisibility(status.inertialStarted ? View.VISIBLE : View.GONE);
    mSpeedTable.setText(getString(R.string.nogps_box_speed_table, speedTableText(status)));
    final boolean firmware = !status.boxFirmware.isEmpty() || status.getFirmwareUpdate() != NoGps.FirmwareUpdate.NONE;
    mFirmware.setVisibility(firmware ? View.VISIBLE : View.GONE);
    mFirmware.setText(getString(R.string.nogps_sensors_firmware, SensorsBottomSheet.firmwareText(context, status)));
    // The box calibrates itself: there is nobody to calibrate while it is out of reach.
    mCalibrate.setEnabled(status.getBleState() == NoGps.BleState.CONNECTED);
    final boolean install = SensorsBottomSheet.canInstallFirmware(status);
    mInstallFirmware.setVisibility(install ? View.VISIBLE : View.GONE);
    if (install)
      mInstallFirmware.setText(getString(R.string.nogps_firmware_install, status.bundledFirmware));
  }

  /**
   * The ranges of the car speed measured by GPS, of all; roughly by the roads until GPS has measured one.
   */
  @NonNull
  private static String speedTableText(@NonNull NoGps.Status status)
  {
    final int all = status.speedTableCarM.length;
    if (status.speedTableRanges == 0 && status.roughSpeedTableRanges > 0)
      return "≈" + status.roughSpeedTableRanges + "/" + all;
    return status.speedTableRanges + "/" + all;
  }

  private void updateSearch(@NonNull NoGps.Status status)
  {
    final NoGps.BleState ble = status.getBleState();
    final boolean bluetoothFailed =
        ble == NoGps.BleState.OFF || ble == NoGps.BleState.DISABLED || ble == NoGps.BleState.NO_PERMISSION;
    showState(new StatusBar.Look(R.drawable.ic_nogps_box, 0), getString(R.string.nogps_box_searching));
    final boolean searched = ble == NoGps.BleState.SEARCHING || ble == NoGps.BleState.PAIRING_CLOSED;
    final boolean connecting = ble == NoGps.BleState.CONNECTING || ble == NoGps.BleState.PAIRING;
    final boolean connected = ble == NoGps.BleState.CONNECTED;
    showStep(0, bluetoothFailed ? StepState.FAILED : StepState.DONE);
    showStep(1, connecting || connected ? StepState.DONE : searched ? StepState.CURRENT : StepState.WAITING);
    showStep(2, connected ? StepState.DONE : connecting ? StepState.CURRENT : StepState.WAITING);
    showStep(3, connected ? StepState.CURRENT : StepState.WAITING);
    mSteps[0].setText(ble == NoGps.BleState.NO_PERMISSION ? R.string.nogps_box_step_bluetooth_denied
                      : bluetoothFailed                   ? R.string.nogps_box_step_bluetooth_off
                                                          : R.string.nogps_box_step_bluetooth);
    mStepAction.setVisibility(bluetoothFailed ? View.VISIBLE : View.GONE);
    mStepAction.setText(ble == NoGps.BleState.NO_PERMISSION ? R.string.nogps_box_allow : R.string.nogps_box_turn_on);
    animateRings(!bluetoothFailed);
  }

  private void showState(@NonNull StatusBar.Look look, @NonNull String text)
  {
    final int color = look.getColor(requireContext());
    mIcon.setImageResource(look.icon);
    ImageViewCompat.setImageTintList(mIcon, ColorStateList.valueOf(color));
    mState.setText(text);
    // A grey state is read as disabled: it is shown in the color of the text.
    if (look.color == 0 || look.color == R.color.source_sleeping)
      mState.setTextColor(mStateColors);
    else
      mState.setTextColor(color);
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
   * Bluetooth is turned on in the settings, or allowed to the app.
   */
  private void onStepAction()
  {
    if (NoGps.getStatus().getBleState() != NoGps.BleState.NO_PERMISSION)
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
   */
  private void askBluetooth()
  {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
      return;
    final String[] permissions = {Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT};
    for (String permission : permissions)
    {
      if (ContextCompat.checkSelfPermission(requireContext(), permission) == PackageManager.PERMISSION_GRANTED)
        continue;
      mBluetoothAsked = true;
      mBluetoothLauncher.launch(permissions);
      return;
    }
  }

  private void showSensors()
  {
    final var manager = getParentFragmentManager();
    dismiss();
    if (manager.findFragmentByTag(SensorsBottomSheet.TAG) == null)
      new SensorsBottomSheet().show(manager, SensorsBottomSheet.TAG);
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
