package app.organicmaps.maplayer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Path;
import android.graphics.RectF;
import android.util.AttributeSet;
import android.widget.FrameLayout;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * The half circle of the navigation search wheel. It shows the sector swept so far by a radius from the middle of
 * its flat side, from the top down through the side of the map.
 */
public class SearchWheelFrame extends FrameLayout
{
  // Degrees.
  static final float FULL_SWEEP = 180;
  // The top, as the angles of a canvas: clockwise from the east.
  private static final float TOP = 270;

  /**
   * Where the clockwise arc of the given sweep starts. In LTR the map is to the west: the sweep goes counterclockwise
   * from the top, so the arc ends at the top. In RTL it goes clockwise from the top.
   */
  static float sectorStart(float sweep, boolean rtl)
  {
    return rtl ? TOP : TOP - sweep;
  }

  private final Path mClip = new Path();
  private final RectF mOval = new RectF();
  private float mSweep;

  public SearchWheelFrame(@NonNull Context context)
  {
    super(context);
  }

  public SearchWheelFrame(@NonNull Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
  }

  float getSweep()
  {
    return mSweep;
  }

  void setSweep(float sweep)
  {
    mSweep = sweep;
    invalidate();
  }

  // Not dispatchDraw(): the half circle is the background.
  @Override
  public void draw(@NonNull Canvas canvas)
  {
    if (mSweep >= FULL_SWEEP)
    {
      super.draw(canvas);
      return;
    }
    final boolean rtl = getLayoutDirection() == LAYOUT_DIRECTION_RTL;
    final float x = rtl ? 0 : getWidth();
    final float y = getHeight() / 2f;
    // To the corners of the frame.
    final float r = (float) Math.hypot(getWidth(), y);
    mOval.set(x - r, y - r, x + r, y + r);
    mClip.rewind();
    mClip.moveTo(x, y);
    mClip.arcTo(mOval, sectorStart(mSweep, rtl), mSweep);
    mClip.close();
    final int saved = canvas.save();
    canvas.clipPath(mClip);
    super.draw(canvas);
    canvas.restoreToCount(saved);
  }
}
