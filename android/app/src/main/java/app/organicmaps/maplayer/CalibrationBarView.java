package app.organicmaps.maplayer;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.res.ColorStateList;
import android.content.res.Resources;
import android.graphics.Outline;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.animation.PathInterpolator;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.StringRes;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import java.util.Locale;

/**
 * The bar that slides out of the speed when the core waits for the car to calibrate the sensor box. It shows how much
 * the box shakes in the last 3 s on a split scale with the last 2 s shaded (the box wants the car still for so long),
 * and a chip with the try, the time held or the peak. It is orange while the core waits and calibrates and green for a
 * while after the calibration. A tap cancels it and opens the calibration page.
 */
class CalibrationBarView
{
  private static final long OPEN_MS = 520;
  private static final long CLOSE_MS = 280;
  private static final long DONE_MS = 2800;
  private static final long COLOR_MS = 250;
  // The status comes once a second, too seldom for a trace.
  private static final long TRACE_MS = 50;
  // The bar keeps clear of the panel of the end edge when the user has moved it down to the bar.
  private static final float END_GAP_DP = 8;
  // The chip says "peak" when nothing is held and the peak of the trace is this much of the limit.
  private static final float PEAK_CHIP_PERCENT = 300;
  // Engine::kCalibrateWhenStillMaxFailures: the core gives up after so many tries.
  private static final int MAX_TRIES = 5;

  @NonNull
  private final View mFrame;
  @NonNull
  private final View mBar;
  @NonNull
  private final View mProgress;
  @NonNull
  private final TextView mTitle;
  @NonNull
  private final TextView mChip;
  @NonNull
  private final View mReady;
  @NonNull
  private final ShakeTraceView mTrace;
  @NonNull
  private final View mSpeed;
  @Nullable
  private final View mEndPanel;
  private final int mAccent;
  private final int mDone;
  private final float mDensity;
  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mEndDone = this::endDone;
  private final Runnable mRefreshTrace = new Runnable() {
    @Override
    public void run()
    {
      mShake = NoGps.nativeGetBoxShake();
      mTrace.setValues(mShake);
      if (!mDoneShown)
        updateChip();
      mHandler.postDelayed(this, TRACE_MS);
    }
  };
  // How much of the bar is out of the speed, 0..1.
  @NonNull
  private int[] mShake = new int[0];
  @Nullable
  private NoGps.Status mStatus;
  private float mReveal;
  private boolean mOpen;
  private boolean mDoneShown;
  // The core has been seen to calibrate the box since it was armed.
  private boolean mSawCalibrating;
  private boolean mWasArmed;
  @Nullable
  private ValueAnimator mRevealAnimator;
  @Nullable
  private ValueAnimator mColorAnimator;

  /**
   * @param frame    the frame of map_speed_hint.xml.
   * @param speed    the speed the bar slides out of.
   * @param endPanel the panel of the buttons at the end edge, the bar stays clear of it.
   * @param onTap    opens the calibration page.
   */
  CalibrationBarView(@NonNull View frame, @NonNull View speed, @Nullable View endPanel, @NonNull Runnable onTap)
  {
    mFrame = frame;
    mBar = frame.findViewById(R.id.calibration_bar);
    mProgress = frame.findViewById(R.id.calibration_bar_progress);
    mTitle = frame.findViewById(R.id.calibration_bar_title);
    mChip = frame.findViewById(R.id.calibration_bar_chip);
    mReady = frame.findViewById(R.id.calibration_bar_ready);
    mTrace = frame.findViewById(R.id.calibration_bar_trace);
    mSpeed = speed;
    mEndPanel = endPanel;
    mAccent = ContextCompat.getColor(frame.getContext(), R.color.calibration_bar_accent);
    mDone = ContextCompat.getColor(frame.getContext(), R.color.speed_hint_done);
    mDensity = frame.getContext().getResources().getDisplayMetrics().density;
    // Only the part out of the speed is drawn, its shadow too.
    mBar.setOutlineProvider(new ViewOutlineProvider() {
      @Override
      public void getOutline(View view, Outline outline)
      {
        final int height = view.getHeight();
        final int width = Math.max(1, Math.round(view.getWidth() * mReveal));
        final int left = view.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL ? view.getWidth() - width : 0;
        outline.setRoundRect(left, 0, left + width, height, Math.min(width, height) / 2f);
      }
    });
    mBar.setClipToOutline(true);
    mBar.setOnClickListener(v -> {
      NoGps.nativeDeclineAutoCalibration();
      cancel();
      onTap.run();
    });
  }

