package app.organicmaps.nogps.intro;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.util.AttributeSet;
import android.util.SizeF;
import android.util.TypedValue;
import android.view.MotionEvent;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import app.organicmaps.util.ThemeUtils;
import app.organicmaps.widget.ArrowPopupBackground;

/**
 * The intro of the first start over the whole map: the screen is dimmed but for the panel the step points at, and a
 * balloon with an arrow at that panel tells what it does. The text of the balloon is typed out, see IntroSequence. A
 * tap while it types shows the rest at once, the next tap opens the next step.
 * <p>
 * ArrowPopup is a PopupWindow and cannot dim the rest of the screen, so only its background drawable is reused.
 */
public class IntroOverlay extends View
{
  /**
   * The view of a step in the panels of the map, see MapButtonsController.getIntroAnchor().
   */
  public interface Anchors
  {
    @Nullable
    View get(@NonNull IntroStep step);
  }

  // A balloon is redrawn on it: the typewriter shows a character every third tick, and the balloon follows a panel
  // the user moves or a screen that turns.
  private static final long TICK_MS = 100;
  private static final int DIM_ALPHA = 0xB0;
  private static final float HOLE_PADDING_DP = 4;
  private static final float HOLE_RADIUS_DP = 16;
  // Between the tip of the arrow and the panel.
  private static final float BALLOON_GAP_DP = 6;
  private static final float BALLOON_PADDING_DP = 14;
  private static final float BALLOON_MARGIN_DP = 12;
  private static final float BALLOON_MAX_WIDTH_DP = 320;
  private static final float TEXT_SP = 16;

  private final IntroSequence mSequence = new IntroSequence();
  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final TextPaint mTextPaint = new TextPaint(TextPaint.ANTI_ALIAS_FLAG);
  private final Paint mDimPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Path mDimPath = new Path();
  private final Path mHolePath = new Path();
  private final RectF mAnchorRect = new RectF();
  private final int[] mLocation = new int[2];
  private final int[] mOwnLocation = new int[2];
  private final Runnable mTicker = this::onTick;

  @Nullable
  private Anchors mAnchors;
  @Nullable
  private Runnable mOnModal;
  @Nullable
  private Runnable mOnEnd;
  /**
   * Of the whole text: the balloon does not grow while the text is typed into it.
   */
  @Nullable
  private StaticLayout mFullLayout;
  @Nullable
  private StaticLayout mShownLayout;
  private String mText = "";
  private int mShownChars = -1;
  private long mStepStartMs;

  public IntroOverlay(@NonNull Context context)
  {
    this(context, null);
  }

