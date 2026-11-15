package app.organicmaps.nogps;

import android.Manifest;
import android.animation.Animator;
import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.content.ActivityNotFoundException;
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
import android.text.InputType;
import android.text.format.DateUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import androidx.activity.ComponentDialog;
import androidx.activity.OnBackPressedCallback;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.StringRes;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.widget.SwitchCompat;
import androidx.core.content.ContextCompat;
import androidx.core.widget.ImageViewCompat;
import androidx.fragment.app.FragmentManager;
import androidx.transition.Slide;
import androidx.transition.TransitionManager;
import androidx.transition.TransitionSet;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.sdk.location.MockLocationShare;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.Utils;
import com.google.android.material.bottomsheet.BottomSheetBehavior;
import com.google.android.material.bottomsheet.BottomSheetDialog;
import com.google.android.material.bottomsheet.BottomSheetDialogFragment;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/**
 * The sensor box and GPS side by side, each opens its page, the current car opens the cars. Under them GPS is blocked
 * for the car. Without a box it is searched while the sheet is open, step by step, and the sheet offers to buy one.
 */
public class BoxBottomSheet extends BottomSheetDialogFragment
{
  public static final String TAG = BoxBottomSheet.class.getSimpleName();
  // The fragment result told when the user closes the sheet: the bottom bar shows the box and GPS at once.
  public static final String RESULT_CLOSED = TAG + ".closed";
  private static final long UPDATE_INTERVAL_MS = 500;
  private static final long RING_DURATION_MS = 2400;
  private static final String SHOP_URL = "https://non-gps.com";
  private static final String ARG_PAGE = "page";
  private static final String ARG_UNFOLD_BOX = "unfold_box";
  private static final String STATE_PAGE = "page";
  private static final String STATE_SEARCHING = "searching";
  private static final String STATE_CARS_BEFORE_ADD = "cars_before_add";
  private static final String STATE_UNFOLDED = "unfolded";
  private static final String STATE_SHARE_ASKED = "share_asked";

  /**
   * Each page is opened from its parent, Back returns there.
   */
  public enum Page
  {
    MAIN,
    GPS,
    CARS,
    PHONES,
    ADD_CAR,
    BOX,
    CALIBRATION;

    @NonNull
    Page parent()
    {
      return switch (this)
      {
        case MAIN, GPS, CARS, BOX -> MAIN;
        case PHONES, ADD_CAR -> CARS;
        case CALIBRATION -> BOX;
      };
    }

    int depth()
    {
      return this == MAIN ? 0 : 1 + parent().depth();
    }
  }

  // The sections of the Box page that fold.
  private static final int SECTION_BOX = 0;
  private static final int SECTION_CAR = 1;
  private static final int SECTION_SPEED = 2;
  private static final int SECTION_IMU = 3;

  private enum StepState
  {
    WAITING,
    CURRENT,
    DONE,
    FAILED,
  }

  /**
   * The header of a section of the Box page and what it folds.
   */
  private static final class Section
  {
    final View header;
    final TextView title;
    final TextView state;
    final View chevron;
    final View content;

    Section(@NonNull View root, int headerId, int contentId)
    {
      header = root.findViewById(headerId);
      title = header.findViewById(R.id.section_title);
      state = header.findViewById(R.id.section_state);
      chevron = header.findViewById(R.id.section_chevron);
      content = root.findViewById(contentId);
    }

    void show(@NonNull String titleText, @NonNull String stateText)
    {
      title.setText(titleText);
      state.setText(BoxTexts.capitalize(stateText));
      state.setVisibility(stateText.isEmpty() ? View.GONE : View.VISIBLE);
    }

    void setVisible(boolean visible)
    {
      header.setVisibility(visible ? View.VISIBLE : View.GONE);
      if (!visible)
        content.setVisibility(View.GONE);
    }

    void setOpen(boolean open)
    {
      content.setVisibility(open ? View.VISIBLE : View.GONE);
      // The chevron points down while the section is open.
      final boolean rtl = header.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
      chevron.setRotation(open ? (rtl ? -90f : 90f) : 0f);
    }
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

  @NonNull
  private Page mPage = Page.MAIN;
  // No box was set up when the sheet opened: it is searched until it is heard, and forgotten if the sheet is closed
  // before it is found.
  private boolean mSearching;
  // The box of a new car is searched on its page until the list of the cars grows: the box of a car is heard before,
  // and a box sleeping after its link was dropped is taken as heard too.
  private int mCarsBeforeAdd;
  private final boolean[] mUnfolded = new boolean[4];
  // The code for a new phone, shown while the box takes it.
  @Nullable
  private AlertDialog mAddPhoneDialog;
  // The user has turned the share on before the app is picked as the mock location app.
  private boolean mShareAsked;
  private final OnBackPressedCallback mBackFromPage = new OnBackPressedCallback(false) {
    @Override
    public void handleOnBackPressed()
    {
      showPage(mPage.parent());
    }
  };
  private ViewGroup mRoot;
  private View mMain;
  private TextView mTitle;
  private View mBox;
  private View mBoxChevron;
  private StatusBar.Button mTile;
  private TextView mState;
  private ColorStateList mStateColors;
  private View mGpsRow;
  private StatusBar.Button mGpsTile;
  private TextView mGpsState;
  private TextView mBluetooth;
  private SwitchCompat mGpsBlock;
  private View mGpsBlockHint;
  private View mGpsBlockNeedsBox;
  private SwitchCompat mSharePosition;
  private View mSharePositionNeedsMock;
  private View mShop;
  private View mShopOffer;
  private View mBuyAnother;
  private View mSearch;
  private final ImageView[] mStepDots = new ImageView[4];
  private final TextView[] mSteps = new TextView[4];
  private TextView mStepHint;
  private TextView mStepAction;
  private final View[] mRings = new View[3];
  @Nullable
  private AnimatorSet mRingsAnimator;

  private View mGpsPage;
  private GpsSheetView mGpsView;

  private View mCarsPage;
  private LinearLayout mCars;
  private View mAddCar;
  // The texts of the car rows shown: the rows are made again when they change.
  private List<String> mCarTexts = new ArrayList<>();
  private View mAddCarPage;

  private View mPhonesPage;
  private LinearLayout mPhonesRows;
  private View mPhonesReadOnly;
  private View mAddPhone;
  // The texts of the phone rows shown: the rows are made again when they change.
  private List<String> mPhoneTexts = new ArrayList<>();

  private View mBoxPage;
  private TextView mReadiness;
  private final Section[] mSections = new Section[4];
  private Section mObdSection;
  private TextView mReadOnly;
  private View mFirmwareRow;
  private TextView mFirmware;
  private Button mFirmwareAction;
  private TextView mSpeed;
  private View mVoltageMismatch;
  private TextView mSpeedScale;
  private TextView mRoughSpeed;
  private TextView mSpeedLagValue;
  private TextView mSpeedLagSource;
  private LinearLayout mSpeedTableRows;
  private TextView mCalibrationRow;
  // The values of the box by groups, in the order the box sends them: car, gyroscope, OBD, box.
  private final LinearLayout[] mValueGroups = new LinearLayout[4];
  // The values shown, the last ones while the box is out of reach: the rows are made again when the box sends other
  // fields.
  private NoGps.BoxValue[] mValueIds = new NoGps.BoxValue[0];
  private String[] mValues = new String[0];
  private TextView[] mValueTexts = new TextView[0];

