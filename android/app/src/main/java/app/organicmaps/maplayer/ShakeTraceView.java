package app.organicmaps.maplayer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.Path;
import android.util.AttributeSet;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;

/**
 * The trace of the shake of the sensor box in the last 3 s on a white track, newest on the right. The dashed line is at
 * the limit of the stillness, 45% from the top: below it the scale is linear from 0 to the limit, above it log10 up to
 * 10 times the limit, with faint guide lines at 3x and 10x. The line is orange above the limit and green below. The
 * last 2 s are shaded, green when all of them are under the limit. A value over the top of the scale is drawn on the
 * top edge with a red tick.
 */
public class ShakeTraceView extends View
{
  // The box sends a line every 20 ms: the trace of 3 s has so many.
  static final int LINES = 150;
  static final int LINE_MS = 20;
  // The box wants the car still for this long to tell STILL, the last so many lines are shaded.
  static final int HOLD_MS = 2000;
  static final int HOLD_LINES = HOLD_MS / LINE_MS;
  // The limit of the stillness in percent, and the top of the scale (kTraceTopPercent of the core's docs).
  static final float LIMIT_PERCENT = 100;
  static final float TOP_PERCENT = 1000;
  static final float LIMIT_FRACTION = 0.45f;

  private final Paint mTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mLine = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mLimit = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mGuide = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mHold = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mTick = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Path mPath = new Path();
  private final int mAbove;
  private final int mBelow;
  private final float mRadius;
  private final float mDensity;
  @NonNull
  private int[] mValues = new int[0];
  private boolean mShowsHold = true;

  public ShakeTraceView(@NonNull Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    mDensity = getResources().getDisplayMetrics().density;
    mAbove = ContextCompat.getColor(context, R.color.calibration_bar_accent);
    mBelow = ContextCompat.getColor(context, R.color.speed_hint_done);
    mRadius = 5 * mDensity;
    mTrack.setColor(0xEBFFFFFF);
    mLine.setStyle(Paint.Style.STROKE);
    mLine.setStrokeWidth(1.5f * mDensity);
    mLine.setStrokeJoin(Paint.Join.ROUND);
    mLimit.setStyle(Paint.Style.STROKE);
    mLimit.setStrokeWidth(mDensity);
    mLimit.setColor(0xFF666666);
    mLimit.setPathEffect(new DashPathEffect(new float[] {3 * mDensity, 3 * mDensity}, 0));
    mGuide.setStyle(Paint.Style.STROKE);
    mGuide.setStrokeWidth(mDensity);
    mGuide.setColor(0x1F000000);
    mTick.setStyle(Paint.Style.STROKE);
    mTick.setStrokeWidth(2 * mDensity);
    mTick.setColor(0xFFFF3B30);
  }

  /**
   * y of a shake value in a view of the height: 0 is the bottom, the limit is at {@link #LIMIT_FRACTION} from the top,
   * the top of the scale and more is the top edge.
   */
  static float y(float value, float height)
  {
    final float limitY = height * LIMIT_FRACTION;
    value = Math.max(value, 0);
    if (value <= LIMIT_PERCENT)
      return height - (height - limitY) * value / LIMIT_PERCENT;
    final double above =
        Math.log10(Math.min(value, TOP_PERCENT) / LIMIT_PERCENT) / Math.log10(TOP_PERCENT / LIMIT_PERCENT);
    return (float) (limitY * (1 - above));
  }

  /**
   * How long the car has been still by the trace: the newest values under the limit in a row, at most {@link #HOLD_MS}.
   */
  static int heldMs(@NonNull int[] values)
  {
    int held = 0;
    for (int i = values.length - 1; i >= 0 && values[i] < LIMIT_PERCENT && held < HOLD_LINES; --i)
      ++held;
    return held * LINE_MS;
  }

  /**
   * @param values the shake in percent of the limit, the oldest first, at most {@link #LINES} are shown.
   */
  public void setValues(@NonNull int[] values)
  {
    mValues = values;
    invalidate();
  }

  /**
   * The hold window is shaded: not while the box measures.
   */
  public void setShowsHold(boolean shows)
  {
    mShowsHold = shows;
    invalidate();
  }

  @Override
  protected void onDraw(@NonNull Canvas canvas)
  {
    final int width = getWidth();
    final int height = getHeight();
    canvas.drawRoundRect(0, 0, width, height, mRadius, mRadius, mTrack);
    final float step = width / (float) (LINES - 1);
    if (mShowsHold)
    {
      mHold.setColor(heldMs(mValues) >= HOLD_MS ? 0x2915803D : 0x29FF9500);
      canvas.drawRect(step * (LINES - HOLD_LINES), 0, width, height, mHold);
    }
    for (float percent : new float[] {3 * LIMIT_PERCENT, TOP_PERCENT})
    {
      final float guideY = y(percent, height);
      canvas.drawLine(0, guideY, width, guideY, mGuide);
    }
    final float limitY = y(LIMIT_PERCENT, height);
    canvas.drawLine(0, limitY, width, limitY, mLimit);
    final int count = Math.min(mValues.length, LINES);
    if (count == 0)
      return;
    final int first = LINES - count;
    mPath.rewind();
    for (int i = 0; i < count; ++i)
    {
      final int value = mValues[mValues.length - count + i];
      final float x = (first + i) * step;
      final float y = y(value, height);
      if (i == 0)
        mPath.moveTo(x, y);
      else
        mPath.lineTo(x, y);
      if (value > TOP_PERCENT)
        canvas.drawLine(x, 0, x, 4 * mDensity, mTick);
    }
    canvas.save();
    canvas.clipRect(0, 0, width, limitY);
    mLine.setColor(mAbove);
    canvas.drawPath(mPath, mLine);
    canvas.restore();
    canvas.save();
    canvas.clipRect(0, limitY, width, height);
    mLine.setColor(mBelow);
    canvas.drawPath(mPath, mLine);
    canvas.restore();
  }
}
