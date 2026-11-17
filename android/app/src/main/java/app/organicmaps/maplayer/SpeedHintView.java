package app.organicmaps.maplayer;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Outline;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.animation.DecelerateInterpolator;
import android.view.animation.OvershootInterpolator;
import android.view.animation.PathInterpolator;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import app.organicmaps.nogps.SpeedHints;
import app.organicmaps.sdk.location.NoGps;

/**
 * The bar that slides out of the speed to the end while the box gives a speed GPS has not measured: without GPS the
 * distance is counted by the car speed corrected for each range. It tells whether accurate GPS measures it now, and
 * celebrates every range measured. The texts are in SpeedHints.
 */
class SpeedHintView
{
  private static final long OPEN_MS = 520;
  private static final long CLOSE_MS = 280;
  private static final long BODY_IN_DELAY_MS = 200;
  private static final long BODY_IN_MS = 380;
  private static final long BODY_OUT_MS = 140;
  private static final float BODY_SHIFT_DP = 16;
  private static final long COLOR_MS = 250;
  private static final long FLASH_MS = 520;
  private static final float FLASH_ALPHA = 0.85f;
  private static final long WIN_IN_MS = 480;
  private static final long WIN_IN_SUBTITLE_DELAY_MS = 90;
  private static final float WIN_IN_SHIFT_DP = 10;
  private static final float WIN_IN_SCALE = 0.85f;
  private static final long STAR_MS = 800;
  private static final float STAR_TURN_DEG = -140;
  // The bar keeps clear of the panel of the end edge when the user has moved it down to the bar.
  private static final float END_GAP_DP = 8;

  @NonNull
  private final View mFrame;
  @NonNull
  private final View mBar;
  @NonNull
  private final View mBody;
  @NonNull
  private final View mFlash;
  @NonNull
  private final View mGpsOff;
  @NonNull
  private final View mStar;
  @NonNull
  private final TextView mTitle;
  @NonNull
  private final TextView mLeft;
  @NonNull
  private final TextView mSubtitle;
  @NonNull
  private final SpeedHintMeterView mMeter;
  @Nullable
  private final SpeedHintConfettiView mConfetti;
  @NonNull
  private final View mSpeed;
  @Nullable
  private final View mEndPanel;
  private final int mAccent;
  private final int mDone;
  private final float mDensity;
  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mEndCelebration = this::endCelebration;
  // How much of the bar is out of the speed, 0..1.
  private float mReveal;
  private boolean mOpen;
  private boolean mCelebrating;
  @Nullable
  private ValueAnimator mRevealAnimator;
  @Nullable
  private ValueAnimator mColorAnimator;

  /**
   * @param frame    the frame of map_speed_hint.xml.
   * @param confetti over the map, null if the layout has none.
   * @param speed    the speed the bar slides out of.
   * @param endPanel the panel of the buttons at the end edge, the bar stays clear of it.
   * @param onTap    opens the speed calibration.
   */
  SpeedHintView(@NonNull View frame, @Nullable SpeedHintConfettiView confetti, @NonNull View speed,
                @Nullable View endPanel, @NonNull Runnable onTap)
  {
    mFrame = frame;
    mBar = frame.findViewById(R.id.speed_hint);
    mBody = frame.findViewById(R.id.speed_hint_body);
    mFlash = frame.findViewById(R.id.speed_hint_flash);
    mGpsOff = frame.findViewById(R.id.speed_hint_gps_off);
    mStar = frame.findViewById(R.id.speed_hint_star);
    mTitle = frame.findViewById(R.id.speed_hint_title);
    mLeft = frame.findViewById(R.id.speed_hint_left);
    mSubtitle = frame.findViewById(R.id.speed_hint_subtitle);
    mMeter = frame.findViewById(R.id.speed_hint_meter);
    mConfetti = confetti;
    mSpeed = speed;
    mEndPanel = endPanel;
    final Context context = frame.getContext();
    mAccent = ContextCompat.getColor(context, R.color.speed_hint_accent);
    mDone = ContextCompat.getColor(context, R.color.speed_hint_done);
    mDensity = context.getResources().getDisplayMetrics().density;
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
    mBar.setOnClickListener(v -> onTap.run());
  }