  private View mCalibrationPage;
  private TextView mCalibrationState;
  private ProgressBar mCalibrationProgress;
  private TextView mCalibrationResult;
  private Button mCalibrate;
  private TextView mCalibrateReason;

  /**
   * Shows the sheet at the page, or turns the sheet shown already to it.
   * @param unfoldBox unfolds the Box section of the Box page, e.g. to show how the firmware is sent.
   */
  public static void show(@NonNull FragmentManager manager, @NonNull Page page, boolean unfoldBox)
  {
    if (manager.findFragmentByTag(TAG) instanceof BoxBottomSheet shown)
    {
      if (page != Page.MAIN && shown.getView() != null)
        shown.open(page, unfoldBox);
      return;
    }
    if (manager.isStateSaved())
      return;
    final BoxBottomSheet sheet = new BoxBottomSheet();
    final Bundle args = new Bundle();
    args.putInt(ARG_PAGE, page.ordinal());
    args.putBoolean(ARG_UNFOLD_BOX, unfoldBox);
    sheet.setArguments(args);
    sheet.show(manager, TAG);
  }

  /**
   * The box is connected and asks to be calibrated, or its calibration has failed: a bar on the map tells so until
   * the user calibrates it. The phone that connected to the box first calibrates it.
   */
  public static boolean needsCalibration(@NonNull NoGps.Status status)
  {
    if (!isConnected(status) || status.boxReadOnly)
      return false;
    return switch (status.getCalibration())
    {
      case CALIBRATING -> false;
      case DONE -> status.boxCalibrationAdvised;
      case NONE, FAILED_MOVING, MOUNT_MOVED, LINK_LOST -> true;
    };
  }

  @Override
  public void onCreate(@Nullable Bundle savedInstanceState)
  {
    super.onCreate(savedInstanceState);
    if (savedInstanceState != null)
    {
      mPage = Page.values()[savedInstanceState.getInt(STATE_PAGE)];
      mSearching = savedInstanceState.getBoolean(STATE_SEARCHING);
      mCarsBeforeAdd = savedInstanceState.getInt(STATE_CARS_BEFORE_ADD);
      final boolean[] unfolded = savedInstanceState.getBooleanArray(STATE_UNFOLDED);
      if (unfolded != null)
        System.arraycopy(unfolded, 0, mUnfolded, 0, mUnfolded.length);
      mShareAsked = savedInstanceState.getBoolean(STATE_SHARE_ASKED);
      // The app was killed while the box was searched: the new core doesn't search it. Without the core the activity
      // goes to the splash screen.
      if (MwmApplication.from(requireContext()).getOrganicMaps().arePlatformAndCoreInitialized())
      {
        if (mPage == Page.ADD_CAR)
          MwmApplication.from(requireContext()).getLocationHelper().searchNewBox(true);
        else if (mSearching && !NoGps.getStatus().inertialEnabled)
          startSearch();
      }
      return;
    }
    if (!NoGps.getStatus().inertialEnabled)
    {
      // Only the main page tells about a box that is not set up.
      mSearching = true;
      startSearch();
      return;
    }
    final Bundle args = getArguments();
    if (args != null)
    {
      mPage = Page.values()[args.getInt(ARG_PAGE)];
      mUnfolded[SECTION_BOX] = args.getBoolean(ARG_UNFOLD_BOX);
    }
  }

  private static void startSearch()
  {
    NoGps.nativeSetEsp32Source(true);
    NoGps.nativeSetInertialNavigationEnabled(true);
  }

  @Override
  public void onSaveInstanceState(@NonNull Bundle outState)
  {
    super.onSaveInstanceState(outState);
    outState.putInt(STATE_PAGE, mPage.ordinal());
    outState.putBoolean(STATE_SEARCHING, mSearching);
    outState.putInt(STATE_CARS_BEFORE_ADD, mCarsBeforeAdd);
    outState.putBooleanArray(STATE_UNFOLDED, mUnfolded);
    outState.putBoolean(STATE_SHARE_ASKED, mShareAsked);
  }

  @Nullable
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View view = inflater.inflate(R.layout.nogps_box_sheet, container, false);
    mRoot = (ViewGroup) ((ViewGroup) view).getChildAt(0);
    mMain = view.findViewById(R.id.box_main);
    mTitle = view.findViewById(R.id.box_title);
    mTitle.setOnClickListener(v -> showPage(Page.CARS));
    mBox = view.findViewById(R.id.box_box);
    mBoxChevron = view.findViewById(R.id.box_chevron);
    mBox.setOnClickListener(v -> showPage(Page.BOX));
    mTile = new StatusBar.Button(view.findViewById(R.id.box_tile), view.findViewById(R.id.box_icon),
                                 view.findViewById(R.id.box_badge));
    mState = view.findViewById(R.id.box_state);
    mStateColors = mState.getTextColors();
    mGpsRow = view.findViewById(R.id.box_gps_row);
    mGpsRow.setOnClickListener(v -> showPage(Page.GPS));
    mGpsTile = new StatusBar.Button(view.findViewById(R.id.box_gps_tile), view.findViewById(R.id.box_gps_icon),
                                    view.findViewById(R.id.box_gps_badge));
    mGpsState = view.findViewById(R.id.box_gps_state);
    mBluetooth = view.findViewById(R.id.box_bluetooth);
    mBluetooth.setOnClickListener(v -> onStepAction());
    mGpsBlock = view.findViewById(R.id.box_gps_block);
    mGpsBlockHint = view.findViewById(R.id.box_gps_block_hint);
    mGpsBlockNeedsBox = view.findViewById(R.id.box_gps_block_needs_box);
    mGpsBlock.setOnClickListener(v -> {
      NoGps.nativeSetGpsDisabled(mGpsBlock.isChecked());
      update();
    });
    mSharePosition = view.findViewById(R.id.box_share_position);
    mSharePositionNeedsMock = view.findViewById(R.id.box_share_position_needs_mock);
    mSharePosition.setOnClickListener(v -> {
      final boolean share = mSharePosition.isChecked();
      mShareAsked = share && !MockLocationShare.isAllowed(requireContext());
      MockLocationShare.setEnabled(share && !mShareAsked);
      // The share is turned on when the user comes back with the app picked there.
      if (mShareAsked)
        openDeveloperOptions();
      update();
    });
    mSharePositionNeedsMock.setOnClickListener(v -> openDeveloperOptions());
    mShop = view.findViewById(R.id.box_shop);
    mShopOffer = view.findViewById(R.id.box_shop_offer);
    mBuyAnother = view.findViewById(R.id.box_buy_another);
    view.findViewById(R.id.box_buy).setOnClickListener(v -> Utils.openUrl(requireContext(), SHOP_URL));
    mBuyAnother.setOnClickListener(v -> Utils.openUrl(requireContext(), SHOP_URL));

