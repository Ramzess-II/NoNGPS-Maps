package app.organicmaps.maplayer;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.AttributeSet;
import android.view.View;
import android.view.animation.LinearInterpolator;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;

/**
 * The ranges of the speed table on the bar of the speed calibration: the measured ones filled, the range of the speed
 * outlined and filled as far as it is driven, pulsing while GPS measures it. A range just measured pops in gold.
 */
public class SpeedHintMeterView extends View
{
  private static final float SEGMENT_DP = 5;
  private static final float GAP_DP = 3;
  private static final float OUTLINE_DP = 1.5f;
  private static final int TRACK_COLOR = 0x4DFFFFFF;
  private static final int FILL_COLOR = 0xFFFFFFFF;
  private static final long PULSE_MS = 1000;
  private static final long POP_MS = 650;
  private static final float POP_PEAK = 0.4f;
  private static final float POP_SCALE_X = 0.6f;
  private static final float POP_SCALE_Y = 1.6f;

  private final float mDensity;
  private final Paint mTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mFill = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mGold = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mOutline = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final RectF mRect = new RectF();
  @NonNull
  private float[] mProgress = new float[0];
  private int mCurrent = -1;
  private boolean mLive;
  private int mPop = -1;
  private float mPopFraction = 1;
  private float mPulse;
  @Nullable
  private ValueAnimator mPulseAnimator;
  @Nullable
  private ValueAnimator mPopAnimator;

  public SpeedHintMeterView(Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    mDensity = context.getResources().getDisplayMetrics().density;
    mTrack.setColor(TRACK_COLOR);
    mFill.setColor(FILL_COLOR);
    mGold.setColor(ContextCompat.getColor(context, R.color.speed_hint_gold));
    mOutline.setColor(FILL_COLOR);
    mOutline.setStyle(Paint.Style.STROKE);
    mOutline.setStrokeWidth(OUTLINE_DP * mDensity);
  }

  /**
   * @param progress of every range, 1 for a measured one.
   * @param current  the range of the speed, -1 for none.
   * @param live     GPS measures the current range now.
   */
  void set(@NonNull float[] progress, int current, boolean live)
  {
    mProgress = progress;
    mCurrent = current;
    mLive = live && current >= 0 && current < progress.length && progress[current] < 1;
    updatePulse();
    invalidate();
  }

  /**
   * The range just measured grows and shrinks back, in gold.
   */
  void pop(int range)
  {
    mPop = range;
    if (mPopAnimator != null)
      mPopAnimator.cancel();
    mPopAnimator = ValueAnimator.ofFloat(0, 1);
    mPopAnimator.setDuration(POP_MS);
    mPopAnimator.addUpdateListener(a -> {
      mPopFraction = (float) a.getAnimatedValue();
      invalidate();
    });
    mPopAnimator.start();
  }

  /**
   * The gold of the range popped stays until set again.
   */
  void clearPop()
  {
    mPop = -1;
    invalidate();
  }

  private void updatePulse()
  {
    final boolean pulse = mLive && isAttachedToWindow();
    if (pulse && mPulseAnimator == null)
    {
      mPulseAnimator = ValueAnimator.ofFloat(0, 1);
      mPulseAnimator.setDuration(PULSE_MS);
      mPulseAnimator.setRepeatCount(ValueAnimator.INFINITE);
      mPulseAnimator.setInterpolator(new LinearInterpolator());
      mPulseAnimator.addUpdateListener(a -> {
        mPulse = (float) a.getAnimatedValue();
        invalidate();
      });
      mPulseAnimator.start();
    }
    else if (!pulse && mPulseAnimator != null)
    {
      mPulseAnimator.cancel();
      mPulseAnimator = null;
      mPulse = 0;
    }
  }

  @Override
  protected void onAttachedToWindow()
  {
    super.onAttachedToWindow();
    updatePulse();
  }

  @Override
  protected void onDetachedFromWindow()
  {
    super.onDetachedFromWindow();
    if (mPulseAnimator != null)
      mPulseAnimator.cancel();
    mPulseAnimator = null;
    if (mPopAnimator != null)
      mPopAnimator.end();
  }

  @Override
  protected void onDraw(@NonNull Canvas canvas)
  {
    final int count = mProgress.length;
    if (count == 0)
      return;
    final float gap = GAP_DP * mDensity;
    final float height = SEGMENT_DP * mDensity;
    final float radius = height / 2;
    final float width = (getWidth() - getPaddingLeft() - getPaddingRight() - gap * (count - 1)) / count;
    final float top = (getHeight() - height) / 2;
    final boolean rtl = getLayoutDirection() == LAYOUT_DIRECTION_RTL;
    for (int i = 0; i < count; ++i)
    {
      final int slot = rtl ? count - 1 - i : i;
      final float left = getPaddingLeft() + slot * (width + gap);
      canvas.save();
      if (i == mPop)
      {
        // Up to the peak and back.
        final float k = mPopFraction < POP_PEAK ? mPopFraction / POP_PEAK : (1 - mPopFraction) / (1 - POP_PEAK);
        canvas.scale(1 + POP_SCALE_X * k, 1 + POP_SCALE_Y * k, left + width / 2, top + height / 2);
      }
      mRect.set(left, top, left + width, top + height);
      canvas.drawRoundRect(mRect, radius, radius, mTrack);
      final float filled = width * mProgress[i];
      if (filled > 0)
      {
        final Paint paint = i == mPop ? mGold : mFill;
        paint.setAlpha(i == mCurrent && mLive ? (int) (255 * (1 - 0.5f * Math.sin(Math.PI * mPulse))) : 255);
        if (rtl)
          mRect.set(left + width - filled, top, left + width, top + height);
        else
          mRect.set(left, top, left + filled, top + height);
        canvas.drawRoundRect(mRect, radius, radius, paint);
      }
      if (i == mCurrent && mProgress[i] < 1)
      {
        final float inset = -mOutline.getStrokeWidth() / 2;
        mRect.set(left, top, left + width, top + height);
        mRect.inset(inset, inset);
        canvas.drawRoundRect(mRect, radius - inset, radius - inset, mOutline);
      }
      canvas.restore();
    }
  }
}