  /**
   * Once a second, after the speed is updated.
   */
  void update(@NonNull NoGps.Status status)
  {
    if (mCelebrating)
      return;
    final boolean shown = SpeedHints.isShown(status) && mSpeed.getVisibility() == View.VISIBLE;
    if (shown)
    {
      final Context context = mBar.getContext();
      final int range = status.speedHintRange;
      mTitle.setText(context.getString(SpeedHints.titleText(status), NoGps.speedTableFromKmh(range),
                                       NoGps.speedTableToKmh(range)));
      mSubtitle.setText(SpeedHints.subtitleText(status));
      mLeft.setText(status.speedHintGps
                        ? context.getString(R.string.nogps_speed_table_left, SpeedHints.metersLeft(status, range))
                        : "");
      mGpsOff.setVisibility(status.speedHintGps ? View.GONE : View.VISIBLE);
      mStar.setVisibility(View.GONE);
      mMeter.clearPop();
      mMeter.set(progress(status), range, status.speedHintGps);
      describe();
      keepClearOfEndPanel();
    }
    setOpen(shown);
  }

  /**
   * GPS has measured the range of status.speedHintRange.
   */
  void celebrate(@NonNull NoGps.Status status)
  {
    // The bar slides out of the speed, the ring goes out of it.
    if (!SpeedHints.celebrates(status) || mSpeed.getVisibility() != View.VISIBLE)
      return;
    final Context context = mBar.getContext();
    final NoGps.SpeedMilestone milestone = status.getSpeedMilestone();
    final int range = status.speedHintRange;
    final int all = status.gpsSpeedTableScale.length;
    mCelebrating = true;
    mHandler.removeCallbacks(mEndCelebration);
    switch (milestone)
    {
    case RANGE ->
    {
      mTitle.setText(context.getString(SpeedHints.celebrationTitle(milestone), NoGps.speedTableFromKmh(range),
                                       NoGps.speedTableToKmh(range)));
      mSubtitle.setText(
          context.getString(SpeedHints.celebrationSubtitle(milestone), SpeedHints.measuredCount(status), all));
    }
    case FULL ->
    {
      mTitle.setText(SpeedHints.celebrationTitle(milestone));
      mSubtitle.setText(context.getString(SpeedHints.celebrationSubtitle(milestone), all));
    }
    case CITY, OUT_OF_TOWN ->
    {
      mTitle.setText(SpeedHints.celebrationTitle(milestone));
      mSubtitle.setText(SpeedHints.celebrationSubtitle(milestone));
    }
    }
    mLeft.setText("");
    mGpsOff.setVisibility(View.GONE);
    mStar.setVisibility(View.VISIBLE);
    mMeter.set(progress(status), -1, false);
    mMeter.pop(range);
    describe();
    keepClearOfEndPanel();
    animateColor(mDone);
    setOpen(true);

    mFlash.animate().cancel();
    mFlash.setAlpha(FLASH_ALPHA);
    mFlash.animate().alpha(0).setDuration(FLASH_MS).setInterpolator(new DecelerateInterpolator()).start();
    winIn(mTitle, 0);
    winIn(mSubtitle, WIN_IN_SUBTITLE_DELAY_MS);
    mStar.setScaleX(0);
    mStar.setScaleY(0);
    mStar.setRotation(STAR_TURN_DEG);
    mStar.animate()
        .scaleX(1)
        .scaleY(1)
        .rotation(0)
        .setDuration(STAR_MS)
        .setInterpolator(new OvershootInterpolator(3))
        .start();
    mBar.performHapticFeedback(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ? HapticFeedbackConstants.CONFIRM
                                                                              : HapticFeedbackConstants.VIRTUAL_KEY);
    throwConfetti(milestone != NoGps.SpeedMilestone.RANGE);
    mHandler.postDelayed(mEndCelebration, SpeedHints.celebrationMs(milestone));
  }

  /**
   * The map is not seen: everything stops, the bar is hidden.
   */
  void stop()
  {
    mHandler.removeCallbacks(mEndCelebration);
    mCelebrating = false;
    if (mRevealAnimator != null)
      mRevealAnimator.cancel();
    if (mColorAnimator != null)
      mColorAnimator.cancel();
    mOpen = false;
    setReveal(0);
    mBody.setAlpha(0);
    mBar.setBackgroundTintList(ColorStateList.valueOf(mAccent));
    mMeter.clearPop();
    if (mConfetti != null)
      mConfetti.stop();
  }