    mSearch = view.findViewById(R.id.box_search);
    final int[] dots = {R.id.box_step0_dot, R.id.box_step1_dot, R.id.box_step2_dot, R.id.box_step3_dot};
    final int[] steps = {R.id.box_step0, R.id.box_step1, R.id.box_step2, R.id.box_step3};
    for (int i = 0; i < mSteps.length; i++)
    {
      mStepDots[i] = view.findViewById(dots[i]);
      mSteps[i] = view.findViewById(steps[i]);
    }
    mStepHint = view.findViewById(R.id.box_step_hint);
    mStepAction = view.findViewById(R.id.box_step_action);
    mStepAction.setOnClickListener(v -> onStepAction());
    final int[] rings = {R.id.box_ring0, R.id.box_ring1, R.id.box_ring2};
    for (int i = 0; i < mRings.length; i++)
      mRings[i] = view.findViewById(rings[i]);

    mGpsPage = view.findViewById(R.id.box_gps_page);
    mGpsView = view.findViewById(R.id.box_gps_view);
    setUpHeader(view, R.id.box_gps_header, R.string.nogps_status_gps);

    mCarsPage = view.findViewById(R.id.box_cars_page);
    setUpHeader(view, R.id.box_cars_header, R.string.nogps_cars);
    mCars = view.findViewById(R.id.box_cars);
    mAddCar = view.findViewById(R.id.box_add_car);
    mAddCar.setOnClickListener(v -> showPage(Page.ADD_CAR));
    mAddCarPage = view.findViewById(R.id.box_add_car_page);
    setUpHeader(view, R.id.box_add_car_header, R.string.nogps_car_add);

    mPhonesPage = view.findViewById(R.id.box_phones_page);
    setUpHeader(view, R.id.box_phones_header, R.string.nogps_car_phones);
    mPhonesRows = view.findViewById(R.id.box_phones_rows);
    mPhonesReadOnly = view.findViewById(R.id.box_phones_read_only);
    mAddPhone = view.findViewById(R.id.box_add_phone);
    mAddPhone.setOnClickListener(v -> addPhone());

    mBoxPage = view.findViewById(R.id.box_box_page);
    setUpHeader(view, R.id.box_box_header, R.string.nogps_box_title);
    mReadiness = view.findViewById(R.id.box_readiness);
    mSections[SECTION_BOX] = new Section(view, R.id.box_section_box, R.id.box_section_box_content);
    mSections[SECTION_CAR] = new Section(view, R.id.box_section_car, R.id.box_section_car_content);
    mSections[SECTION_SPEED] = new Section(view, R.id.box_section_speed, R.id.box_section_speed_content);
    mSections[SECTION_IMU] = new Section(view, R.id.box_section_imu, R.id.box_section_imu_content);
    for (int i = 0; i < mSections.length; ++i)
    {
      final int section = i;
      mSections[i].header.setOnClickListener(v -> {
        mUnfolded[section] = !mUnfolded[section];
        TransitionManager.beginDelayedTransition(mRoot);
        update();
      });
    }
    // Always open: it tells why the car gives no speed.
    mObdSection = new Section(view, R.id.box_section_obd, R.id.box_values_obd);
    mObdSection.chevron.setVisibility(View.GONE);
    mObdSection.header.setClickable(false);
    mObdSection.header.setBackground(null);
    mReadOnly = view.findViewById(R.id.box_read_only);
    mFirmwareRow = view.findViewById(R.id.box_firmware_row);
    mFirmware = view.findViewById(R.id.box_firmware);
    mFirmwareAction = view.findViewById(R.id.box_firmware_action);
    mFirmwareAction.setOnClickListener(v -> onFirmwareAction());
    mSpeed = view.findViewById(R.id.box_speed);
    mVoltageMismatch = view.findViewById(R.id.box_voltage_mismatch);
    mSpeedScale = view.findViewById(R.id.box_speed_scale);
    mRoughSpeed = view.findViewById(R.id.box_rough_speed);
    mSpeedLagValue = view.findViewById(R.id.box_speed_lag_value);
    mSpeedLagSource = view.findViewById(R.id.box_speed_lag_source);
    mSpeedTableRows = view.findViewById(R.id.box_speed_table_rows);
    view.findViewById(R.id.box_clear_speed).setOnClickListener(v -> confirmClearSpeed());
    mCalibrationRow = view.findViewById(R.id.box_calibration_row);
    mCalibrationRow.setOnClickListener(v -> showPage(Page.CALIBRATION));
    mValueGroups[0] = view.findViewById(R.id.box_values_car);
    mValueGroups[1] = view.findViewById(R.id.box_values_imu);
    mValueGroups[2] = view.findViewById(R.id.box_values_obd);
    mValueGroups[3] = view.findViewById(R.id.box_values_box);

    mCalibrationPage = view.findViewById(R.id.box_calibration_page);
    setUpHeader(view, R.id.box_calibration_header, R.string.nogps_box_calibration);
    mCalibrationState = view.findViewById(R.id.box_calibration_state);
    mCalibrationProgress = view.findViewById(R.id.box_calibration_progress);
    mCalibrationResult = view.findViewById(R.id.box_calibration_result);
    mCalibrate = view.findViewById(R.id.box_calibrate);
    mCalibrate.setOnClickListener(v -> {
      // The box may have gone out of reach since the button was drawn.
      if (calibrateDisabledReason(NoGps.getStatus()) == 0)
        NoGps.nativeCalibrate();
      update();
    });
    mCalibrateReason = view.findViewById(R.id.box_calibrate_reason);
    return view;
  }

  private void setUpHeader(@NonNull View root, int id, @StringRes int title)
  {
    final View header = root.findViewById(id);
    ((TextView) header.findViewById(R.id.page_title)).setText(title);
    header.findViewById(R.id.page_back).setOnClickListener(v -> showPage(mPage.parent()));
  }

