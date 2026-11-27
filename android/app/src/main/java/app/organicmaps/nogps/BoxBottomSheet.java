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
import android.content.res.Configuration;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.text.format.DateUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.BaseAdapter;
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
import androidx.appcompat.content.res.AppCompatResources;
import androidx.appcompat.widget.ListPopupWindow;
import androidx.appcompat.widget.SwitchCompat;
import androidx.core.content.ContextCompat;
import androidx.core.widget.ImageViewCompat;
import androidx.core.widget.NestedScrollView;
import androidx.fragment.app.FragmentManager;
import androidx.transition.Slide;
import androidx.transition.TransitionManager;
import androidx.transition.TransitionSet;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.util.Utils;
import com.google.android.material.bottomsheet.BottomSheetBehavior;
import com.google.android.material.bottomsheet.BottomSheetDialog;
import com.google.android.material.bottomsheet.BottomSheetDialogFragment;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * The sensor box and GPS side by side, each opens its page, the current car opens its own. Under them GPS is blocked
 * for the car. Without a box it is searched while the sheet is open, step by step, and the sheet offers to buy one.
 */
public class BoxBottomSheet extends BottomSheetDialogFragment
{
  public static final String TAG = BoxBottomSheet.class.getSimpleName();
  // The fragment result told when the user closes the sheet: the bottom bar shows the box and GPS at once.
  public static final String RESULT_CLOSED = TAG + ".closed";
  private static final long UPDATE_INTERVAL_MS = 500;
  private static final long RING_DURATION_MS = 2400;
  private static final String BOX_NAME = "NonGPS-OBD";
  private static final String ARG_PAGE = "page";
  private static final String STATE_PAGE = "page";
  private static final String STATE_SEARCHING = "searching";
  private static final String STATE_CARS_BEFORE_ADD = "cars_before_add";

  /**
   * Each page is opened from its parent, Back returns there.
   */
  public enum Page
  {
    MAIN,
    GPS,
    CAR,
    ADD_CAR,
    BOX,
    // The items of the Box page.
    ITEM_BOX,
    ITEM_OBD,
    ITEM_CAR,
    ITEM_SPEED,
    ITEM_IMU,
    CALIBRATION,
    // The results of the timed runs, opened from the car page.
    SPRINT_TO_100,
    SPRINT_QUARTER_MILE;

    @NonNull
    Page parent()
    {
      return switch (this)
      {
        case MAIN, GPS, CAR, BOX -> MAIN;
        case ADD_CAR, SPRINT_TO_100, SPRINT_QUARTER_MILE -> CAR;
        case ITEM_BOX, ITEM_OBD, ITEM_CAR, ITEM_SPEED, ITEM_IMU -> BOX;
        case CALIBRATION -> ITEM_IMU;
      };
    }
  }

  private enum StepState
  {
    WAITING,
    CURRENT,
    DONE,
    FAILED,
  }

  /**
   * A row of the Box page and the page it opens, both with the title of the item.
   */
  private static final class Item
  {
    final View row;
    final TextView title;
    final TextView state;
    final TextView pageTitle;

    Item(@NonNull View row, @NonNull TextView pageTitle)
    {
      this.row = row;
      title = row.findViewById(R.id.section_title);
      state = row.findViewById(R.id.section_state);
      this.pageTitle = pageTitle;
    }

