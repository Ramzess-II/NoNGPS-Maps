package app.organicmaps.nogps;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.provider.Settings;
import android.util.AttributeSet;
import android.view.Choreographer;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import androidx.annotation.ColorInt;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;

/**
 * The globe of About NonGPS Maps: the Earth, the GPS constellation and the jammed area with the car, which the finger
 * spins. The model is {@link GlobeScene}, this view draws it and turns touches into its calls. GlobeSceneView.swift
 * is the same on iOS.
 */
public class GlobeSceneView extends View implements Choreographer.FrameCallback
{
  public interface Listener
  {
    void onSatellitesChanged(int on, int total);
  }

  private static final int GRATICULE_STEP_DEG = 30;
  private static final int SAMPLE_STEP_DEG = 6;
  private static final int JAM_RING_POINTS = 48;
  // A frame after a pause, e.g. a stopped activity, is not a jump of the whole pause.
  private static final double MAX_FRAME_MS = 100;
  private static final float SATELLITE_RADIUS_DP = 3.5f;
  private static final float PANEL_LENGTH_DP = 5.5f;
  private static final float BREAK_DP = 5;
  private static final float DIM_ALPHA = 0.35f;
  private static final float BACK_GRATICULE_ALPHA = 0.35f;
  // The coverage is computed for a pixel of the bitmap per dp of the disc, and drawn scaled with filtering.
  private static final float COVERAGE_PIXELS_PER_DP = 1;

  // The unit vectors of the Earth frame, which do not change: the graticule, the coast and the rim of the jam.
  private static final double[][] GRATICULE = buildGraticule();
  private static final double[][] COAST = buildCoast();
  private static final double[][] JAM_RING = buildJamRing();

  private final GlobeScene mScene = new GlobeScene();
  private final Paint mFill = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mStroke = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint mBitmapPaint = new Paint(Paint.FILTER_BITMAP_FLAG);
  private final DashPathEffect mDash = new DashPathEffect(new float[] {5, 4}, 0);
  private final Path mPath = new Path();
  private final Path mDisc = new Path();
  private final RectF mRect = new RectF();
  private final double[] mPoint = new double[3];
  private final double[] mNext = new double[3];
  private final float[] mXy = new float[2];
  private final float[] mNextXy = new float[2];
  private final float mDensity;
  private final int mTouchSlop;

  @ColorInt
  private final int mSea;
  @ColorInt
  private final int mGraticule;
  @ColorInt
  private final int mLand;
  @ColorInt
  private final int mSatellite;
  @ColorInt
  private final int mSatelliteOff;
  @ColorInt
  private final int mBeam;
  @ColorInt
  private final int mJam;
  @ColorInt
  private final int mCar;
  @ColorInt
  private final int mCarOutline;
  /** The green of the coast: the coast stays drawn over it. */
  @ColorInt
  private final int mLandFill;
  /** Translucent, as the outage: the graticule, the coast and the jam stay readable over them. */
  @ColorInt
  private final int mCoverage;
  @ColorInt
  private final int mOutage;

  /** The coverage of the disc, made again only when its size changes. */
  @Nullable
  private Bitmap mCoverageBitmap;
  @Nullable
  private int[] mCoveragePixels;

  @Nullable
  private Listener mListener;
  private boolean mFrames;
  private long mLastFrameNs;

  private float mDownX;
  private float mDownY;
  private float mLastX;
  private float mLastY;
  private boolean mMoved;
  /** The finger that turns the globe: the others do not move it. */
  private int mPointerId = MotionEvent.INVALID_POINTER_ID;
  @Nullable
  private VelocityTracker mTracker;