  /**
   * The bar is on the screen: the bar of the speed range waits.
   */
  boolean isShown()
  {
    return mOpen || mDoneShown;
  }

  /**
   * The first try of an arming can still see the failure of an earlier calibration: not a move of this one.
   */
  private static boolean moved(@NonNull NoGps.Status status)
  {
    return status.getCalibration() == NoGps.CalibrationState.FAILED_MOVING && status.calibrationTries >= 2;
  }

  @StringRes
  private static int title(@NonNull NoGps.Status status)
  {
    if (moved(status))
      return R.string.nogps_calibrate_bar_moved;
    return status.getCalibration() == NoGps.CalibrationState.CALIBRATING ? R.string.nogps_calibrate_bar_measuring
                                                                         : R.string.nogps_calibrate_bar_hold;
  }

  /**
   * The chip at the right of the first row, null when there is nothing to say.
   *
   * @param values the trace of the shake in percent of the limit, the oldest first.
   */
  @Nullable
  static String chipText(@NonNull Resources resources, @NonNull NoGps.Status status, @NonNull int[] values)
  {
    if (status.getCalibration() == NoGps.CalibrationState.CALIBRATING)
      return status.calibrationProgress + " %";
    if (moved(status))
      return resources.getString(R.string.nogps_calibrate_bar_try, status.calibrationTries, MAX_TRIES);
    final int held = ShakeTraceView.heldMs(values);
    if (held >= ShakeTraceView.HOLD_MS && !status.boxStill)
      return resources.getString(R.string.nogps_calibrate_bar_waiting_box);
    if (held > 0)
      return resources.getString(R.string.nogps_calibrate_bar_held,
                                 String.format(Locale.getDefault(), "%.1f", held / 1000f));
    int peak = 0;
    for (int i = Math.max(0, values.length - ShakeTraceView.LINES); i < values.length; ++i)
      peak = Math.max(peak, values[i]);
    if (peak >= PEAK_CHIP_PERCENT)
      return resources.getString(R.string.nogps_calibrate_bar_peak, Math.round(peak / ShakeTraceView.LIMIT_PERCENT));
    return null;
  }

  private void updateChip()
  {
    final String text = mStatus == null ? null : chipText(mFrame.getResources(), mStatus, mShake);
    mChip.setText(text);
    mChip.setVisibility(text == null ? View.GONE : View.VISIBLE);
  }

  /**
   * Once a second and right after the tap, after the speed is updated.
   */
  void update(@NonNull NoGps.Status status)
  {
    final boolean armed = status.calibrationArmed;
    final boolean wasArmed = mWasArmed;
    mWasArmed = armed;
    if (mDoneShown)
      return;
    if (armed && mSpeed.getVisibility() == View.VISIBLE)
    {
      final boolean calibrating = status.getCalibration() == NoGps.CalibrationState.CALIBRATING;
      mSawCalibrating |= calibrating;
      mStatus = status;
      mTrace.setShowsHold(!calibrating);
      mTrace.setVisibility(View.VISIBLE);
      mReady.setVisibility(View.GONE);
      updateChip();
      mTitle.setText(title(status));
      mBar.setContentDescription(mTitle.getText());
      mProgress.setPivotX(mBar.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL ? mBar.getWidth() : 0);
      mProgress.setScaleX(calibrating ? status.calibrationProgress / 100f : 0);
      keepClearOfEndPanel();
      setOpen(true);
      return;
    }
    // The core is not armed after the box answers: calibrated, if it was seen to calibrate.
    if (wasArmed && !armed && mSawCalibrating && mOpen && status.getCalibration() == NoGps.CalibrationState.DONE)
      celebrate();
    else
      setOpen(false);
    mSawCalibrating = false;
  }

  private void celebrate()
  {
    mDoneShown = true;
    mTitle.setText(R.string.nogps_calibrate_bar_done);
    mChip.setVisibility(View.GONE);
    mTrace.setVisibility(View.INVISIBLE);
    mReady.setVisibility(View.VISIBLE);
    mBar.setContentDescription(mTitle.getText());
    mProgress.setScaleX(0);
    animateColor(mDone);
    mHandler.removeCallbacks(mEndDone);
    mHandler.postDelayed(mEndDone, DONE_MS);
  }