  @Override
  public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState)
  {
    super.onViewCreated(view, savedInstanceState);
    ((ComponentDialog) requireDialog())
        .getOnBackPressedDispatcher()
        .addCallback(getViewLifecycleOwner(), mBackFromPage);
    // Each page is as high as its rows, a long one scrolls. Pulled down, the sheet closes.
    final BottomSheetBehavior<?> behavior = getBehavior();
    behavior.setSkipCollapsed(true);
    behavior.setState(BottomSheetBehavior.STATE_EXPANDED);
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
    // The code is not shown without the sheet that updates it.
    if (mAddPhoneDialog != null)
      mAddPhoneDialog.dismiss();
    animateRings(false);
    mTile.pulse(false);
    mGpsTile.pulse(false);
    mGpsView.stop();
  }

  /**
   * Called on the sheet shown already, e.g. by the firmware offer.
   */
  private void open(@NonNull Page page, boolean unfoldBox)
  {
    if (unfoldBox)
      mUnfolded[SECTION_BOX] = true;
    showPage(page);
  }

  /**
   * The page opened comes from the end as a new screen does, and goes back there.
   */
  private void showPage(@NonNull Page page)
  {
    final Page from = mPage;
    if (page == from)
    {
      update();
      return;
    }
    if (from == Page.ADD_CAR)
      stopAddingCar();
    mPage = page;
    if (page == Page.ADD_CAR)
      startAddingCar();
    else if (page == Page.PHONES)
      NoGps.nativeListBoxPhones();
    final boolean deeper = page.depth() > from.depth();
    final Slide in = new Slide(deeper ? Gravity.END : Gravity.START);
    final Slide out = new Slide(deeper ? Gravity.START : Gravity.END);
    for (View view : pageViews(page))
      in.addTarget(view);
    for (View view : pageViews(from))
      out.addTarget(view);
    TransitionManager.beginDelayedTransition(mRoot, new TransitionSet().addTransition(in).addTransition(out));
    update();
    getBehavior().setState(BottomSheetBehavior.STATE_EXPANDED);
  }

  @NonNull
  private View[] pageViews(@NonNull Page page)
  {
    return switch (page)
    {
      case MAIN -> new View[] {mMain, mSearch, mShop};
      case GPS -> new View[] {mGpsPage};
      case CARS -> new View[] {mCarsPage};
      case PHONES -> new View[] {mPhonesPage};
      case ADD_CAR -> new View[] {mAddCarPage, mSearch};
      case BOX -> new View[] {mBoxPage};
      case CALIBRATION -> new View[] {mCalibrationPage};
    };
  }

  private void update()
  {
    final NoGps.Status status = NoGps.getStatus();
    // The box connected while it was searched: the sheet shows it as any other.
    if (mSearching && isBoxHeard(status))
      mSearching = false;
    if (mPage == Page.ADD_CAR && isCarAdded())
    {
      showPage(Page.CARS);
      return;
    }
    // The box has disconnected: its phones are not known.
    if (mPage == Page.PHONES && !status.boxHasPhones)
    {
      showPage(Page.CARS);
      return;
    }
    // The pages of a box set up, e.g. after the box has removed this phone.
    if (mPage != Page.MAIN && mPage != Page.GPS && (mSearching || !status.inertialEnabled))
    {
      showPage(Page.MAIN);
      return;
    }
    updateAddPhone(status);
    mBackFromPage.setEnabled(mPage != Page.MAIN);
    for (Page page : Page.values())
    {
      if (page != mPage)
        for (View view : pageViews(page))
          view.setVisibility(View.GONE);
    }
    mMain.setVisibility(mPage == Page.MAIN ? View.VISIBLE : View.GONE);
    mShop.setVisibility(mPage == Page.MAIN ? View.VISIBLE : View.GONE);
    mSearch.setVisibility((mPage == Page.MAIN && mSearching) || mPage == Page.ADD_CAR ? View.VISIBLE : View.GONE);
    for (View view : pageViews(mPage))
    {
      if (view != mSearch && view != mShop)
        view.setVisibility(View.VISIBLE);
    }
    if (mPage != Page.ADD_CAR && !(mPage == Page.MAIN && mSearching))
      animateRings(false);
    switch (mPage)
    {
    case MAIN -> updateMain(status);
    case GPS -> mGpsView.update(status);
    case CARS -> updateCars(status);
    case PHONES -> updatePhones(status);
    case ADD_CAR -> updateSearch(status);
    case BOX -> updateBoxPage(status);
    case CALIBRATION -> updateCalibration(status);
    }
  }

  private void updateMain(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final boolean boxSetUp = status.inertialEnabled && !mSearching;
    final NoGps.Car[] cars = boxSetUp ? NoGps.nativeGetCars() : new NoGps.Car[0];
    NoGps.Car current = null;
    for (NoGps.Car car : cars)
    {
      if (car.id.equals(status.carId))
        current = car;
    }
    mTitle.setText(current != null ? BoxTexts.carName(context, current) : getString(R.string.nogps_box_title));
    mTitle.setClickable(cars.length > 0);
    mTitle.setCompoundDrawablesRelativeWithIntrinsicBounds(0, 0, cars.length > 0 ? R.drawable.ic_nogps_chevron : 0, 0);
    mBox.setClickable(boxSetUp);
    mBoxChevron.setVisibility(boxSetUp ? View.VISIBLE : View.GONE);
    if (mSearching)
      updateSearch(status);
    else
      showBox(StatusBar.getBoxLook(status), status.inertialEnabled ? BoxTexts.boxStateText(context, status)
                                                                   : getString(R.string.nogps_box_buy_title));
    final int linkAction = boxSetUp ? linkActionText(status) : 0;
    mBluetooth.setVisibility(linkAction != 0 ? View.VISIBLE : View.GONE);
    if (linkAction != 0)
      mBluetooth.setText(linkAction);
    updateGps(status);
    // Without a box the offer stands out.
    mShopOffer.setVisibility(boxSetUp ? View.GONE : View.VISIBLE);
    mBuyAnother.setVisibility(boxSetUp ? View.VISIBLE : View.GONE);
  }

  private void updateGps(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final StatusBar.Look look = StatusBar.getGpsLook(context, status);
    mGpsTile.show(look);
    final String state = StatusBar.getGpsStateText(context, status);
    showState(mGpsState, look, state);
    mGpsRow.setContentDescription(getString(R.string.nogps_status_gps) + ": " + state);
    // GPS is blocked for the car only while the box can drive it: nothing would move the mark otherwise.
    final boolean canSwitch = status.gpsDisabled || isBoxHeard(status);
    mGpsBlock.setEnabled(canSwitch);
    if (!mGpsBlock.isPressed())
      mGpsBlock.setChecked(status.gpsDisabled);
    mGpsBlockHint.setVisibility(canSwitch ? View.VISIBLE : View.INVISIBLE);
    mGpsBlockNeedsBox.setVisibility(canSwitch ? View.INVISIBLE : View.VISIBLE);

    // Off until the app is picked as the mock location app, the hint tells where.
    final boolean shareAllowed = MockLocationShare.isAllowed(context);
    if (mShareAsked && shareAllowed)
    {
      mShareAsked = false;
      MockLocationShare.setEnabled(true);
    }
    // Also unpicked since the share was turned on.
    final boolean shareNeedsMock = (mShareAsked || MockLocationShare.isEnabled()) && !shareAllowed;
    if (!mSharePosition.isPressed())
      mSharePosition.setChecked(MockLocationShare.isEnabled() && shareAllowed);
    mSharePositionNeedsMock.setVisibility(shareNeedsMock ? View.VISIBLE : View.GONE);
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

  /**
   * The box sends its data: it is connected, whatever it tells.
   */
  static boolean isBoxHeard(@NonNull NoGps.Status status)
  {
    final NoGps.SourceState state = status.getSourceState();
    return status.inertialStarted && state != NoGps.SourceState.DISCONNECTED && state != NoGps.SourceState.CONNECTING;
  }

  /**
   * The box tells the car data and its calibration only while it is in reach.
   */
  private static boolean isConnected(@NonNull NoGps.Status status)
  {
    return isBoxHeard(status) && status.getBleState() == NoGps.BleState.CONNECTED;
  }

  /**
   * The phone can't look for the box until the user turns Bluetooth on or allows it in the settings.
   */
  private static boolean isBluetoothFailed(@NonNull NoGps.Status status)
  {
    final NoGps.BleState ble = status.getBleState();
    return ble == NoGps.BleState.OFF || ble == NoGps.BleState.DISABLED || ble == NoGps.BleState.NO_PERMISSION;
  }

  /**
   * What the user does for the phone to reach the box, 0 if nothing: the steps and their button tell the rest.
   */
  static int linkHintText(@NonNull NoGps.Status status)
  {
    return switch (status.getBleState())
    {
      case PAIRING_CLOSED -> R.string.nogps_box_bt_pairing_closed;
      case PAIRING_BY_PHONE -> R.string.nogps_box_bt_pairing_by_phone;
      case PAIRING_FULL -> R.string.nogps_box_bt_pairing_full;
      case PAIRING -> R.string.nogps_box_bt_pairing;
      case PAIRING_FAILED -> R.string.nogps_box_bt_pairing_failed;
      case BOND_LOST -> R.string.nogps_box_bt_bond_lost;
      default -> 0;
    };
  }

  /**
   * What the user does for the box to get the car speed, 0 if nothing.
   */
  static int obdHintText(@NonNull NoGps.Status status)
  {
    if (!isConnected(status))
      return 0;
    return switch (status.getSourceState())
    {
      // The box retries the search of the car protocol while the car is silent: one text for both.
      case NO_CAR_DATA, OBD_CONNECTING -> R.string.nogps_box_hint_no_car;
      case NO_ADAPTER -> R.string.nogps_box_hint_no_adapter;
      case OBD_ERROR -> R.string.nogps_box_hint_obd_error;
      case OBD_DISABLED -> R.string.nogps_box_hint_obd_disabled;
      default -> 0;
    };
  }

  /**
   * The button of the steps and of a box set up, 0 if none.
   */
  private int linkActionText(@NonNull NoGps.Status status)
  {
    if (isBluetoothFailed(status))
      return bluetoothActionText(status);
    return switch (status.getBleState())
    {
      case PAIRING_FAILED -> R.string.nogps_box_try_again;
      // The search starts again when the pairing is removed there.
      case BOND_LOST -> R.string.nogps_box_bluetooth_settings;
      default -> 0;
    };
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

  @NonNull
  private String carStateText(@NonNull NoGps.Status status, @NonNull NoGps.Car car)
  {
    if (car.id.equals(status.carId))
      return getString(isConnected(status) ? R.string.nogps_car_connected : R.string.nogps_car_current);
    if (car.lastSeenUnixMs <= 0)
      return "";
    final CharSequence when =
        DateUtils.getRelativeTimeSpanString(car.lastSeenUnixMs, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS);
    return getString(R.string.nogps_car_last_seen, when);
  }

  private void updateCars(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final NoGps.Car[] cars = NoGps.nativeGetCars();
    mAddCar.setVisibility(cars.length < NoGps.nativeGetMaxCars() ? View.VISIBLE : View.GONE);
    final List<String> texts = new ArrayList<>();
    for (NoGps.Car car : cars)
    {
      texts.add(BoxTexts.carName(context, car));
      texts.add(carStateText(status, car));
    }
    if (texts.equals(mCarTexts))
      return;
    mCarTexts = texts;
    mCars.removeAllViews();
    final LayoutInflater inflater = LayoutInflater.from(context);
    for (int i = 0; i < cars.length; ++i)
    {
      final NoGps.Car car = cars[i];
      final View row = inflater.inflate(R.layout.nogps_car_row, mCars, false);
      ((TextView) row.findViewById(R.id.car_name)).setText(texts.get(2 * i));
      final TextView state = row.findViewById(R.id.car_state);
      state.setText(texts.get(2 * i + 1));
      state.setVisibility(texts.get(2 * i + 1).isEmpty() ? View.GONE : View.VISIBLE);
      row.setOnClickListener(v -> showCarMenu(car));
      mCars.addView(row);
    }
  }

  /**
   * What the user does with a car: drives it, names it or forgets it.
   */
  private void showCarMenu(@NonNull NoGps.Car car)
  {
    final Context context = requireContext();
    final boolean current = car.id.equals(NoGps.getStatus().carId);
    final List<String> items = new ArrayList<>();
    final List<Runnable> actions = new ArrayList<>();
    if (!current)
    {
      items.add(getString(R.string.nogps_car_drive));
      actions.add(() -> {
        NoGps.nativeSelectCar(car.id);
        update();
      });
    }
    if (current && NoGps.getStatus().boxHasPhones)
    {
      items.add(getString(R.string.nogps_car_phones));
      actions.add(() -> showPage(Page.PHONES));
    }
    items.add(getString(R.string.nogps_car_rename));
    actions.add(() -> renameCar(car));
    items.add(getString(R.string.nogps_car_forget));
    actions.add(() -> confirmForgetCar(car));
    new MaterialAlertDialogBuilder(context)
        .setTitle(BoxTexts.carName(context, car))
        .setItems(items.toArray(new String[0]), (dialog, which) -> actions.get(which).run())
        .setNegativeButton(R.string.cancel, null)
        .show();
  }

  private void renameCar(@NonNull NoGps.Car car)
  {
    final Context context = requireContext();
    final EditText name = new EditText(context);
    name.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
    name.setSingleLine();
    name.setText(car.name);
    name.setHint(context.getString(app.organicmaps.sdk.R.string.nogps_car_default_name, car.id));
    name.setSelection(name.getText().length());
    final FrameLayout frame = new FrameLayout(context);
    frame.setPadding(dp(24), dp(8), dp(24), 0);
    frame.addView(name);
    new MaterialAlertDialogBuilder(context)
        .setTitle(R.string.nogps_car_name)
        .setView(frame)
        .setPositiveButton(R.string.save,
                           (dialog, which) -> {
                             NoGps.nativeRenameCar(car.id, name.getText().toString());
                             update();
                           })
        .setNegativeButton(R.string.cancel, null)
        .show();
  }

  private void confirmForgetCar(@NonNull NoGps.Car car)
  {
    final Context context = requireContext();
    new MaterialAlertDialogBuilder(context)
        .setTitle(BoxTexts.carName(context, car))
        .setMessage(R.string.nogps_car_forget_text)
        .setPositiveButton(R.string.nogps_car_forget,
                           (dialog, which) -> {
                             MwmApplication.from(context).getLocationHelper().forgetCar(car.id);
                             // The last car: the box is not looked for, the sheet offers to buy one.
                             if (!NoGps.getStatus().inertialEnabled)
                               dismiss();
                             else
                               update();
                           })
        .setNegativeButton(R.string.cancel, null)
        .show();
  }

  /**
   * The box of the new car is searched step by step, as the first one: the box connected now is dropped.
   */
  private void startAddingCar()
  {
    mCarsBeforeAdd = NoGps.nativeGetCars().length;
    MwmApplication.from(requireContext()).getLocationHelper().searchNewBox(true);
  }

  /**
   * Left before the box of the new car was heard: the boxes of the other cars are looked for again.
   */
  private void stopAddingCar()
  {
    if (!isCarAdded())
      MwmApplication.from(requireContext()).getLocationHelper().searchNewBox(false);
  }

  /**
   * The box of a new car, or of a forgotten one, has told about itself.
   */
  private boolean isCarAdded()
  {
    return NoGps.nativeGetCars().length > mCarsBeforeAdd;
  }

  private void updatePhones(@NonNull NoGps.Status status)
  {
    mPhonesReadOnly.setVisibility(status.boxReadOnly ? View.VISIBLE : View.GONE);
    mAddPhone.setEnabled(!status.boxReadOnly);
    final Context context = requireContext();
    final List<String> texts = new ArrayList<>();
    for (NoGps.Phone phone : status.boxPhones)
    {
      texts.add(phone.name.isEmpty() ? getString(R.string.nogps_phone_unnamed) : phone.name);
      texts.add(phoneStateText(phone));
    }
    // The rows keep the phones they remove: two phones may look the same.
    for (NoGps.Phone phone : status.boxPhones)
      texts.add(phone.address);
    texts.add(String.valueOf(status.boxReadOnly));
    if (texts.equals(mPhoneTexts))
      return;
    mPhoneTexts = texts;
    mPhonesRows.removeAllViews();
    final LayoutInflater inflater = LayoutInflater.from(context);
    for (int i = 0; i < status.boxPhones.length; ++i)
    {
      final NoGps.Phone phone = status.boxPhones[i];
      final String name = texts.get(2 * i);
      final View row = inflater.inflate(R.layout.nogps_car_row, mPhonesRows, false);
      ((TextView) row.findViewById(R.id.car_name)).setText(name);
      final TextView state = row.findViewById(R.id.car_state);
      state.setText(texts.get(2 * i + 1));
      state.setVisibility(texts.get(2 * i + 1).isEmpty() ? View.GONE : View.VISIBLE);
      if (!status.boxReadOnly)
        row.setOnClickListener(v -> confirmRemovePhone(phone, name));
      else
        row.setClickable(false);
      mPhonesRows.addView(row);
    }
  }

  @NonNull
  private String phoneStateText(@NonNull NoGps.Phone phone)
  {
    if (phone.thisPhone)
      return getString(R.string.nogps_phone_this);
    if (phone.seenUnixS <= 0)
      return "";
    final CharSequence when = DateUtils.getRelativeTimeSpanString(phone.seenUnixS * 1000, System.currentTimeMillis(),
                                                                  DateUtils.MINUTE_IN_MILLIS);
    return getString(R.string.nogps_car_last_seen, when);
  }

  private void confirmRemovePhone(@NonNull NoGps.Phone phone, @NonNull String name)
  {
    new MaterialAlertDialogBuilder(requireContext())
        .setTitle(name)
        .setMessage(phone.thisPhone ? R.string.nogps_phone_remove_this_text : R.string.nogps_phone_remove_text)
        .setPositiveButton(R.string.nogps_phone_remove,
                           (dialog, which) -> {
                             NoGps.nativeForgetBoxPhone(phone.address);
                             update();
                           })
        .setNegativeButton(R.string.cancel, null)
        .show();
  }

  /**
   * The box takes a new phone with a code shown here: the user enters it on the new phone.
   */
  private void addPhone()
  {
    NoGps.nativeStartAddPhone();
    mAddPhoneDialog = new MaterialAlertDialogBuilder(requireContext())
                          .setTitle(R.string.nogps_phone_add)
                          .setMessage(R.string.nogps_phone_add_opening)
                          .setPositiveButton(R.string.close, null)
                          .setOnDismissListener(dialog -> {
                            mAddPhoneDialog = null;
                            NoGps.nativeEndAddPhone();
                          })
                          .show();
    update();
  }

  private void updateAddPhone(@NonNull NoGps.Status status)
  {
    if (mAddPhoneDialog == null)
      return;
    final String text = switch (status.getAddPhone())
    {
      case NONE, OPENING -> getString(R.string.nogps_phone_add_opening);
      case OPEN ->
        status.addPhoneCode + "\n\n"
            + getString(R.string.nogps_phone_add_code, DateUtils.formatElapsedTime(status.addPhoneSecondsLeft));
      case ADDED -> getString(R.string.nogps_phone_added);
      case EXPIRED -> getString(R.string.nogps_phone_add_expired);
      case FULL -> getString(R.string.nogps_phone_add_full);
      case FAILED -> getString(R.string.nogps_phone_add_failed);
    };
    mAddPhoneDialog.setMessage(text);
  }

  private void updateBoxPage(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final boolean connected = isConnected(status);
    updateReadiness(status);
    updateValues(status);

    final String firmware = BoxTexts.firmwareText(context, status);
    final String boxState = BoxTexts.boxStateText(context, status);
    mSections[SECTION_BOX].show(getString(R.string.nogps_box_value_group_box),
                                firmware.isEmpty() ? boxState : boxState + " · " + firmware);
    // Another phone calibrates and updates the box.
    mReadOnly.setVisibility(connected && status.boxReadOnly ? View.VISIBLE : View.GONE);
    final NoGps.FirmwareUpdate update = status.getFirmwareUpdate();
    final boolean updating = BoxTexts.isUpdating(update);
    mFirmwareRow.setVisibility(updating || !status.boxFirmware.isEmpty() ? View.VISIBLE : View.GONE);
    mFirmware.setText(getString(R.string.nogps_sensors_firmware, firmware));
    // A box that has taken the firmware restarts by itself.
    final boolean cancel = updating && update != NoGps.FirmwareUpdate.RESTARTING;
    final boolean install = BoxTexts.canInstallFirmware(status);
    mFirmwareAction.setVisibility(cancel || install ? View.VISIBLE : View.GONE);
    if (cancel)
      mFirmwareAction.setText(R.string.cancel);
    else if (install)
      mFirmwareAction.setText(getString(R.string.nogps_firmware_install, status.bundledFirmware));

    final int obdHint = obdHintText(status);
    mObdSection.show(getString(R.string.nogps_box_value_group_obd), obdHint != 0 ? getString(obdHint) : boxState);

    final NoGps.Car car = currentCar(status);
    mSections[SECTION_CAR].show(
        car != null ? BoxTexts.carName(context, car) : getString(R.string.nogps_box_value_group_car),
        getString(status.engineRunning < 0   ? R.string.nogps_unknown
                  : status.engineRunning > 0 ? R.string.nogps_engine_running
                                             : R.string.nogps_engine_stopped));
    mSpeed.setText(getString(R.string.nogps_sensors_speed, connected && status.speedKmh >= 0
                                                               ? getString(R.string.nogps_speed_kmh, status.speedKmh)
                                                               : getString(R.string.nogps_unknown)));

    mSections[SECTION_SPEED].show(getString(R.string.nogps_speed_calibration),
                                  BoxTexts.speedTableText(context, status));
    mSpeedScale.setText(getString(R.string.nogps_sensors_scale, String.format(Locale.US, "×%.2f", status.speedScale),
                                  status.speedTableRanges));
    // Until GPS measures the speed, e.g. on the first trip, it is corrected roughly by the roads.
    mRoughSpeed.setVisibility(status.speedTableRanges == 0 ? View.VISIBLE : View.GONE);
    mRoughSpeed.setText(status.roughSpeedTableRanges > 0
                            ? getString(R.string.nogps_sensors_rough_speed, status.roughSpeedTableRanges)
                            : getString(R.string.nogps_sensors_rough_speed_learning));
    mSpeedLagValue.setText(
        getString(R.string.nogps_speed_lag_value, String.format(Locale.US, "%.1f", status.speedLagSec)));
    mSpeedLagSource.setText(status.speedLagMeasured ? R.string.nogps_speed_lag_measured
                                                    : R.string.nogps_speed_lag_usual);
    updateSpeedTable(status);

    final List<String> imu = new ArrayList<>();
    for (int i = 0; i < mValueIds.length; ++i)
    {
      final NoGps.BoxValue id = mValueIds[i];
      if ((id == NoGps.BoxValue.IMU_STATE || id == NoGps.BoxValue.IMU_TEMPERATURE) && connected
          && !mValues[i].isEmpty())
        imu.add(BoxTexts.boxValueText(context, status, id, mValues[i]));
    }
    mSections[SECTION_IMU].show(getString(R.string.nogps_box_value_group_gyroscope),
                                imu.isEmpty() ? getString(R.string.nogps_unknown) : String.join(" · ", imu));
    mCalibrationRow.setText(getString(R.string.nogps_sensors_box_sensors,
                                      BoxTexts.boxCalibrationText(context, status, calibration(status))));

    for (int i = 0; i < mSections.length; ++i)
    {
      // The speed is learned while the box leads the car.
      final boolean visible = i != SECTION_SPEED || status.inertialStarted;
      mSections[i].setVisible(visible);
      if (visible)
        mSections[i].setOpen(mUnfolded[i]);
    }
  }

  @Nullable
  private static NoGps.Car currentCar(@NonNull NoGps.Status status)
  {
    for (NoGps.Car car : NoGps.nativeGetCars())
    {
      if (car.id.equals(status.carId))
        return car;
    }
    return null;
  }

  @NonNull
  private static NoGps.CalibrationState calibration(@NonNull NoGps.Status status)
  {
    return status.inertialStarted ? status.getCalibration() : NoGps.CalibrationState.NONE;
  }

  /**
   * What the box still needs to lead the car, while it does.
   */
  private void updateReadiness(@NonNull NoGps.Status status)
  {
    mReadiness.setVisibility(status.inertialStarted ? View.VISIBLE : View.GONE);
    if (!status.inertialStarted)
      return;
    final List<String> missing = new ArrayList<>();
    if (status.speedKmh < 0)
      missing.add(getString(R.string.nogps_missing_speed));
    if (status.getCalibration() != NoGps.CalibrationState.DONE)
      missing.add(getString(R.string.nogps_missing_box_calibration));
    if (!status.hasInertialPosition)
      missing.add(getString(R.string.nogps_missing_position));
    mReadiness.setText(missing.isEmpty() ? getString(R.string.nogps_sensors_ready)
                                         : getString(R.string.nogps_sensors_not_ready, String.join(", ", missing)));
    mReadiness.setTextColor(ContextCompat.getColor(
        requireContext(), missing.isEmpty() ? R.color.nogps_status_gps : R.color.nogps_status_none));
  }

  /**
   * The values the box sends while it is connected. Out of reach, the last ones are shown without their values.
   */
  private void updateValues(@NonNull NoGps.Status status)
  {
    final boolean live = status.boxValues.length > 0;
    if (live)
    {
      final NoGps.BoxValue[] ids = new NoGps.BoxValue[status.boxValues.length];
      for (int i = 0; i < ids.length; ++i)
        ids[i] = status.getBoxValueId(i);
      if (!Arrays.equals(ids, mValueIds))
        makeValueRows(ids);
      mValues = status.boxValues.clone();
    }
    else
    {
      Arrays.fill(mValues, "");
    }
    boolean mismatch = false;
    for (int i = 0; i < mValueIds.length; ++i)
    {
      mValueTexts[i].setText(live ? BoxTexts.boxValueText(requireContext(), status, mValueIds[i], mValues[i])
                                  : getString(R.string.nogps_unknown));
      if (mValueIds[i] == NoGps.BoxValue.VOLTAGE_MISMATCH && mValues[i].equals("1"))
        mismatch = true;
    }
    mVoltageMismatch.setVisibility(mismatch ? View.VISIBLE : View.GONE);
  }

  private void makeValueRows(@NonNull NoGps.BoxValue[] ids)
  {
    final LayoutInflater inflater = LayoutInflater.from(requireContext());
    for (LinearLayout group : mValueGroups)
      group.removeAllViews();
    mValueIds = ids;
    mValues = new String[ids.length];
    mValueTexts = new TextView[ids.length];
    // The values come in the order of the groups.
    final NoGps.BoxValue[] groupStarts = {NoGps.BoxValue.ENGINE, NoGps.BoxValue.IMU_NAME, NoGps.BoxValue.OBD_STATE,
                                          NoGps.BoxValue.FIRMWARE};
    for (int i = 0; i < ids.length; ++i)
    {
      int group = 0;
      while (group + 1 < groupStarts.length && ids[i].ordinal() >= groupStarts[group + 1].ordinal())
        ++group;
      final View row = inflater.inflate(R.layout.nogps_sheet_row, mValueGroups[group], false);
      ((TextView) row.findViewById(R.id.row_label)).setText(BoxTexts.boxValueLabel(ids[i]));
      mValueTexts[i] = row.findViewById(R.id.row_value);
      mValueGroups[group].addView(row);
    }
  }

  private void updateSpeedTable(@NonNull NoGps.Status status)
  {
    final int ranges = status.speedTableCarM.length;
    while (mSpeedTableRows.getChildCount() < ranges)
    {
      final TextView row = new TextView(requireContext());
      row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
      row.setFontFeatureSettings("tnum");
      row.setMinHeight(dp(28));
      row.setGravity(Gravity.CENTER_VERTICAL);
      mSpeedTableRows.addView(row);
    }
    for (int i = 0; i < mSpeedTableRows.getChildCount(); ++i)
    {
      final TextView row = (TextView) mSpeedTableRows.getChildAt(i);
      row.setVisibility(i < ranges ? View.VISIBLE : View.GONE);
      if (i < ranges)
        row.setText(BoxTexts.speedTableRowText(requireContext(), status, i));
    }
  }

  /**
   * The row does what it shows, if the update still allows it: the box may have gone on since it was drawn.
   */
  private void onFirmwareAction()
  {
    final NoGps.Status status = NoGps.getStatus();
    final NoGps.FirmwareUpdate update = status.getFirmwareUpdate();
    if (BoxTexts.isUpdating(update) && update != NoGps.FirmwareUpdate.RESTARTING)
      NoGps.nativeCancelFirmwareUpdate();
    else if (BoxTexts.canInstallFirmware(status))
      NoGps.nativeStartFirmwareUpdate();
    update();
  }

  private void confirmClearSpeed()
  {
    new MaterialAlertDialogBuilder(requireContext())
        .setTitle(R.string.nogps_clear_speed_title)
        .setMessage(R.string.nogps_clear_speed_message)
        .setPositiveButton(R.string.nogps_clear_speed,
                           (dialog, which) -> {
                             NoGps.nativeClearSpeedCalibration();
                             update();
                           })
        .setNegativeButton(R.string.cancel, null)
        .show();
  }

  private void updateCalibration(@NonNull NoGps.Status status)
  {
    final NoGps.CalibrationState calibration = calibration(status);
    mCalibrationState.setText(getString(R.string.nogps_sensors_box_sensors,
                                        BoxTexts.boxCalibrationText(requireContext(), status, calibration)));
    final boolean calibrating = calibration == NoGps.CalibrationState.CALIBRATING;
    mCalibrationProgress.setVisibility(calibrating ? View.VISIBLE : View.GONE);
    mCalibrationProgress.setProgress(status.calibrationProgress);
    // What the user does after a failure.
    final int result = switch (calibration)
    {
      case FAILED_MOVING -> R.string.nogps_calibration_failed_moving;
      case MOUNT_MOVED -> R.string.nogps_calibration_failed_mount;
      case LINK_LOST -> R.string.nogps_calibration_failed_link;
      default -> 0;
    };
    mCalibrationResult.setVisibility(result != 0 ? View.VISIBLE : View.GONE);
    if (result != 0)
      mCalibrationResult.setText(result);
    mCalibrate.setVisibility(calibrating ? View.GONE : View.VISIBLE);
    mCalibrate.setText(calibration == NoGps.CalibrationState.DONE && !status.boxCalibrationAdvised
                           ? R.string.nogps_box_recalibrate
                           : R.string.nogps_sensors_calibrate_box);
    final int reason = calibrateDisabledReason(status);
    mCalibrate.setEnabled(reason == 0);
    mCalibrateReason.setVisibility(reason != 0 && !calibrating ? View.VISIBLE : View.GONE);
    if (reason != 0)
      mCalibrateReason.setText(reason);
  }

  /**
   * The box calibrates itself: there is nobody to calibrate while it is out of reach, and the phone that connected to
   * it first calibrates it.
   * @return 0 if the box can be calibrated now.
   */
  @StringRes
  private static int calibrateDisabledReason(@NonNull NoGps.Status status)
  {
    if (!isConnected(status))
      return R.string.nogps_calibration_needs_box;
    return status.boxReadOnly ? R.string.nogps_box_read_only : 0;
  }

  private int dp(int value)
  {
    return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
  }

  private void updateSearch(@NonNull NoGps.Status status)
  {
    final NoGps.BleState ble = status.getBleState();
    final boolean bluetoothFailed = isBluetoothFailed(status);
    showBox(new StatusBar.Look(R.drawable.ic_nogps_box, 0), getString(R.string.nogps_box_searching));
    final boolean searched = ble == NoGps.BleState.SEARCHING || ble == NoGps.BleState.PAIRING_CLOSED
                          || ble == NoGps.BleState.PAIRING_BY_PHONE || ble == NoGps.BleState.PAIRING_FULL;
    final boolean connecting = ble == NoGps.BleState.CONNECTING || ble == NoGps.BleState.PAIRING;
    final boolean connected = ble == NoGps.BleState.CONNECTED;
    final boolean linkFailed = ble == NoGps.BleState.PAIRING_FAILED || ble == NoGps.BleState.BOND_LOST;
    showStep(0, bluetoothFailed ? StepState.FAILED : StepState.DONE);
    showStep(1, connecting || connected || linkFailed ? StepState.DONE
                : searched                            ? StepState.CURRENT
                                                      : StepState.WAITING);
    showStep(2, connected    ? StepState.DONE
                : linkFailed ? StepState.FAILED
                : connecting ? StepState.CURRENT
                             : StepState.WAITING);
    showStep(3, connected ? StepState.CURRENT : StepState.WAITING);
    mSteps[0].setText(ble == NoGps.BleState.NO_PERMISSION
                          ? (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? R.string.nogps_box_step_nearby_denied
                                                                            : R.string.nogps_box_step_location_denied)
                      : isLocationOff(status) ? R.string.nogps_box_step_location_off
                      : bluetoothFailed       ? R.string.nogps_box_step_bluetooth_off
                                              : R.string.nogps_box_step_bluetooth);
    final int hint = linkHintText(status);
    mStepHint.setVisibility(hint != 0 ? View.VISIBLE : View.GONE);
    if (hint != 0)
      showState(mStepHint, new StatusBar.Look(0, 0), getString(hint));
    final int action = linkActionText(status);
    mStepAction.setVisibility(action != 0 ? View.VISIBLE : View.GONE);
    if (action != 0)
      mStepAction.setText(action);
    // Nothing is searched after a failed pairing or a lost bond until the user acts.
    animateRings(!bluetoothFailed && !linkFailed);
  }

  private void showBox(@NonNull StatusBar.Look look, @NonNull String text)
  {
    mTile.show(look);
    showState(mState, look, text);
    mBox.setContentDescription(getString(R.string.nogps_box_title) + ": " + mState.getText());
  }

  private void showState(@NonNull TextView state, @NonNull StatusBar.Look look, @NonNull String text)
  {
    state.setText(BoxTexts.capitalize(text));
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
    if (status.getBleState() == NoGps.BleState.PAIRING_FAILED)
    {
      MwmApplication.from(requireContext()).getLocationHelper().retryBox();
      update();
      return;
    }
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

  @NonNull
  private BottomSheetBehavior<?> getBehavior()
  {
    return ((BottomSheetDialog) requireDialog()).getBehavior();
  }

  @Override
  public void onDismiss(@NonNull DialogInterface dialog)
  {
    super.onDismiss(dialog);
    if (requireActivity().isChangingConfigurations())
      return;
    // Closed before the box was heard, even if connected already: the phone stops looking for it. The box of a car
    // being added: the boxes of the other cars are looked for again.
    if (mPage == Page.ADD_CAR)
      stopAddingCar();
    else if (mSearching && !isBoxHeard(NoGps.getStatus()))
      NoGps.nativeSetInertialNavigationEnabled(false);
    getParentFragmentManager().setFragmentResult(RESULT_CLOSED, Bundle.EMPTY);
  }
}
