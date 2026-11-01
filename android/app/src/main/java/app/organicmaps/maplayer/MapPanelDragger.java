package app.organicmaps.maplayer;

import android.content.res.ColorStateList;
import android.graphics.PorterDuff;
import android.os.Handler;
import android.os.Looper;
import android.view.Choreographer;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.constraintlayout.widget.ConstraintLayout;
import androidx.core.content.ContextCompat;
import androidx.core.graphics.ColorUtils;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;

/**
 * Moves a panel of map buttons up and down its free area, where a hand or a car holder may cover it. A long press
 * lifts the panel, the finger drags it, a quick release flings it on with a bounce at the ends. Its place is the
 * vertical bias of the panel in its frame: a fraction of the distance it can travel, so it stays when the frame or
 * the panel changes size.
 */
public class MapPanelDragger
{
  // A slower release leaves the panel where it is, dp/s.
  static final float FLING_SPEED = 800;
  // The speed of a fling is multiplied by it every ms, as in a scroll view of iOS.
  static final float DECELERATION = 0.998f;
  // The part of the speed kept by a bounce at an end.
  static final float BOUNCE = 0.6f;
  // A fling stops below it, dp/s.
  static final float STOP_SPEED = 30;
  // The middle of the frame.
  static final float DEFAULT_FRACTION = 0.5f;
  private static final float LIFTED_SCALE = 1.08f;
  private static final int LIFTED_TINT_ALPHA = 0x33;

  /**
   * One frame of a fling: the place and the speed after dt seconds. The speed goes down as in a scroll view, the
   * panel bounces back from min and max and stops at a low speed.
   *
   * @return the place and the speed.
   */
  @NonNull
  static float[] step(float y, float v, float dt, float min, float max)
  {
    final double rate = Math.log(DECELERATION) * 1000;
    final double decay = Math.exp(rate * dt);
    float newY = (float) (y + v * (decay - 1) / rate);
    float newV = (float) (v * decay);
    if (newY > max)
    {
      newY = max - (newY - max) * BOUNCE;
      newV = -newV * BOUNCE;
    }
    else if (newY < min)
    {
      newY = min + (min - newY) * BOUNCE;
      newV = -newV * BOUNCE;
    }
    if (Math.abs(newV) < STOP_SPEED)
      newV = 0;
    return new float[] {Math.min(Math.max(newY, min), max), newV};
  }

  /**
   * Whether a release with the speed v flings the panel on.
   */
  static boolean flings(float v)
  {
    return Math.abs(v) >= FLING_SPEED;
  }

  /**
   * Gives the touches on the panel to a dragger, over its buttons too.
   *
   * @param atStart the panel is docked to the start edge of the screen, otherwise to the end one.
   */
  @NonNull
  static MapPanelDragger attach(@NonNull MapPanelLayout panel, @NonNull String key, boolean atStart)
  {
    final MapPanelDragger dragger = new MapPanelDragger(panel, key, atStart);
    panel.setDragger(dragger);
    return dragger;
  }

  @NonNull
  private final View mPanel;
  @NonNull
  private final String mKey;
  private final boolean mAtStart;
  private final float mDensity;
  private final int mTouchSlop;
  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mLift = this::lift;
  private final Choreographer.FrameCallback mFrameCallback = this::onFrame;
  @Nullable
  private VelocityTracker mTracker;
  private float mFraction;
  private boolean mEnabled = true;
  private boolean mLifted;
  // In dp from the top of the travel.
  private float mY;
  // dp/s.
  private float mV;
  private float mStartY;
  // Raw, px.
  private float mDownX;
  private float mDownY;
  private float mTouchY;
  private float mStartTouch;
  private long mLastFrameNanos;

  private MapPanelDragger(@NonNull View panel, @NonNull String key, boolean atStart)
  {
    mPanel = panel;
    mKey = key;
    mAtStart = atStart;
    mDensity = panel.getResources().getDisplayMetrics().density;
    mTouchSlop = ViewConfiguration.get(panel.getContext()).getScaledTouchSlop();
    mFraction = MwmApplication.prefs(panel.getContext()).getFloat(key, DEFAULT_FRACTION);
    applyFraction();
  }

  /**
   * A hidden panel can't be moved.
   */
  void setEnabled(boolean enabled)
  {
    mEnabled = enabled;
    if (!enabled)
      stop();
  }

  /**
   * Puts the panel down where it is.
   */
  void stop()
  {
    endTouch();
    drop();
  }