  /**
   * Moves with the speed, e.g. above the place page.
   */
  void setTranslationY(float translationY)
  {
    mFrame.setTranslationY(translationY);
  }

  private void endCelebration()
  {
    mCelebrating = false;
    setOpen(false);
  }

  @NonNull
  private static float[] progress(@NonNull NoGps.Status status)
  {
    final float[] progress = new float[status.gpsSpeedTableScale.length];
    for (int i = 0; i < progress.length; ++i)
      progress[i] = SpeedHints.progress(status, i);
    return progress;
  }

  private void describe()
  {
    mBar.setContentDescription(mTitle.getText() + ". " + mSubtitle.getText());
  }

  private void setOpen(boolean open)
  {
    if (open == mOpen)
      return;
    mOpen = open;
    if (mRevealAnimator != null)
      mRevealAnimator.cancel();
    mBody.animate().cancel();
    final float shift = BODY_SHIFT_DP * mDensity * (mBar.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL ? 1 : -1);
    if (open)
    {
      mBar.setVisibility(View.VISIBLE);
      mBody.setAlpha(0);
      mBody.setTranslationX(shift);
      mBody.animate()
          .alpha(1)
          .translationX(0)
          .setStartDelay(BODY_IN_DELAY_MS)
          .setDuration(BODY_IN_MS)
          .setInterpolator(new PathInterpolator(0.22f, 1, 0.36f, 1))
          .start();
    }
    else
    {
      mBody.animate().alpha(0).translationX(shift).setStartDelay(0).setDuration(BODY_OUT_MS).start();
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
        if (mCanceled || mOpen)
          return;
        // Back in the speed: the next bar is blue again.
        if (mColorAnimator != null)
          mColorAnimator.cancel();
        mBar.setBackgroundTintList(ColorStateList.valueOf(mAccent));
        mMeter.clearPop();
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
    final ColorStateList tint = mBar.getBackgroundTintList();
    final int from = tint != null ? tint.getDefaultColor() : mAccent;
    mColorAnimator = ValueAnimator.ofArgb(from, color);
    mColorAnimator.setDuration(COLOR_MS);
    mColorAnimator.addUpdateListener(
        a -> mBar.setBackgroundTintList(ColorStateList.valueOf((int) a.getAnimatedValue())));
    mColorAnimator.start();
  }

  private void winIn(@NonNull View view, long delayMs)
  {
    view.animate().cancel();
    view.setAlpha(0);
    view.setTranslationY(WIN_IN_SHIFT_DP * mDensity);
    view.setScaleX(WIN_IN_SCALE);
    view.setScaleY(WIN_IN_SCALE);
    view.setPivotX(mBar.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL ? view.getWidth() : 0);
    view.animate()
        .alpha(1)
        .translationY(0)
        .scaleX(1)
        .scaleY(1)
        .setStartDelay(delayMs)
        .setDuration(WIN_IN_MS)
        .setInterpolator(new OvershootInterpolator(2))
        .start();
  }

  /**
   * Confetti from the bar and a ring from the speed, and rain over the map for a milestone.
   */
  private void throwConfetti(boolean rain)
  {
    if (mConfetti == null || mConfetti.getWidth() == 0)
      return;
    final int[] origin = new int[2];
    mConfetti.getLocationInWindow(origin);
    final int[] bar = new int[2];
    mBar.getLocationInWindow(bar);
    final float barLeft = bar[0] - origin[0];
    final float barTop = bar[1] - origin[1];
    mConfetti.burst(barLeft + mBar.getHeight(), barLeft + mBar.getWidth() - mBar.getHeight() / 2f, barTop);
    final int[] speed = new int[2];
    mSpeed.getLocationInWindow(speed);
    mConfetti.ring(speed[0] - origin[0] + mSpeed.getWidth() / 2f, speed[1] - origin[1] + mSpeed.getHeight() / 2f,
                   mSpeed.getWidth() / 2f);
    if (rain)
      mConfetti.rain();
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