  public IntroOverlay(@NonNull Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    mDimPaint.setColor(Color.argb(DIM_ALPHA, 0, 0, 0));
    mTextPaint.setColor(ThemeUtils.getColor(context, android.R.attr.textColorPrimary));
    mTextPaint.setTextSize(
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, TEXT_SP, context.getResources().getDisplayMetrics()));
  }

  /**
   * @param anchors the panels the balloons point at.
   * @param onModal shows the modal of the first step; the overlay waits for onModalClosed().
   * @param onEnd   the panels go back to their own rules.
   */
  public void start(@NonNull Anchors anchors, @NonNull Runnable onModal, @NonNull Runnable onEnd)
  {
    mAnchors = anchors;
    mOnModal = onModal;
    mOnEnd = onEnd;
    openStep();
  }

  public boolean isRunning()
  {
    return mAnchors != null && !mSequence.isOver();
  }

  /**
   * The modal was closed by its accent button, or dismissed: the balloons follow either way.
   */
  public void onModalClosed()
  {
    // A modal restored with the activity, whose intro this overlay never ran: the flag is set, nothing follows.
    if (!isRunning() || mSequence.step() != IntroStep.MODAL)
      return;
    advance();
  }

  /**
   * The navigation starts, or the map goes away: the intro is over and does not come back.
   */
  public void finish()
  {
    if (!isRunning())
      return;
    mSequence.finish();
    openStep();
  }

  /**
   * The text is shown whole: the step is over.
   */
  private void advance()
  {
    mSequence.tap(0, 0);
    openStep();
  }

  private void openStep()
  {
    mHandler.removeCallbacks(mTicker);
    final IntroStep step = mSequence.step();
    if (step == null)
    {
      setVisibility(GONE);
      mAnchors = null;
      final Runnable onEnd = mOnEnd;
      mOnEnd = null;
      mOnModal = null;
      if (onEnd != null)
        onEnd.run();
      return;
    }
    mStepStartMs = SystemClock.uptimeMillis();
    mText = step.getText(getContext());
    mFullLayout = null;
    mShownLayout = null;
    mShownChars = -1;
    if (step == IntroStep.MODAL)
    {
      // The modal dims the screen by itself, the overlay waits under it.
      setVisibility(GONE);
      if (mOnModal != null)
        mOnModal.run();
      return;
    }
    setContentDescription(mText);
    setVisibility(VISIBLE);
    invalidate();
    mHandler.postDelayed(mTicker, TICK_MS);
  }

  private void onTick()
  {
    if (mSequence.isOver())
      return;
    invalidate();
    mHandler.postDelayed(mTicker, TICK_MS);
  }

  private double elapsedS()
  {
    return (SystemClock.uptimeMillis() - mStepStartMs) / 1000.0;
  }

  @Override
  public boolean onTouchEvent(MotionEvent event)
  {
    if (!isRunning())
      return false;
    if (event.getActionMasked() != MotionEvent.ACTION_UP)
      return true;
    final boolean typing = mSequence.isTyping(mText.length(), elapsedS());
    mSequence.tap(mText.length(), elapsedS());
    // The rest of the text at once, or the next step.
    if (typing)
      invalidate();
    else
      openStep();
    return true;
  }

  @Override
  protected void onDetachedFromWindow()
  {
    super.onDetachedFromWindow();
    mHandler.removeCallbacks(mTicker);
  }

  @Override
  protected void onDraw(@NonNull Canvas canvas)
  {
    super.onDraw(canvas);
    final IntroStep step = mSequence.step();
    if (step == null || mAnchors == null)
      return;
    final View anchor = mAnchors.get(step);
    if (anchor == null || anchor.getVisibility() != VISIBLE)
    {
      // Nothing to point at: the step is skipped rather than shown with an arrow into the void.
      post(this::skipMissingAnchor);
      return;
    }
    // Not laid out yet: the next tick draws it.
    if (anchor.getWidth() == 0 || anchor.getHeight() == 0)
      return;
    anchorRect(anchor);
    drawDim(canvas);
    drawBalloon(canvas);
  }

  /**
   * Posted from onDraw(): the anchor of the step is taken again, so a second post of the same draw does not skip
   * the step after it too.
   */
  private void skipMissingAnchor()
  {
    final IntroStep step = mSequence.step();
    if (step == null || mAnchors == null)
      return;
    final View anchor = mAnchors.get(step);
    if (anchor == null || anchor.getVisibility() != VISIBLE)
      advance();
  }

  private void anchorRect(@NonNull View anchor)
  {
    anchor.getLocationInWindow(mLocation);
    getLocationInWindow(mOwnLocation);
    final float left = mLocation[0] - mOwnLocation[0];
    final float top = mLocation[1] - mOwnLocation[1];
    final float padding = dp(HOLE_PADDING_DP);
    mAnchorRect.set(left - padding, top - padding, left + anchor.getWidth() + padding,
                    top + anchor.getHeight() + padding);
  }

  private void drawDim(@NonNull Canvas canvas)
  {
    final float radius = dp(HOLE_RADIUS_DP);
    mDimPath.reset();
    mDimPath.addRect(0, 0, getWidth(), getHeight(), Path.Direction.CW);
    mHolePath.reset();
    mHolePath.addRoundRect(mAnchorRect, radius, radius, Path.Direction.CW);
    mDimPath.op(mHolePath, Path.Op.DIFFERENCE);
    canvas.drawPath(mDimPath, mDimPaint);
  }

  private void drawBalloon(@NonNull Canvas canvas)
  {
    final float padding = dp(BALLOON_PADDING_DP);
    final float margin = dp(BALLOON_MARGIN_DP);
    final float gap = dp(BALLOON_GAP_DP);
    final int maxTextWidth =
        (int) Math.min(dp(BALLOON_MAX_WIDTH_DP) - 2 * padding, getWidth() - 2 * margin - 2 * padding);
    if (maxTextWidth <= 0)
      return;
    if (mFullLayout == null)
      mFullLayout = layout(mText, Math.min(maxTextWidth, (int) Math.ceil(Layout.getDesiredWidth(mText, mTextPaint))));
    final int textWidth = mFullLayout.getWidth();
    final int shownChars = mSequence.revealed(mText.length(), elapsedS());
    if (shownChars != mShownChars)
    {
      mShownChars = shownChars;
      mShownLayout = layout(mText.substring(0, shownChars), textWidth);
    }
    final float arrowHeight = getResources().getDimension(R.dimen.routes_popup_arrow_height);
    final float width = textWidth + 2 * padding;
    final float height = mFullLayout.getHeight() + 2 * padding + arrowHeight;
    // Above the panel where it fits, else below it.
    final boolean below = mAnchorRect.top - gap - height < margin;
    final float top = below ? mAnchorRect.bottom + gap : mAnchorRect.top - gap - height;
    final float tip = Math.min(Math.max(mAnchorRect.centerX(), margin + dp(HOLE_RADIUS_DP)),
                               getWidth() - margin - dp(HOLE_RADIUS_DP));
    final float left = Math.min(Math.max(tip - width / 2, margin), Math.max(margin, getWidth() - margin - width));
    final ArrowPopupBackground background = background(below);
    background.setBounds((int) left, (int) top, (int) (left + width), (int) (top + height));
    background.setArrowCx(tip - left);
    background.draw(canvas);
    canvas.save();
    canvas.translate(left + padding, top + padding + (below ? arrowHeight : 0));
    if (mShownLayout != null)
      mShownLayout.draw(canvas);
    canvas.restore();
  }

  @NonNull
  private ArrowPopupBackground background(boolean arrowOnTop)
  {
    final Context context = getContext();
    return new ArrowPopupBackground(ThemeUtils.getColor(context, R.attr.cardBackground),
                                    ContextCompat.getColor(context, R.color.black_12),
                                    getResources().getDimension(R.dimen.corner_radius_medium),
                                    new SizeF(getResources().getDimension(R.dimen.routes_popup_arrow_width),
                                              getResources().getDimension(R.dimen.routes_popup_arrow_height)),
                                    getResources().getDimension(R.dimen.routes_popup_shadow_offset), arrowOnTop);
  }

  @NonNull
  private StaticLayout layout(@NonNull String text, int width)
  {
    return StaticLayout.Builder.obtain(text, 0, text.length(), mTextPaint, Math.max(1, width))
        .setAlignment(Layout.Alignment.ALIGN_NORMAL)
        .build();
  }

  private float dp(float value)
  {
    return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
  }
}