  public GlobeSceneView(@NonNull Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
    mDensity = context.getResources().getDisplayMetrics().density;
    mTouchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
    mSea = ContextCompat.getColor(context, R.color.nogps_globe_sea);
    mGraticule = ContextCompat.getColor(context, R.color.nogps_globe_graticule);
    mLand = ContextCompat.getColor(context, R.color.nogps_globe_land);
    mSatellite = ContextCompat.getColor(context, R.color.nogps_globe_satellite);
    mSatelliteOff = ContextCompat.getColor(context, R.color.nogps_globe_satellite_off);
    mBeam = ContextCompat.getColor(context, R.color.nogps_globe_beam);
    mJam = ContextCompat.getColor(context, R.color.nogps_globe_jam);
    mCar = ContextCompat.getColor(context, R.color.nogps_globe_car);
    mCarOutline = ContextCompat.getColor(context, R.color.nogps_globe_car_outline);
    mLandFill = ContextCompat.getColor(context, R.color.nogps_globe_land_fill);
    mCoverage = ContextCompat.getColor(context, R.color.nogps_globe_coverage);
    mOutage = ContextCompat.getColor(context, R.color.nogps_globe_outage);
    mStroke.setStyle(Paint.Style.STROKE);
    mStroke.setStrokeCap(Paint.Cap.ROUND);
    mStroke.setStrokeJoin(Paint.Join.ROUND);
    mScene.setAnimated(!areAnimationsRemoved());
  }

  public void setListener(@Nullable Listener listener)
  {
    mListener = listener;
    notifyChanged();
  }

  int satellitesOn()
  {
    return mScene.onCount();
  }