    void show(@NonNull String titleText, @NonNull String stateText)
    {
      title.setText(titleText);
      pageTitle.setText(titleText);
      state.setText(BoxTexts.capitalize(stateText));
      state.setVisibility(stateText.isEmpty() ? View.GONE : View.VISIBLE);
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
  // The code for a new phone, shown while the box takes it.
  @Nullable
  private AlertDialog mAddPhoneDialog;
  private TextView mAddPhoneCode;
  private TextView mAddPhoneMessage;
  // The phones of the box are asked for once while the box tells them.
  private boolean mPhonesListed;
  private final OnBackPressedCallback mBackFromPage = new OnBackPressedCallback(false) {
    @Override
    public void handleOnBackPressed()
    {
      showPage(mPage.parent());
    }
  };
  private ViewGroup mRoot;
  private NestedScrollView mScroll;
  private View mMain;
  private View mTitleRow;
  private TextView mTitle;
  private View mTitleSubtitle;
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
  private View mShop;
  private View mBuyText;
  private View mSearchBuyText;
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

  private View mAddCarPage;

  private View mCarPage;
  private TextView mCarPageTitle;
  private View mCarPageNameRow;
  private View mCarPageNameLabel;
  private TextView mCarPageName;
  private TextView mCarBoxState;
  // The drop-down of the cars over the title of the car page, null while it is closed.
  @Nullable
  private ListPopupWindow mCarMenu;
  private View mPhonesUnknown;
  private LinearLayout mPhonesRows;
  private View mPhonesReadOnly;
  private TextView mPhonesRecoveryCode;
  private TextView mAddPhone;
  private ColorStateList mAddPhoneColors;
  // The texts of the phone rows shown: the rows are made again when they change.
  private List<String> mPhoneTexts = new ArrayList<>();

  private View mBoxPage;
  private TextView mReadiness;
  private Item mItemBox;
  private Item mItemObd;
  private Item mItemCar;
  private Item mItemSpeed;
  private Item mItemImu;
  private View mBoxItemPage;
  private View mObdItemPage;
  private View mCarItemPage;
  private View mSpeedItemPage;
  private View mImuItemPage;
  private TextView mReadOnly;
  private View mFirmwareRow;
  private TextView mFirmware;
  private TextView mFirmwareAction;
  private TextView mSpeed;
  private View mCarNameRow;
  private TextView mCarName;
  private View mVoltageMismatch;
  private TextView mSpeedLagValue;
  private TextView mSpeedLagSource;
  private LinearLayout mSpeedTableRows;
  private TextView mCalibrationValue;
  // The values of the box by groups, in the order the box sends them: car, gyroscope, OBD, box.
  private final LinearLayout[] mValueGroups = new LinearLayout[4];
  // The values shown, the last ones while the box is out of reach: the rows are made again when the box sends other
  // fields.
  private NoGps.BoxValue[] mValueIds = new NoGps.BoxValue[0];
  private String[] mValues = new String[0];
  private TextView[] mValueTexts = new TextView[0];

  private final TextView[] mSprintBest = new TextView[2];
  private View mSprintPage;
  private TextView mSprintTitle;
  private LinearLayout mSprintRows;
  private View mSprintNone;

  private View mCalibrationPage;
  private TextView mCalibrationState;
  private ProgressBar mCalibrationProgress;
  private TextView mCalibrationResult;
  private Button mCalibrate;
  private TextView mCalibrateReason;

  /**
   * Shows the sheet at the page, or turns the sheet shown already to it.
   */
  public static void show(@NonNull FragmentManager manager, @NonNull Page page)
  {
    if (manager.findFragmentByTag(TAG) instanceof BoxBottomSheet shown)
    {
      if (page != Page.MAIN && shown.getView() != null)
        shown.showPage(page);
      return;
    }
    if (manager.isStateSaved())
      return;
    final BoxBottomSheet sheet = new BoxBottomSheet();
    final Bundle args = new Bundle();
    args.putInt(ARG_PAGE, page.ordinal());
    sheet.setArguments(args);
    sheet.show(manager, TAG);
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
  }

  @Nullable
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View view = inflater.inflate(R.layout.nogps_box_sheet, container, false);
    mRoot = (ViewGroup) ((ViewGroup) view).getChildAt(0);
    mMain = view.findViewById(R.id.box_main);
    mTitleRow = view.findViewById(R.id.box_title_row);
    mTitleRow.setOnClickListener(v -> showPage(Page.CAR));
    mTitle = view.findViewById(R.id.box_title);
    mTitleSubtitle = view.findViewById(R.id.box_title_subtitle);
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
    mShop = view.findViewById(R.id.box_shop);
    mBuyText = view.findViewById(R.id.box_buy_text);
    mSearchBuyText = view.findViewById(R.id.box_search_buy_text);
    view.findViewById(R.id.box_buy).setOnClickListener(v -> Utils.openUrl(requireContext(), NoGpsLinks.SHOP_URL));

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

    mAddCarPage = view.findViewById(R.id.box_add_car_page);
    setUpHeader(view, R.id.box_add_car_header, R.string.nogps_car_add);

    mCarPage = view.findViewById(R.id.box_car_page);
    mCarPageTitle = setUpHeader(view, R.id.box_car_header, 0);
    // The title of the page is the drop-down of the cars.
    mCarPageTitle.setCompoundDrawablesRelativeWithIntrinsicBounds(
        null, null, AppCompatResources.getDrawable(requireContext(), R.drawable.ic_chevron_down_thin), null);
    mCarPageTitle.setOnClickListener(this::showCarMenu);
    mCarPageName = view.findViewById(R.id.box_car_page_name);
    mCarPageNameLabel = view.findViewById(R.id.box_car_page_name_label);
    mCarPageNameRow = view.findViewById(R.id.box_car_page_name_row);
    mCarPageNameRow.setOnClickListener(v -> {
      final NoGps.Car car = pageCar();
      if (car != null)
        renameCar(car);
    });
    view.findViewById(R.id.box_car_box_row).setOnClickListener(v -> showPage(Page.BOX));
    mCarBoxState = view.findViewById(R.id.box_car_box_state);
    view.findViewById(R.id.box_car_forget).setOnClickListener(v -> {
      final NoGps.Car car = pageCar();
      if (car != null)
        confirmForgetCar(car);
    });
    mPhonesUnknown = view.findViewById(R.id.box_phones_unknown);
    ((TextView) mPhonesUnknown.findViewById(R.id.car_name)).setText(R.string.nogps_car_phones_unknown);
    mPhonesUnknown.setEnabled(false);
    mPhonesUnknown.findViewById(R.id.car_name).setEnabled(false);
    mPhonesUnknown.findViewById(R.id.car_state).setVisibility(View.GONE);
    mPhonesRows = view.findViewById(R.id.box_phones_rows);
    mPhonesReadOnly = view.findViewById(R.id.box_phones_read_only);
    mPhonesRecoveryCode = view.findViewById(R.id.box_phones_recovery_code);
    mAddPhone = view.findViewById(R.id.box_add_phone);
    mAddPhoneColors = mAddPhone.getTextColors();
    mAddPhone.setOnClickListener(v -> addPhone());
    view.findViewById(R.id.box_sprint_to100_row).setOnClickListener(v -> showPage(Page.SPRINT_TO_100));
    view.findViewById(R.id.box_sprint_quarter_row).setOnClickListener(v -> showPage(Page.SPRINT_QUARTER_MILE));
    mSprintBest[0] = view.findViewById(R.id.box_sprint_to100_best);
    mSprintBest[1] = view.findViewById(R.id.box_sprint_quarter_best);

    mBoxPage = view.findViewById(R.id.box_box_page);
    setUpHeader(view, R.id.box_box_header, R.string.nogps_box_title);
    mReadiness = view.findViewById(R.id.box_readiness);
    mItemBox = setUpItem(view, R.id.box_item_box, R.id.box_box_item_header, Page.ITEM_BOX);
    mItemObd = setUpItem(view, R.id.box_item_obd, R.id.box_obd_item_header, Page.ITEM_OBD);
    mItemCar = setUpItem(view, R.id.box_item_car, R.id.box_car_item_header, Page.ITEM_CAR);
    mItemSpeed = setUpItem(view, R.id.box_item_speed, R.id.box_speed_item_header, Page.ITEM_SPEED);
    mItemImu = setUpItem(view, R.id.box_item_imu, R.id.box_imu_item_header, Page.ITEM_IMU);
    mBoxItemPage = view.findViewById(R.id.box_box_item_page);
    mObdItemPage = view.findViewById(R.id.box_obd_item_page);
    mCarItemPage = view.findViewById(R.id.box_car_item_page);
    mSpeedItemPage = view.findViewById(R.id.box_speed_item_page);
    mImuItemPage = view.findViewById(R.id.box_imu_item_page);
    mReadOnly = view.findViewById(R.id.box_read_only);
    mFirmwareRow = view.findViewById(R.id.box_firmware_row);
    ((TextView) mFirmwareRow.findViewById(R.id.row_label)).setText(R.string.nogps_box_value_firmware);
    mFirmware = mFirmwareRow.findViewById(R.id.row_value);
    mFirmwareAction = view.findViewById(R.id.box_firmware_action);
    mFirmwareAction.setOnClickListener(v -> onFirmwareAction());
    mSpeed = view.findViewById(R.id.box_speed);
    mCarNameRow = view.findViewById(R.id.box_car_name_row);
    mCarName = view.findViewById(R.id.box_car_name);
    mVoltageMismatch = view.findViewById(R.id.box_voltage_mismatch);
    mSpeedLagValue = view.findViewById(R.id.box_speed_lag_value);
    mSpeedLagSource = view.findViewById(R.id.box_speed_lag_source);
    mSpeedTableRows = view.findViewById(R.id.box_speed_table_rows);
    view.findViewById(R.id.box_clear_speed).setOnClickListener(v -> confirmClearSpeed());
    view.findViewById(R.id.box_calibration_row).setOnClickListener(v -> showPage(Page.CALIBRATION));
    mCalibrationValue = view.findViewById(R.id.box_calibration_value);
    mSprintPage = view.findViewById(R.id.box_sprint_page);
    mSprintTitle = setUpHeader(view, R.id.box_sprint_header, 0);
    mSprintRows = view.findViewById(R.id.box_sprint_rows);
    mSprintNone = view.findViewById(R.id.box_sprint_none);
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

  @NonNull
  private TextView setUpHeader(@NonNull View root, int id, @StringRes int title)
  {
    final View header = root.findViewById(id);
    final TextView titleView = header.findViewById(R.id.page_title);
    if (title != 0)
      titleView.setText(title);
    header.findViewById(R.id.page_back).setOnClickListener(v -> showPage(mPage.parent()));
    return titleView;
  }

  /**
   * The titles of the items follow the car and the box.
   */
  @NonNull
  private Item setUpItem(@NonNull View root, int rowId, int headerId, @NonNull Page page)
  {
    final Item item = new Item(root.findViewById(rowId), setUpHeader(root, headerId, 0));
    item.row.setOnClickListener(v -> showPage(page));
    return item;
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
    mScroll = (NestedScrollView) view;
    mScroll.setMinimumHeight(minSheetHeight(windowHeight()));
  }

  @Override
  public void onConfigurationChanged(@NonNull Configuration newConfig)
  {
    super.onConfigurationChanged(newConfig);
    if (mScroll != null)
      mScroll.setMinimumHeight(minSheetHeight(windowHeight()));
  }

  private int windowHeight()
  {
    // Not the decor view: its height is 0 before the first layout, e.g. when restored after a rotation.
    return requireActivity().getResources().getDisplayMetrics().heightPixels;
  }

  @Override
  public int getTheme()
  {
    return R.style.MwmTheme_BoxBottomSheetDialog;
  }

  // A short page is not a sliver at the bottom: the sheet is at least half the window.
  static int minSheetHeight(int windowHeight)
  {
    return windowHeight / 2;
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
    // Neither is shown without the sheet that updates it.
    if (mAddPhoneDialog != null)
      mAddPhoneDialog.dismiss();
    if (mCarMenu != null)
      mCarMenu.dismiss();
    animateRings(false);
    mTile.pulse(false);
    mGpsTile.pulse(false);
    mGpsView.stop();
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
    // The drop-down belongs to the car page, and the page may change under it, e.g. the box removes this phone.
    if (mCarMenu != null)
      mCarMenu.dismiss();
    if (from == Page.ADD_CAR)
      stopAddingCar();
    mPage = page;
    if (page == Page.ADD_CAR)
      startAddingCar();
    else if (page == Page.CAR)
      mPhonesListed = false;
    final boolean deeper = depthOf(page) > depthOf(from);
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

  private static int depthOf(@NonNull Page page)
  {
    return page == Page.MAIN ? 0 : 1 + depthOf(page.parent());
  }

  /**
   * The car of the car page: always the one driven now, null without a car.
   */
  @Nullable
  private NoGps.Car pageCar()
  {
    return currentCar(NoGps.getStatus());
  }

  @NonNull
  private View[] pageViews(@NonNull Page page)
  {
    return switch (page)
    {
      case MAIN -> new View[] {mMain, mSearch, mShop};
      case GPS -> new View[] {mGpsPage};
      case CAR -> new View[] {mCarPage};
      case ADD_CAR -> new View[] {mAddCarPage, mSearch, mShop};
      case BOX -> new View[] {mBoxPage};
      case ITEM_BOX -> new View[] {mBoxItemPage};
      case ITEM_OBD -> new View[] {mObdItemPage};
      case ITEM_CAR -> new View[] {mCarItemPage};
      case ITEM_SPEED -> new View[] {mSpeedItemPage};
      case ITEM_IMU -> new View[] {mImuItemPage};
      case CALIBRATION -> new View[] {mCalibrationPage};
      case SPRINT_TO_100, SPRINT_QUARTER_MILE -> new View[] {mSprintPage};
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
      showPage(Page.CAR);
      return;
    }
    // The car is forgotten, e.g. after its box has removed this phone.
    if (mPage == Page.CAR && pageCar() == null)
    {
      showPage(Page.MAIN);
      return;
    }
    // The pages of a box set up, e.g. after the box has removed this phone.
    if (mPage != Page.MAIN && mPage != Page.GPS && (mSearching || !status.inertialEnabled))
    {
      showPage(Page.MAIN);
      return;
    }
    // The speed is learned while the box leads the car.
    if (mPage == Page.ITEM_SPEED && !status.inertialStarted)
    {
      showPage(Page.BOX);
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
    mShop.setVisibility(mPage == Page.MAIN || mPage == Page.ADD_CAR ? View.VISIBLE : View.GONE);
    mSearch.setVisibility((mPage == Page.MAIN && mSearching) || mPage == Page.ADD_CAR ? View.VISIBLE : View.GONE);
    // The user adding a car knows what the box is for.
    mSearchBuyText.setVisibility(mPage == Page.MAIN ? View.VISIBLE : View.GONE);
    if (mPage == Page.ADD_CAR)
      mBuyText.setVisibility(View.GONE);
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
    case CAR -> updateCarPage(status);
    case ADD_CAR -> updateSearch(status);
    case BOX, ITEM_BOX, ITEM_OBD, ITEM_CAR, ITEM_SPEED, ITEM_IMU -> updateBoxPage(status);
    case CALIBRATION -> updateCalibration(status);
    case SPRINT_TO_100, SPRINT_QUARTER_MILE -> updateSprintPage();
    }
  }

  private void updateMain(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final boolean boxSetUp = status.inertialEnabled && !mSearching;
    // The car driven now opens its page. Without a box set up, or with an adapter that is not a box, there is no car.
    final NoGps.Car current = boxSetUp ? currentCar(status) : null;
    mTitle.setText(current != null ? BoxTexts.carName(context, current) : getString(R.string.nogps_box_title));
    mTitleRow.setClickable(current != null);
    mTitleSubtitle.setVisibility(current != null ? View.VISIBLE : View.GONE);
    mTitle.setCompoundDrawablesRelativeWithIntrinsicBounds(0, 0, current != null ? R.drawable.ic_nogps_chevron : 0, 0);
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
    // Without a box: what it is for, under the search while it goes.
    mBuyText.setVisibility(!status.inertialEnabled && !mSearching ? View.VISIBLE : View.GONE);
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
  static boolean isConnected(@NonNull NoGps.Status status)
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
      case CAR_LIMIT -> R.string.nogps_box_bt_car_limit;
      case PAIRING -> R.string.nogps_box_bt_pairing;
      case PAIRING_FAILED -> R.string.nogps_box_bt_pairing_failed;
      case BOND_LOST -> R.string.nogps_box_bt_bond_lost;
      default -> 0;
    };
  }

  /**
   * The hint of a box not paired with this phone gets the code of its recovery window, when the box has told it: the
   * system dialog of the pairing wants that code then, not 123456.
   */
  static boolean hintHasRecoveryCode(@NonNull NoGps.Status status)
  {
    if (status.boxRecoveryCode.isEmpty())
      return false;
    return switch (status.getBleState())
    {
      case PAIRING_BY_PHONE, PAIRING_FULL, PAIRING -> true;
      default -> false;
    };
  }

  @NonNull
  private String linkHint(@NonNull NoGps.Status status, @StringRes int hint)
  {
    final String text = getString(hint);
    if (!hintHasRecoveryCode(status))
      return text;
    return text + ". " + getString(R.string.nogps_box_bt_recovery_code, status.boxRecoveryCode);
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
  private String carStateText(@Nullable CarMenu.State state, long lastSeenUnixMs)
  {
    if (state == null)
      return "";
    return switch (state)
    {
      case CONNECTED -> getString(R.string.nogps_car_connected);
      case CURRENT -> getString(R.string.nogps_car_current);
      case NEARBY -> getString(R.string.nogps_car_nearby);
      case LAST_SEEN ->
        getString(R.string.nogps_car_last_seen,
                  DateUtils.getRelativeTimeSpanString(lastSeenUnixMs, System.currentTimeMillis(),
                                                      DateUtils.MINUTE_IN_MILLIS));
    };
  }

  // The box of another car is awake near the phone.
  private boolean isNearby(@NonNull String carId)
  {
    return MwmApplication.from(requireContext()).getLocationHelper().isBoxNearby(carId);
  }

  /**
   * The cars over the title of the car page: picking one drives it and the page shows it, the last entry adds a car.
   */
  private void showCarMenu(@NonNull View anchor)
  {
    final NoGps.Status status = NoGps.getStatus();
    final List<CarMenu.Entry> entries = CarMenu.entries(NoGps.nativeGetCars(), status.carId, isConnected(status),
                                                        this::isNearby, NoGps.nativeGetMaxCars());
    final ListPopupWindow menu = new ListPopupWindow(requireContext());
    mCarMenu = menu;
    menu.setAnchorView(anchor);
    // As wide as the page, over the title: a name with its state under it has no room in a drop-down fitted to the
    // text of the title. Taken from the header row, which spans the page: the sheet is narrower than a wide screen,
    // and the width of the anchor itself is only the width of its text.
    final View header = (View) anchor.getParent();
    menu.setWidth(Math.max(header.getWidth(), dp(280)));
    menu.setHorizontalOffset(-anchor.getLeft());
    menu.setAdapter(new CarMenuAdapter(entries));
    menu.setOnDismissListener(() -> mCarMenu = null);
    menu.setOnItemClickListener((parent, view, position, id) -> {
      menu.dismiss();
      final NoGps.Car car = entries.get(position).car();
      if (car == null)
        showPage(Page.ADD_CAR);
      else
      {
        NoGps.nativeSelectCar(car.id);
        update();
      }
    });
    menu.show();
  }

  /**
   * A row of the drop-down of the cars: the name of the car, its state under it, a check on the car driven now. The
   * last row adds a car.
   */
  private final class CarMenuAdapter extends BaseAdapter
  {
    @NonNull
    private final List<CarMenu.Entry> mEntries;

    CarMenuAdapter(@NonNull List<CarMenu.Entry> entries)
    {
      mEntries = entries;
    }

    @Override
    public int getCount()
    {
      return mEntries.size();
    }

    @Override
    public Object getItem(int position)
    {
      return mEntries.get(position);
    }

    @Override
    public long getItemId(int position)
    {
      return position;
    }

    @NonNull
    @Override
    public View getView(int position, @Nullable View convertView, @NonNull ViewGroup parent)
    {
      final View row = convertView != null
                         ? convertView
                         : LayoutInflater.from(requireContext()).inflate(R.layout.nogps_car_row, parent, false);
      row.setPadding(dp(16), row.getPaddingTop(), dp(16), row.getPaddingBottom());
      final CarMenu.Entry entry = mEntries.get(position);
      final NoGps.Car car = entry.car();
      ((TextView) row.findViewById(R.id.car_name))
          .setText(car != null ? BoxTexts.carName(requireContext(), car) : getString(R.string.nogps_car_add));
      final String stateText = car != null ? carStateText(entry.state(), car.lastSeenUnixMs) : "";
      final TextView state = row.findViewById(R.id.car_state);
      state.setText(stateText);
      state.setVisibility(stateText.isEmpty() ? View.GONE : View.VISIBLE);
      row.findViewById(R.id.car_check).setVisibility(entry.current() ? View.VISIBLE : View.GONE);
      return row;
    }
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
    final AlertDialog dialog = new MaterialAlertDialogBuilder(context)
                                   .setTitle(R.string.nogps_car_name)
                                   .setView(frame)
                                   .setPositiveButton(R.string.save,
                                                      (d, which) -> {
                                                        NoGps.nativeRenameCar(car.id, name.getText().toString());
                                                        update();
                                                      })
                                   .setNegativeButton(R.string.cancel, null)
                                   .show();
    // An empty name is refused: the core keeps the previous one.
    final Button save = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
    save.setEnabled(!name.getText().toString().trim().isEmpty());
    name.addTextChangedListener(new TextWatcher() {
      @Override
      public void beforeTextChanged(CharSequence s, int start, int count, int after)
      {}

      @Override
      public void onTextChanged(CharSequence s, int start, int before, int count)
      {}

      @Override
      public void afterTextChanged(Editable s)
      {
        save.setEnabled(!s.toString().trim().isEmpty());
      }
    });
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
                               showPage(Page.MAIN);
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

  /**
   * The car driven now and what the user does with it. Its box tells its phones while it is connected.
   */
  private void updateCarPage(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final NoGps.Car car = pageCar();
    if (car == null)
      return;
    final String name = BoxTexts.carName(context, car);
    mCarPageTitle.setText(name);
    mCarPageName.setText(name);
    // The box takes the name from the phone connected first only, the note under the phones tells it.
    final boolean canRename = !status.boxReadOnly;
    mCarPageNameRow.setEnabled(canRename);
    mCarPageNameLabel.setEnabled(canRename);
    mCarBoxState.setText(BoxTexts.capitalize(BoxTexts.boxStateText(context, status)));
    final boolean phones = status.boxHasPhones;
    mPhonesRows.setVisibility(phones ? View.VISIBLE : View.GONE);
    mAddPhone.setVisibility(phones ? View.VISIBLE : View.GONE);
    mPhonesUnknown.setVisibility(phones ? View.GONE : View.VISIBLE);
    if (phones && !mPhonesListed)
      NoGps.nativeListBoxPhones();
    mPhonesListed = phones;
    if (phones)
      updatePhones(status);
    else
      mPhonesReadOnly.setVisibility(View.GONE);
    // The code the box told this phone before: shown while the box is out of reach too, to be written down.
    final boolean recovery = !status.boxRecoveryCode.isEmpty();
    mPhonesRecoveryCode.setVisibility(recovery ? View.VISIBLE : View.GONE);
    if (recovery)
      mPhonesRecoveryCode.setText(getString(R.string.nogps_phone_recovery_code, status.boxRecoveryCode));
    final NoGps.Sprint[] sprints = NoGps.nativeGetSprints();
    mSprintBest[0].setText(Sprints.bestText(this::getString, sprints, NoGps.SprintKind.TO_100));
    mSprintBest[1].setText(Sprints.bestText(this::getString, sprints, NoGps.SprintKind.QUARTER_MILE));
  }

  private void updatePhones(@NonNull NoGps.Status status)
  {
    mPhonesReadOnly.setVisibility(status.boxReadOnly ? View.VISIBLE : View.GONE);
    // The row looks like a link only while it works: the box of another phone takes no new phone.
    mAddPhone.setEnabled(!status.boxReadOnly);
    mAddPhone.setTextColor(status.boxReadOnly ? mStateColors : mAddPhoneColors);
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
      return phone.changesBox
        ? getString(R.string.nogps_phone_this) + " · " + getString(R.string.nogps_phone_changes_box)
        : getString(R.string.nogps_phone_this);
    // Connected now.
    if (phone.changesBox)
      return getString(R.string.nogps_phone_changes_box);
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
    final NoGps.Car car = pageCar();
    if (car == null)
      return;
    NoGps.nativeStartAddPhone();
    final Context context = requireContext();
    final View content = getLayoutInflater().inflate(R.layout.dialog_nogps_add_phone, null);
    mAddPhoneCode = content.findViewById(R.id.add_phone_code);
    mAddPhoneMessage = content.findViewById(R.id.add_phone_message);
    mAddPhoneDialog = new MaterialAlertDialogBuilder(context)
                          .setTitle(getString(R.string.nogps_phone_add_to_car, BoxTexts.carName(context, car)))
                          .setView(content)
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
      case OPEN -> getString(R.string.nogps_phone_add_code, DateUtils.formatElapsedTime(status.addPhoneSecondsLeft));
      case ADDED -> getString(R.string.nogps_phone_added);
      case EXPIRED -> getString(R.string.nogps_phone_add_expired);
      case FULL -> getString(R.string.nogps_phone_add_full);
      case FAILED -> getString(R.string.nogps_phone_add_failed);
    };
    final boolean open = status.getAddPhone() == NoGps.AddPhone.OPEN;
    mAddPhoneCode.setText(open ? status.addPhoneCode : "");
    mAddPhoneCode.setVisibility(open ? View.VISIBLE : View.GONE);
    mAddPhoneMessage.setText(text);
  }

  private void updateBoxPage(@NonNull NoGps.Status status)
  {
    final Context context = requireContext();
    final boolean connected = isConnected(status);
    updateReadiness(status);
    updateValues(status);

    final String firmware = BoxTexts.firmwareText(context, status);
    final String boxState = BoxTexts.boxStateText(context, status);
    // How the firmware is sent stands for the state of the box while it goes.
    final String state = BoxTexts.isUpdating(status.getFirmwareUpdate()) ? firmware : boxState;
    mItemBox.show(getString(R.string.nogps_box_section, boxModel(status)),
                  status.boxFirmware.isEmpty()
                      ? state
                      : getString(R.string.nogps_box_version, status.boxFirmware) + ", " + BoxTexts.capitalize(state));
    // Another phone calibrates and updates the box.
    mReadOnly.setVisibility(connected && status.boxReadOnly ? View.VISIBLE : View.GONE);
    // The phone that follows the other one shows its place.
    final String peer = BoxTexts.peerPositionText(requireContext(), status);
    mReadOnly.setText(peer == null ? getString(R.string.nogps_box_read_only)
                                   : getString(R.string.nogps_box_read_only) + "\n" + peer);
    final NoGps.FirmwareUpdate update = status.getFirmwareUpdate();
    final boolean updating = BoxTexts.isUpdating(update);
    mFirmwareRow.setVisibility(updating || !status.boxFirmware.isEmpty() ? View.VISIBLE : View.GONE);
    mFirmware.setText(firmware);
    // The dialog of the update has its own Cancel.
    final boolean install = BoxTexts.canInstallFirmware(status);
    mFirmwareAction.setVisibility(install ? View.VISIBLE : View.GONE);
    if (install)
      mFirmwareAction.setText(getString(R.string.nogps_firmware_install, status.bundledFirmware));

    final int obdHint = obdHintText(status);
    mItemObd.show(getString(R.string.nogps_box_value_group_obd), obdHint != 0 ? getString(obdHint) : boxState);

    final NoGps.Car car = currentCar(status);
    mItemCar.show(car != null ? getString(R.string.nogps_box_car, BoxTexts.carName(context, car))
                              : getString(R.string.nogps_box_value_group_car),
                  getString(!isBoxHeard(status) || status.engineRunning < 0 ? R.string.nogps_unknown
                            : status.engineRunning > 0                      ? R.string.nogps_engine_running
                                                                            : R.string.nogps_engine_stopped));
    mSpeed.setText(getString(R.string.nogps_sensors_speed, status.inertialStarted && status.speedKmh >= 0
                                                               ? getString(R.string.nogps_speed_kmh, status.speedKmh)
                                                               : getString(R.string.nogps_unknown)));

    mCarNameRow.setVisibility(car != null ? View.VISIBLE : View.GONE);
    if (car != null)
      mCarName.setText(BoxTexts.carName(context, car));

    mItemSpeed.show(getString(R.string.nogps_speed_calibration), BoxTexts.speedTableText(context, status));
    mSpeedLagValue.setText(
        getString(R.string.nogps_speed_lag_value, String.format(Locale.US, "%.1f", status.speedLagSec)));
    mSpeedLagSource.setText(status.speedLagMeasured ? R.string.nogps_speed_lag_measured
                                                    : R.string.nogps_speed_lag_usual);
    updateSpeedTable(status);

    final List<String> imu = new ArrayList<>();
    for (int i = 0; i < mValueIds.length; ++i)
    {
      final NoGps.BoxValue id = mValueIds[i];
      if ((id == NoGps.BoxValue.IMU_STATE || id == NoGps.BoxValue.IMU_TEMPERATURE) && status.boxValues.length > 0)
        imu.add(BoxTexts.boxValueText(context, status, id, mValues[i]));
    }
    mItemImu.show(getString(R.string.nogps_box_imu),
                  imu.isEmpty() ? getString(R.string.nogps_unknown) : String.join(" · ", imu));
    mCalibrationValue.setText(BoxTexts.capitalize(BoxTexts.boxCalibrationText(context, status, calibration(status))));

    // The speed is learned while the box leads the car.
    mItemSpeed.row.setVisibility(status.inertialStarted ? View.VISIBLE : View.GONE);
  }

  /**
   * The results of the kind of the page for the car, newest first, the best marked.
   */
  private void updateSprintPage()
  {
    final NoGps.SprintKind kind = mPage == Page.SPRINT_TO_100 ? NoGps.SprintKind.TO_100 : NoGps.SprintKind.QUARTER_MILE;
    mSprintTitle.setText(Sprints.titleText(kind));
    final NoGps.Sprint[] all = NoGps.nativeGetSprints();
    final NoGps.Sprint best = Sprints.best(all, kind);
    final NoGps.Sprint[] sprints = Sprints.ofKind(all, kind);
    mSprintNone.setVisibility(sprints.length == 0 ? View.VISIBLE : View.GONE);
    final LayoutInflater inflater = LayoutInflater.from(requireContext());
    final DateFormat dateFormat = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT);
    while (mSprintRows.getChildCount() < sprints.length)
      mSprintRows.addView(inflater.inflate(R.layout.nogps_sheet_row, mSprintRows, false));
    for (int i = 0; i < mSprintRows.getChildCount(); ++i)
    {
      final View row = mSprintRows.getChildAt(i);
      row.setVisibility(i < sprints.length ? View.VISIBLE : View.GONE);
      if (i >= sprints.length)
        continue;
      final boolean isBest = sprints[i] == best;
      final String date = dateFormat.format(new Date(sprints[i].unixTimeMs));
      ((TextView) row.findViewById(R.id.row_label))
          .setText(isBest ? date + " · " + getString(R.string.nogps_sprint_best) : date);
      final TextView value = row.findViewById(R.id.row_value);
      value.setText(Sprints.resultText(this::getString, sprints[i]));
      value.setTypeface(null, isBest ? Typeface.BOLD : Typeface.NORMAL);
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
      // Nothing from the box yet: the pages of the values show every row with a dash instead of collapsing to a
      // header and nothing under it.
      if (mValueIds.length == 0)
        makeValueRows(NoGps.BoxValue.values());
      Arrays.fill(mValues, "");
    }
    boolean mismatch = false;
    for (int i = 0; i < mValueIds.length; ++i)
    {
      if (mValueTexts[i] != null)
        mValueTexts[i].setText(live ? BoxTexts.boxValueText(requireContext(), status, mValueIds[i], mValues[i])
                                    : getString(R.string.nogps_unknown));
      if (mValueIds[i] == NoGps.BoxValue.VOLTAGE_MISMATCH && mValues[i].equals("1"))
        mismatch = true;
    }
    mVoltageMismatch.setVisibility(mismatch ? View.VISIBLE : View.GONE);
  }

  // "NonGPS-OBD, R1" once the box has told its hardware revision.
  @NonNull
  private static String boxModel(@NonNull NoGps.Status status)
  {
    for (int i = 0; i < status.boxValues.length; i++)
      if (status.getBoxValueId(i) == NoGps.BoxValue.REVISION && !status.boxValues[i].isEmpty())
        return BOX_NAME + ", " + status.boxValues[i];
    return BOX_NAME;
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
      // The firmware row of the Box page tells it.
      if (ids[i] == NoGps.BoxValue.FIRMWARE)
        continue;
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
   * Starts the update, if it is still allowed: the box may have gone on since the row was drawn.
   */
  private void onFirmwareAction()
  {
    final NoGps.Status status = NoGps.getStatus();
    if (BoxTexts.canInstallFirmware(status))
    {
      NoGps.nativeStartFirmwareUpdate();
      FirmwareUpdateDialog.show(requireActivity().getSupportFragmentManager());
    }
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
    mCalibrationState.setText(BoxTexts.capitalize(BoxTexts.boxCalibrationText(requireContext(), status, calibration)));
    // Green once calibrated, red after a failure.
    final int stateColor = switch (calibration)
    {
      case DONE -> status.boxCalibrationAdvised ? 0 : R.color.nogps_status_gps;
      case FAILED_MOVING, MOUNT_MOVED, LINK_LOST -> R.color.nogps_status_none;
      default -> 0;
    };
    if (stateColor != 0)
      mCalibrationState.setTextColor(ContextCompat.getColor(requireContext(), stateColor));
    else
      mCalibrationState.setTextColor(mStateColors);
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
                          || ble == NoGps.BleState.PAIRING_BY_PHONE || ble == NoGps.BleState.PAIRING_FULL
                          || ble == NoGps.BleState.CAR_LIMIT;
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
      showState(mStepHint, new StatusBar.Look(0, 0), linkHint(status, hint));
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
