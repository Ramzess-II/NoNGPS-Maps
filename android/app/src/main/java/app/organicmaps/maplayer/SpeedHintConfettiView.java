package app.organicmaps.maplayer;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.SystemClock;
import android.util.AttributeSet;
import android.view.View;
import android.view.animation.LinearInterpolator;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * Over the whole map, takes no touches: the confetti and the ring of the celebration of the speed calibration, see
 * SpeedHintView. Drawn by the view itself.
 */
public class SpeedHintConfettiView extends View
{
  private static final int[] COLORS = {0xFFFFD54A, 0xFFFF6B6B, 0xFF4ADE80, 0xFF60A5FA, 0xFFF472B6, 0xFFFFFFFF};
  private static final int BURST_PIECES = 28;
  private static final long BURST_MS = 1400;
  private static final long BURST_MAX_DELAY_MS = 180;
  // The pieces fly up to their peak at this part of their time, then fall and fade.
  private static final float BURST_PEAK = 0.55f;
  private static final int RAIN_PIECES = 44;
  private static final long RAIN_MIN_MS = 2200;
  private static final long RAIN_MAX_EXTRA_MS = 900;
  private static final long RAIN_MIN_DELAY_MS = 200;
  private static final long RAIN_MAX_DELAY_MS = 1400;
  private static final float RAIN_FADE = 0.85f;
  private static final long RING_MS = 900;
  private static final int RING_PULSES = 2;
  private static final float RING_DP = 3;

  private static final class Piece
  {
    float mX;
    float mY;
    // How far it flies: up to its peak for a burst, down for the rain.
    float mDx;
    float mDy;
    float mTurnsDeg;
    float mWidth;
    float mHeight;
    int mColor;
    long mDelayMs;
    long mDurationMs;
    boolean mRain;
  }

  private final float mDensity;
  private final Paint mPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mRingPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final RectF mRect = new RectF();
  private final List<Piece> mPieces = new ArrayList<>();
  private final Random mRandom = new Random();
  private float mRingX;
  private float mRingY;
  private float mRingRadius;
  private long mRingStartMs = -1;
  private long mStartMs;
  private long mNowMs;
  @Nullable
  private ValueAnimator mAnimator;

  public SpeedHintConfettiView(Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    mDensity = context.getResources().getDisplayMetrics().density;
    mRingPaint.setStyle(Paint.Style.STROKE);
    mRingPaint.setStrokeWidth(RING_DP * mDensity);
    mRingPaint.setColor(ContextCompat.getColor(context, R.color.speed_hint_gold));
  }

  /**
   * Confetti burst up from the top of the bar, the coordinates are in this view.
   */
  void burst(float left, float right, float top)
  {
    final long offsetMs = elapsedMs();
    for (int i = 0; i < BURST_PIECES; ++i)
    {
      final Piece piece = new Piece();
      piece.mX = left + mRandom.nextFloat() * (right - left);
      piece.mY = top;
      piece.mDx = (mRandom.nextFloat() * 2 - 1) * 110 * mDensity;
      piece.mDy = -(95 + mRandom.nextFloat() * 170) * mDensity;
      piece.mTurnsDeg = (mRandom.nextBoolean() ? 1 : -1) * (360 + mRandom.nextFloat() * 140);
      setSize(piece, 5 + 2 * (i % 3));
      piece.mColor = COLORS[i % COLORS.length];
      piece.mDelayMs = offsetMs + (long) (mRandom.nextFloat() * BURST_MAX_DELAY_MS);
      piece.mDurationMs = BURST_MS;
      mPieces.add(piece);
    }
    start();
  }

  /**
   * Confetti rain over the whole map.
   */
  void rain()
  {
    final long offsetMs = elapsedMs();
    for (int i = 0; i < RAIN_PIECES; ++i)
    {
      final Piece piece = new Piece();
      piece.mX = mRandom.nextFloat() * getWidth();
      piece.mY = -16 * mDensity;
      piece.mDx = (mRandom.nextFloat() * 2 - 1) * 30 * mDensity;
      piece.mDy = getHeight() + 32 * mDensity;
      piece.mTurnsDeg = 720;
      setSize(piece, 8);
      piece.mColor = COLORS[i % COLORS.length];
      piece.mDelayMs = offsetMs + RAIN_MIN_DELAY_MS + (long) (mRandom.nextFloat() * RAIN_MAX_DELAY_MS);
      piece.mDurationMs = RAIN_MIN_MS + (long) (mRandom.nextFloat() * RAIN_MAX_EXTRA_MS);
      piece.mRain = true;
      mPieces.add(piece);
    }
    start();
  }