  /** "Remove animations" of the system: the globe stands until the finger moves it. */
  private boolean areAnimationsRemoved()
  {
    return Settings.Global.getFloat(getContext().getContentResolver(), Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
 == 0f;
  }

  private void notifyChanged()
  {
    if (mListener != null)
      mListener.onSatellitesChanged(mScene.onCount(), GlobeScene.SATELLITES);
  }

  // Frames.

  private void startFrames()
  {
    mScene.setAnimated(!areAnimationsRemoved());
    if (mFrames || !mScene.isAnimated() || !isAttachedToWindow() || getWindowVisibility() != VISIBLE)
      return;
    mFrames = true;
    mLastFrameNs = 0;
    Choreographer.getInstance().postFrameCallback(this);
  }

  private void stopFrames()
  {
    mFrames = false;
    Choreographer.getInstance().removeFrameCallback(this);
  }

  @Override
  protected void onAttachedToWindow()
  {
    super.onAttachedToWindow();
    startFrames();
  }

  @Override
  protected void onDetachedFromWindow()
  {
    stopFrames();
    super.onDetachedFromWindow();
  }

  @Override
  protected void onWindowVisibilityChanged(int visibility)
  {
    super.onWindowVisibilityChanged(visibility);
    if (visibility == VISIBLE)
      startFrames();
    else
      stopFrames();
  }

  @Override
  public void doFrame(long frameTimeNanos)
  {
    if (!mFrames)
      return;
    final double dtMs = mLastFrameNs == 0 ? 0 : Math.min((frameTimeNanos - mLastFrameNs) / 1e6, MAX_FRAME_MS);
    mLastFrameNs = frameTimeNanos;
    mScene.step(dtMs);
    invalidate();
    Choreographer.getInstance().postFrameCallback(this);
  }

  // Touch.

  @Override
  protected void onSizeChanged(int w, int h, int oldw, int oldh)
  {
    super.onSizeChanged(w, h, oldw, oldh);
    mScene.setSize(w / mDensity, h / mDensity);
  }

  @Override
  public boolean onTouchEvent(MotionEvent event)
  {
    switch (event.getActionMasked())
    {
    case MotionEvent.ACTION_DOWN:
      // The screen scrolls; here the finger turns the globe, in any direction.
      getParent().requestDisallowInterceptTouchEvent(true);
      mPointerId = event.getPointerId(0);
      mDownX = mLastX = event.getX();
      mDownY = mLastY = event.getY();
      mMoved = false;
      mTracker = VelocityTracker.obtain();
      mTracker.addMovement(event);
      return true;
    case MotionEvent.ACTION_MOVE:
    {
      if (mTracker == null)
        return false;
      mTracker.addMovement(event);
      // The place of the finger that started the drag, not of the first in the list: with a second finger down the
      // first one is not index 0 any more, and the globe would jump the distance between them.
      final int index = event.findPointerIndex(mPointerId);
      if (index < 0)
        return true;
      final float x = event.getX(index);
      final float y = event.getY(index);
      if (!mMoved && Math.hypot(x - mDownX, y - mDownY) > mTouchSlop)
      {
        mMoved = true;
        mScene.beginDrag();
      }
      if (mMoved)
      {
        mScene.drag((x - mLastX) / mDensity, (y - mLastY) / mDensity);
        mLastX = x;
        mLastY = y;
        invalidate();
      }
      return true;
    }
    case MotionEvent.ACTION_POINTER_UP:
      // The finger that turns the globe is up while another is still down: the gesture ends with it.
      if (mTracker == null || event.getPointerId(event.getActionIndex()) != mPointerId)
        return super.onTouchEvent(event);
      mTracker.addMovement(event);
      finishDrag();
      invalidate();
      return true;
    case MotionEvent.ACTION_UP:
    {
      if (mTracker == null)
        return false;
      mTracker.addMovement(event);
      final int index = event.findPointerIndex(mPointerId);
      if (mMoved || index < 0)
        finishDrag();
      else
      {
        tap(event.getX(index) / mDensity, event.getY(index) / mDensity);
        release();
      }
      invalidate();
      return true;
    }
    case MotionEvent.ACTION_CANCEL:
      if (mMoved)
        mScene.endDrag(0, 0);
      release();
      return true;
    default: return super.onTouchEvent(event);
    }
  }

  /** The finger that turns the globe is up: the flick carries on, if it was fast enough. */
  private void finishDrag()
  {
    if (mMoved && mTracker != null)
    {
      mTracker.computeCurrentVelocity(1000);
      mScene.endDrag(mTracker.getXVelocity(mPointerId) / mDensity, mTracker.getYVelocity(mPointerId) / mDensity);
    }
    release();
  }

  private void release()
  {
    if (mTracker != null)
      mTracker.recycle();
    mTracker = null;
    mMoved = false;
    mPointerId = MotionEvent.INVALID_POINTER_ID;
  }

  private void tap(float x, float y)
  {
    performClick();
    final int i = mScene.satelliteAt(x, y);
    if (i < 0)
      return;
    mScene.toggle(i);
    notifyChanged();
  }

  @Override
  public boolean performClick()
  {
    return super.performClick();
  }

  // Drawing.

  @Override
  protected void onDraw(@NonNull Canvas canvas)
  {
    final float radius = mScene.earthRadius();
    final float cx = mScene.centerX();
    final float cy = mScene.centerY();
    canvas.save();
    canvas.scale(mDensity, mDensity);

    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (mScene.satellite(i)[2] <= 0)
        drawSatellite(canvas, i, true);
    }

    mFill.setStyle(Paint.Style.FILL);
    mFill.setColor(mSea);
    canvas.drawCircle(cx, cy, radius, mFill);
    drawGround(canvas, cx, cy, radius);
    mStroke.setPathEffect(null);
    mStroke.setStrokeWidth(1);
    mStroke.setColor(mGraticule);
    canvas.drawCircle(cx, cy, radius, mStroke);

    drawGraticule(canvas);
    drawCoast(canvas);
    drawJam(canvas);
    drawBeams(canvas);
    drawCar(canvas);

    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (mScene.satellite(i)[2] > 0)
        drawSatellite(canvas, i, false);
    }
    canvas.restore();
  }

  /**
   * The land and, over it and the sea, the coverage: the ground of the front half that sees enough satellites for a
   * fix carries the coverage tint, the rest the outage tint. Each pixel of the bitmap is the front point of the unit
   * disc under it: satellite(i) is in the frame of the screen too, and only the land needs the frame of the Earth.
   */
  private void drawGround(@NonNull Canvas canvas, float cx, float cy, float radius)
  {
    final int side = (int) Math.ceil(2 * radius * COVERAGE_PIXELS_PER_DP);
    if (side <= 0)
      return;
    if (mCoverageBitmap == null || mCoverageBitmap.getWidth() != side)
    {
      mCoverageBitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888);
      mCoveragePixels = new int[side * side];
    }
    final int[] pixels = mCoveragePixels;
    final double[][] satellites = mScene.onSatellites();
    // The rotation is orthonormal: its transpose takes the screen frame to the Earth frame.
    final double[] m = mScene.rotation();
    // A tint over the land fill, or over the sea drawn under the bitmap.
    final int coveredLand = over(mCoverage, mLandFill);
    final int outageLand = over(mOutage, mLandFill);
    for (int row = 0; row < side; row++)
    {
      // Row 0 is the top of the disc, y up.
      final double y = 1 - 2 * (row + 0.5) / side;
      for (int col = 0; col < side; col++)
      {
        final double x = 2 * (col + 0.5) / side - 1;
        final double r2 = x * x + y * y;
        if (r2 >= 1)
        {
          pixels[row * side + col] = 0;
          continue;
        }
        final double z = Math.sqrt(1 - r2);
        final boolean covered = GlobeScene.isCovered(x, y, z, satellites);
        final boolean land = GlobeScene.isLand(m[0] * x + m[3] * y + m[6] * z, m[1] * x + m[4] * y + m[7] * z,
                                               m[2] * x + m[5] * y + m[8] * z);
        pixels[row * side + col] = covered ? (land ? coveredLand : mCoverage) : (land ? outageLand : mOutage);
      }
    }
    mCoverageBitmap.setPixels(pixels, 0, side, 0, 0, side, side);
    mDisc.rewind();
    mDisc.addCircle(cx, cy, radius, Path.Direction.CW);
    mRect.set(cx - radius, cy - radius, cx + radius, cy + radius);
    canvas.save();
    canvas.clipPath(mDisc);
    canvas.drawBitmap(mCoverageBitmap, null, mRect, mBitmapPaint);
    canvas.restore();
  }

  private void drawGraticule(@NonNull Canvas canvas)
  {
    mStroke.setStrokeWidth(0.8f);
    // The far side first and faint, so the globe reads as a sphere.
    mStroke.setColor(withAlpha(mGraticule, BACK_GRATICULE_ALPHA));
    canvas.drawPath(linePath(GRATICULE, false), mStroke);
    mStroke.setColor(mGraticule);
    canvas.drawPath(linePath(GRATICULE, true), mStroke);
  }

  private void drawCoast(@NonNull Canvas canvas)
  {
    mStroke.setStrokeWidth(1.4f);
    mStroke.setColor(mLand);
    canvas.drawPath(linePath(COAST, true), mStroke);
  }

  /**
   * The segments of the lines on one side of the globe. A line is a row of unit vectors of the Earth frame; null
   * between two lines.
   */
  private Path linePath(@NonNull double[][] lines, boolean front)
  {
    mPath.rewind();
    boolean open = false;
    boolean previousFront = false;
    for (final double[] p : lines)
    {
      if (p == null)
      {
        open = false;
        continue;
      }
      mScene.rotate(p[0], p[1], p[2], mNext);
      final boolean nextFront = mScene.project(mNext, mNextXy);
      if (open && nextFront == previousFront && nextFront == front)
        mPath.lineTo(mNextXy[0], mNextXy[1]);
      else
        mPath.moveTo(mNextXy[0], mNextXy[1]);
      open = true;
      previousFront = nextFront;
    }
    return mPath;
  }

  private void drawJam(@NonNull Canvas canvas)
  {
    // A point on the far side is pushed to the rim of the disc: what shows is the part of the cap in front of it.
    mPath.rewind();
    boolean anyFront = false;
    for (int i = 0; i < JAM_RING.length; i++)
    {
      final double[] p = JAM_RING[i];
      mScene.rotate(p[0], p[1], p[2], mPoint);
      final boolean front = mScene.project(mPoint, mXy);
      anyFront |= front;
      if (!front)
      {
        final double length = Math.hypot(mPoint[0], mPoint[1]);
        final float r = mScene.earthRadius();
        if (length > 0)
        {
          mXy[0] = mScene.centerX() + (float) (r * mPoint[0] / length);
          mXy[1] = mScene.centerY() - (float) (r * mPoint[1] / length);
        }
      }
      if (i == 0)
        mPath.moveTo(mXy[0], mXy[1]);
      else
        mPath.lineTo(mXy[0], mXy[1]);
    }
    if (!anyFront)
      return;
    mPath.close();
    mFill.setColor(withAlpha(mJam, 0.28f));
    canvas.drawPath(mPath, mFill);

    mStroke.setStrokeWidth(1.6f);
    mStroke.setColor(mJam);
    mStroke.setPathEffect(mDash);
    canvas.drawPath(linePath(JAM_RING, true), mStroke);
    mStroke.setPathEffect(null);
  }

  private void drawBeams(@NonNull Canvas canvas)
  {
    final double[] car = mScene.car();
    if (!mScene.project(car, mNextXy))
      return;
    final float carX = mNextXy[0];
    final float carY = mNextXy[1];
    mStroke.setStrokeWidth(1);
    mStroke.setColor(withAlpha(mBeam, 0.8f));
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      final int beam = mScene.beam(i);
      if (beam == GlobeScene.BEAM_NONE)
        continue;
      mScene.project(mScene.satellite(i), mXy);
      final float dx = carX - mXy[0];
      final float dy = carY - mXy[1];
      final float length = (float) Math.hypot(dx, dy);
      if (beam == GlobeScene.BEAM_REACHES || length <= GlobeScene.BEAM_GAP_DP)
      {
        canvas.drawLine(mXy[0], mXy[1], carX, carY, mStroke);
        continue;
      }
      // Stops short of the car and ends in a broken stub: the signal is there and does not arrive.
      final float ux = dx / length;
      final float uy = dy / length;
      final float endX = carX - ux * GlobeScene.BEAM_GAP_DP;
      final float endY = carY - uy * GlobeScene.BEAM_GAP_DP;
      canvas.drawLine(mXy[0], mXy[1], endX, endY, mStroke);
      canvas.drawLine(endX - uy * BREAK_DP - ux * BREAK_DP, endY + ux * BREAK_DP - uy * BREAK_DP,
                      endX + uy * BREAK_DP + ux * BREAK_DP, endY - ux * BREAK_DP + uy * BREAK_DP, mStroke);
    }
  }

  private void drawCar(@NonNull Canvas canvas)
  {
    if (!mScene.project(mScene.car(), mXy))
      return;
    final float x = mXy[0];
    final float y = mXy[1];
    mPath.rewind();
    mRect.set(x - 7, y - 3.5f, x + 7, y + 3.5f);
    mPath.addRoundRect(mRect, 2.5f, 2.5f, Path.Direction.CW);
    mRect.set(x - 3.5f, y - 6, x + 3.5f, y - 2);
    mPath.addRoundRect(mRect, 2, 2, Path.Direction.CW);
    // The outline first and twice as wide, so the fill covers its inner half and the seam of the two shapes.
    mStroke.setStrokeWidth(2);
    mStroke.setColor(mCarOutline);
    canvas.drawPath(mPath, mStroke);
    mFill.setStyle(Paint.Style.FILL);
    mFill.setColor(mCar);
    canvas.drawPath(mPath, mFill);
    mFill.setColor(mSea);
    canvas.drawCircle(x - 4, y + 3.5f, 1.8f, mFill);
    canvas.drawCircle(x + 4, y + 3.5f, 1.8f, mFill);
  }

  private void drawSatellite(@NonNull Canvas canvas, int i, boolean behind)
  {
    final double[] p = mScene.satellite(i);
    mScene.project(p, mXy);
    final float x = mXy[0];
    final float y = mXy[1];
    final boolean on = mScene.isOn(i);
    final int color = on ? mSatellite : mSatelliteOff;
    final int drawn = behind ? withAlpha(color, DIM_ALPHA) : color;
    if (on)
    {
      mStroke.setStrokeWidth(2.4f);
      mStroke.setStrokeCap(Paint.Cap.BUTT);
      mStroke.setColor(drawn);
      canvas.drawLine(x - SATELLITE_RADIUS_DP - PANEL_LENGTH_DP, y, x - SATELLITE_RADIUS_DP, y, mStroke);
      canvas.drawLine(x + SATELLITE_RADIUS_DP, y, x + SATELLITE_RADIUS_DP + PANEL_LENGTH_DP, y, mStroke);
      mStroke.setStrokeCap(Paint.Cap.ROUND);
      mFill.setStyle(Paint.Style.FILL);
      mFill.setColor(drawn);
      canvas.drawCircle(x, y, SATELLITE_RADIUS_DP, mFill);
    }
    else
    {
      // Off: hollow and grey.
      mStroke.setStrokeWidth(1.4f);
      mStroke.setColor(drawn);
      canvas.drawCircle(x, y, SATELLITE_RADIUS_DP, mStroke);
    }
  }

  /** The colour of top drawn over bottom, both not premultiplied, as setPixels takes them. */
  @ColorInt
  private static int over(@ColorInt int top, @ColorInt int bottom)
  {
    final float ta = (top >>> 24) / 255f;
    final float ba = (bottom >>> 24) / 255f * (1 - ta);
    final float a = ta + ba;
    if (a == 0)
      return 0;
    int color = Math.round(a * 255) << 24;
    for (int shift = 0; shift < 24; shift += 8)
    {
      final float c = (((top >> shift) & 0xFF) * ta + ((bottom >> shift) & 0xFF) * ba) / a;
      color |= Math.round(c) << shift;
    }
    return color;
  }

  @ColorInt
  private static int withAlpha(@ColorInt int color, float alpha)
  {
    return (color & 0x00FFFFFF) | (Math.round(alpha * (color >>> 24)) << 24);
  }

  // The unit vectors of the Earth frame.

  private static double[] earthPoint(double latDeg, double lonDeg)
  {
    final double lat = Math.toRadians(latDeg);
    final double lon = Math.toRadians(lonDeg);
    return new double[] {Math.cos(lat) * Math.sin(lon), Math.sin(lat), Math.cos(lat) * Math.cos(lon)};
  }

  private static double[][] buildGraticule()
  {
    final java.util.List<double[]> points = new java.util.ArrayList<>();
    for (int lon = 0; lon < 360; lon += GRATICULE_STEP_DEG)
    {
      for (int lat = -90; lat <= 90; lat += SAMPLE_STEP_DEG)
        points.add(earthPoint(lat, lon));
      points.add(null);
    }
    for (int lat = -90 + GRATICULE_STEP_DEG; lat < 90; lat += GRATICULE_STEP_DEG)
    {
      for (int lon = 0; lon <= 360; lon += SAMPLE_STEP_DEG)
        points.add(earthPoint(lat, lon));
      points.add(null);
    }
    return points.toArray(new double[0][]);
  }

  private static double[][] buildCoast()
  {
    final java.util.List<double[]> points = new java.util.ArrayList<>();
    final short[] flat = GlobeCoastline.POINTS;
    for (int i = 0; i + 1 < flat.length; i += 2)
    {
      if (flat[i] == GlobeCoastline.SEPARATOR)
        points.add(null);
      else
        points.add(earthPoint((double) flat[i] / GlobeCoastline.SCALE, (double) flat[i + 1] / GlobeCoastline.SCALE));
    }
    return points.toArray(new double[0][]);
  }

  /** The circle of JAM_RADIUS_DEG about the jam centre, closed. */
  private static double[][] buildJamRing()
  {
    final double lat = Math.toRadians(GlobeScene.JAM_LAT_DEG);
    final double lon = Math.toRadians(GlobeScene.JAM_LON_DEG);
    final double r = Math.toRadians(GlobeScene.JAM_RADIUS_DEG);
    final double[] centre = earthPoint(GlobeScene.JAM_LAT_DEG, GlobeScene.JAM_LON_DEG);
    // East and north at the centre.
    final double[] east = {Math.cos(lon), 0, -Math.sin(lon)};
    final double[] north = {-Math.sin(lat) * Math.sin(lon), Math.cos(lat), -Math.sin(lat) * Math.cos(lon)};
    final double[][] ring = new double[JAM_RING_POINTS + 1][];
    for (int i = 0; i <= JAM_RING_POINTS; i++)
    {
      final double bearing = 2 * Math.PI * i / JAM_RING_POINTS;
      final double[] p = new double[3];
      for (int k = 0; k < 3; k++)
        p[k] = Math.cos(r) * centre[k] + Math.sin(r) * (Math.sin(bearing) * east[k] + Math.cos(bearing) * north[k]);
      ring[i] = p;
    }
    return ring;
  }
}
