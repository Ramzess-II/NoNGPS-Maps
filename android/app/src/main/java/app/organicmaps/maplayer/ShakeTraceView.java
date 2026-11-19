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
 * The trace of the shake of the sensor box in the last 3 s on a white track, newest on the right. A dashed line is at
 * the limit of the stillness: the trace is orange above it and green below.
 */
public class ShakeTraceView extends View
{
  // The box sends a line every 20 ms: the trace of 3 s has so many.
  static final int LINES = 150;
  // The trace shows this much of the shake in percent of the limit of the stillness.
  static final float TOP_PERCENT = 200;
  static final float LIMIT_PERCENT = 100;

  private final Paint mTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mLine = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mLimit = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Path mPath = new Path();
  private final int mAbove;
  private final int mBelow;
  private final float mRadius;
  @NonNull
  private int[] mValues = new int[0];

  public ShakeTraceView(@NonNull Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    final float density = getResources().getDisplayMetrics().density;
    mAbove = ContextCompat.getColor(context, R.color.calibration_bar_accent);
    mBelow = ContextCompat.getColor(context, R.color.speed_hint_done);
    mRadius = 5 * density;
    mTrack.setColor(0xEBFFFFFF);
    mLine.setStyle(Paint.Style.STROKE);
    mLine.setStrokeWidth(1.5f * density);
    mLine.setStrokeJoin(Paint.Join.ROUND);
    mLimit.setStyle(Paint.Style.STROKE);
    mLimit.setStrokeWidth(density);
    mLimit.setColor(0xFF666666);
    mLimit.setPathEffect(new DashPathEffect(new float[] {3 * density, 3 * density}, 0));
  }

  /**
   * @param values the shake in percent of the limit, the oldest first, at most {@link #LINES} are shown.
   */
  public void setValues(@NonNull int[] values)
  {
    mValues = values;
    invalidate();
  }

  @Override
  protected void onDraw(@NonNull Canvas canvas)
  {
    final int width = getWidth();
    final int height = getHeight();
    canvas.drawRoundRect(0, 0, width, height, mRadius, mRadius, mTrack);
    final float limitY = height * (1 - LIMIT_PERCENT / TOP_PERCENT);
    canvas.drawLine(0, limitY, width, limitY, mLimit);
    final int count = Math.min(mValues.length, LINES);
    if (count == 0)
      return;
    final float step = width / (float) (LINES - 1);
    final int first = LINES - count;
    mPath.rewind();
    for (int i = 0; i < count; ++i)
    {
      final float value = Math.min(Math.max(mValues[mValues.length - count + i], 0), TOP_PERCENT);
      final float x = (first + i) * step;
      final float y = height * (1 - value / TOP_PERCENT);
      if (i == 0)
        mPath.moveTo(x, y);
      else
        mPath.lineTo(x, y);
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