  /**
   * Two rings spread from the circle, the coordinates are in this view.
   */
  void ring(float centerX, float centerY, float radius)
  {
    mRingX = centerX;
    mRingY = centerY;
    mRingRadius = radius;
    mRingStartMs = elapsedMs();
    start();
  }

  void stop()
  {
    final ValueAnimator animator = mAnimator;
    mAnimator = null;
    if (animator != null)
      animator.cancel();
    mPieces.clear();
    mRingStartMs = -1;
    invalidate();
  }

  private void setSize(@NonNull Piece piece, float widthDp)
  {
    piece.mWidth = widthDp * mDensity;
    piece.mHeight = (widthDp + 4) * mDensity;
  }

  /**
   * @return the time since the pieces in the air started: the pieces added now start later by it.
   */
  private long elapsedMs()
  {
    return mAnimator != null ? SystemClock.uptimeMillis() - mStartMs : 0;
  }

  private void start()
  {
    if (mAnimator != null)
      return;
    mStartMs = SystemClock.uptimeMillis();
    mNowMs = 0;
    mAnimator = ValueAnimator.ofFloat(0, 1);
    mAnimator.setInterpolator(new LinearInterpolator());
    mAnimator.setDuration(RING_MS);
    mAnimator.setRepeatCount(ValueAnimator.INFINITE);
    mAnimator.addUpdateListener(a -> {
      mNowMs = SystemClock.uptimeMillis() - mStartMs;
      if (isFinished())
        stop();
      else
        invalidate();
    });
    // With the animations switched off in the system settings it ends at once.
    mAnimator.addListener(new AnimatorListenerAdapter() {
      @Override
      public void onAnimationEnd(Animator animation)
      {
        if (mAnimator == animation)
          stop();
      }
    });
    mAnimator.start();
  }

  private boolean isFinished()
  {
    for (Piece piece : mPieces)
      if (mNowMs < piece.mDelayMs + piece.mDurationMs)
        return false;
    return mRingStartMs < 0 || mNowMs >= mRingStartMs + RING_MS * RING_PULSES;
  }

  @Override
  protected void onDetachedFromWindow()
  {
    super.onDetachedFromWindow();
    stop();
  }

  @Override
  protected void onDraw(@NonNull Canvas canvas)
  {
    for (Piece piece : mPieces)
      drawPiece(canvas, piece);
    if (mRingStartMs >= 0)
    {
      final long ringMs = mNowMs - mRingStartMs;
      if (ringMs >= 0 && ringMs < RING_MS * RING_PULSES)
      {
        final float t = (ringMs % RING_MS) / (float) RING_MS;
        mRingPaint.setAlpha((int) (255 * (1 - t)));
        canvas.drawCircle(mRingX, mRingY, mRingRadius * (1 + t), mRingPaint);
      }
    }
  }

  private void drawPiece(@NonNull Canvas canvas, @NonNull Piece piece)
  {
    final long ms = mNowMs - piece.mDelayMs;
    if (ms < 0 || ms >= piece.mDurationMs)
      return;
    final float t = ms / (float) piece.mDurationMs;
    final float x;
    final float y;
    final float alpha;
    if (piece.mRain)
    {
      x = piece.mX + piece.mDx * (float) Math.sin(2 * Math.PI * t);
      y = piece.mY + piece.mDy * t;
      alpha = t < RAIN_FADE ? 1 : (1 - t) / (1 - RAIN_FADE);
    }
    else
    {
      // Up to the peak and a third of the way back down.
      final float u = t / BURST_PEAK;
      x = piece.mX + piece.mDx * (1 - (1 - t) * (1 - t));
      y = piece.mY + piece.mDy * (2 * u - u * u);
      alpha = t < BURST_PEAK ? 1 : (1 - t) / (1 - BURST_PEAK);
    }
    mPaint.setColor(piece.mColor);
    mPaint.setAlpha((int) (255 * Math.max(0, Math.min(1, alpha))));
    canvas.save();
    canvas.rotate(piece.mTurnsDeg * t, x, y);
    mRect.set(x - piece.mWidth / 2, y - piece.mHeight / 2, x + piece.mWidth / 2, y + piece.mHeight / 2);
    canvas.drawRoundRect(mRect, 2 * mDensity, 2 * mDensity, mPaint);
    canvas.restore();
  }
}