  /**
   * Takes every event of a touch on the panel once.
   *
   * @return true while the panel is lifted: the touch is taken from the button under the finger, it does not fire.
   */
  boolean onTouch(@NonNull MotionEvent event)
  {
    if (!mEnabled)
      return false;
    final boolean lifted = mLifted;
    mTouchY = event.getRawY();
    switch (event.getActionMasked())
    {
    case MotionEvent.ACTION_DOWN:
      mDownX = event.getRawX();
      mDownY = event.getRawY();
      endTouch();
      mTracker = VelocityTracker.obtain();
      addMovement(event);
      mHandler.postDelayed(mLift, ViewConfiguration.getLongPressTimeout());
      break;
    case MotionEvent.ACTION_MOVE:
      addMovement(event);
      if (lifted)
        move(mStartY + (mTouchY - mStartTouch) / mDensity);
      else if (Math.hypot(event.getRawX() - mDownX, event.getRawY() - mDownY) > mTouchSlop)
        cancelPress();
      break;
    case MotionEvent.ACTION_UP:
      addMovement(event);
      if (lifted)
        release();
      endTouch();
      break;
    case MotionEvent.ACTION_CANCEL:
      endTouch();
      drop();
      break;
    }
    return lifted;
  }

  // The panel moves under the finger: the speed is taken on the screen.
  private void addMovement(@NonNull MotionEvent event)
  {
    if (mTracker == null)
      return;
    final MotionEvent onScreen = MotionEvent.obtain(event);
    onScreen.setLocation(event.getRawX(), event.getRawY());
    mTracker.addMovement(onScreen);
    onScreen.recycle();
  }

  private void cancelPress()
  {
    mHandler.removeCallbacks(mLift);
  }

  private void endTouch()
  {
    cancelPress();
    if (mTracker != null)
    {
      mTracker.recycle();
      mTracker = null;
    }
  }

  private void lift()
  {
    stopFling();
    mLifted = true;
    mY = mFraction * travel();
    mStartY = mY;
    mStartTouch = mTouchY;
    mPanel.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
    // Bigger, still docked to its edge of the screen.
    final boolean rtl = mPanel.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
    mPanel.setPivotX(mAtStart != rtl ? 0 : mPanel.getWidth());
    mPanel.setPivotY(mPanel.getHeight() / 2f);
    mPanel.animate().scaleX(LIFTED_SCALE).scaleY(LIFTED_SCALE);
    final int accent = ContextCompat.getColor(mPanel.getContext(), R.color.base_accent);
    mPanel.setBackgroundTintMode(PorterDuff.Mode.SRC_ATOP);
    mPanel.setBackgroundTintList(ColorStateList.valueOf(ColorUtils.setAlphaComponent(accent, LIFTED_TINT_ALPHA)));
  }

  private void release()
  {
    float speed = 0;
    if (mTracker != null)
    {
      mTracker.computeCurrentVelocity(1000);
      speed = mTracker.getYVelocity() / mDensity;
    }
    if (flings(speed) && travel() > 0)
      fling(speed);
    else
      drop();
  }

  private void drop()
  {
    stopFling();
    if (!mLifted)
      return;
    mLifted = false;
    MwmApplication.prefs(mPanel.getContext()).edit().putFloat(mKey, mFraction).apply();
    mPanel.animate().scaleX(1).scaleY(1);
    mPanel.setBackgroundTintList(null);
  }

  // The distance the panel can travel in its frame, dp.
  private float travel()
  {
    final View frame = (View) mPanel.getParent();
    final int travel = frame.getHeight() - frame.getPaddingTop() - frame.getPaddingBottom() - mPanel.getHeight();
    return Math.max(0, travel) / mDensity;
  }

  private void move(float y)
  {
    final float travel = travel();
    if (travel <= 0)
      return;
    mY = Math.min(Math.max(y, 0), travel);
    mFraction = mY / travel;
    applyFraction();
  }

  private void applyFraction()
  {
    final ConstraintLayout.LayoutParams params = (ConstraintLayout.LayoutParams) mPanel.getLayoutParams();
    params.verticalBias = mFraction;
    mPanel.setLayoutParams(params);
  }

  private void fling(float speed)
  {
    mV = speed;
    mLastFrameNanos = System.nanoTime();
    Choreographer.getInstance().postFrameCallback(mFrameCallback);
  }

  private void onFrame(long frameTimeNanos)
  {
    final float dt = Math.max(0, frameTimeNanos - mLastFrameNanos) / 1e9f;
    mLastFrameNanos = frameTimeNanos;
    final float[] next = step(mY, mV, dt, 0, travel());
    mV = next[1];
    move(next[0]);
    if (mV == 0)
      drop();
    else
      Choreographer.getInstance().postFrameCallback(mFrameCallback);
  }

  private void stopFling()
  {
    Choreographer.getInstance().removeFrameCallback(mFrameCallback);
  }
}