  private void endDone()
  {
    mDoneShown = false;
    setOpen(false);
  }

  /**
   * Hides the bar at once, e.g. after the tap on it.
   */
  private void cancel()
  {
    mSawCalibrating = false;
    mDoneShown = false;
    mHandler.removeCallbacks(mEndDone);
    setOpen(false);
  }

  /**
   * The map is not seen: everything stops, the bar is hidden.
   */
  void stop()
  {
    mHandler.removeCallbacks(mEndDone);
    mHandler.removeCallbacks(mRefreshTrace);
    mDoneShown = false;
    mSawCalibrating = false;
    if (mRevealAnimator != null)
      mRevealAnimator.cancel();
    if (mColorAnimator != null)
      mColorAnimator.cancel();
    mOpen = false;
    setReveal(0);
    mBar.setBackgroundTintList(ColorStateList.valueOf(mAccent));
  }

  private void setOpen(boolean open)
  {
    if (open == mOpen)
      return;
    mOpen = open;
    if (mRevealAnimator != null)
      mRevealAnimator.cancel();
    mHandler.removeCallbacks(mRefreshTrace);
    if (open)
    {
      mBar.setBackgroundTintList(ColorStateList.valueOf(mAccent));
      mBar.setVisibility(View.VISIBLE);
      mHandler.post(mRefreshTrace);
    }
    mRevealAnimator = ValueAnimator.ofFloat(mReveal, open ? 1 : 0);
    mRevealAnimator.setDuration(open ? OPEN_MS : CLOSE_MS);
    mRevealAnimator.setInterpolator(open ? new PathInterpolator(0.22f, 1, 0.36f, 1)
                                         : new PathInterpolator(0.4f, 0, 0.7f, 1));
    mRevealAnimator.addUpdateListener(a -> setReveal((float) a.getAnimatedValue()));
    mRevealAnimator.addListener(new AnimatorListenerAdapter() {
      private boolean mCanceled;

      @Override
      public void onAnimationCancel(Animator animation)
      {
        mCanceled = true;
      }

      @Override
      public void onAnimationEnd(Animator animation)
      {
        // Back in the speed: the next bar is orange again.
        if (!mCanceled && !mOpen)
          mBar.setBackgroundTintList(ColorStateList.valueOf(mAccent));
      }
    });
    mRevealAnimator.start();
  }

  private void setReveal(float reveal)
  {
    mReveal = reveal;
    mBar.setVisibility(reveal > 0 ? View.VISIBLE : View.INVISIBLE);
    mBar.invalidateOutline();
  }

  private void animateColor(int color)
  {
    if (mColorAnimator != null)
      mColorAnimator.cancel();
    mColorAnimator = ValueAnimator.ofArgb(mAccent, color);
    mColorAnimator.setDuration(COLOR_MS);
    mColorAnimator.addUpdateListener(
        a -> mBar.setBackgroundTintList(ColorStateList.valueOf((int) a.getAnimatedValue())));
    mColorAnimator.start();
  }

  /**
   * The user can move the panel of the end edge down to the bar: the bar ends before it then.
   */
  private void keepClearOfEndPanel()
  {
    final int gap = Math.round(END_GAP_DP * mDensity);
    int end = gap;
    if (mEndPanel != null && mEndPanel.isShown() && mEndPanel.getAlpha() > 0 && mBar.getHeight() > 0)
    {
      final int[] panel = new int[2];
      mEndPanel.getLocationInWindow(panel);
      final int[] frame = new int[2];
      mFrame.getLocationInWindow(frame);
      final int barTop = frame[1] + mBar.getTop();
      if (panel[1] < barTop + mBar.getHeight() && panel[1] + mEndPanel.getHeight() > barTop)
      {
        final boolean rtl = mFrame.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
        end = (rtl ? panel[0] + mEndPanel.getWidth() - frame[0] : frame[0] + mFrame.getWidth() - panel[0]) + gap;
      }
    }
    final ViewGroup.MarginLayoutParams params = (ViewGroup.MarginLayoutParams) mBar.getLayoutParams();
    if (params.getMarginEnd() != end)
    {
      params.setMarginEnd(end);
      mBar.setLayoutParams(params);
    }
  }
}
