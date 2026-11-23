package app.organicmaps.nogps;

/**
 * The model of the globe of About NonGPS Maps: the Earth, 24 GPS satellites around it and the jammed area with the
 * car. No view in it, so it is tested on the JVM. GlobeScene.swift does the same with the same names and constants.
 *
 * <p>Points of the scene are in the frame of the screen: x to the right, y up, z to the viewer, the unit is the Earth
 * radius. The Earth turns in it by {@link #rotation()}, which maps the frame of the Earth (y is the polar axis, lon 0
 * is +z) to the frame of the screen. The satellites orbit in the frame of the screen: the Earth turns under them.
 * Distances on the screen are in dp.
 */
final class GlobeScene
{
  static final float SCENE_HEIGHT_DP = 260;
  static final float EARTH_RADIUS_FRACTION = 0.26f;
  /** The real orbit is 4.16 Earth radii: the satellites would be off the screen. */
  static final double ORBIT_RADIUS_FACTOR = 2.1;
  static final int PLANES = 6;
  static final int SATS_PER_PLANE = 4;
  static final double INCLINATION_DEG = 55;
  static final double RAAN_STEP_DEG = 60;
  static final double ANOMALY_STEP_DEG = 90;
  static final double PLANE_ANOMALY_OFFSET_DEG = 22.5;
  /** The real period is 11 h 58 min. */
  static final double ORBIT_PERIOD_MS = 24000;
  static final double IDLE_SPIN_DEG_PER_S = 6;
  /** Per ms, as MapPanelDragger.DECELERATION. */
  static final double SPIN_DAMPING = 0.998;
  static final double STOP_SPEED_DEG_PER_S = 3;
  static final float SAT_TAP_RADIUS_DP = 22;
  static final double JAM_LAT_DEG = 49;
  static final double JAM_LON_DEG = 32;
  static final double JAM_RADIUS_DEG = 18;
  /** A beam inside the jammed area stops this far from the car. */
  static final float BEAM_GAP_DP = 26;

  static final int SATELLITES = PLANES * SATS_PER_PLANE;

  static final int BEAM_NONE = 0;
  static final int BEAM_REACHES = 1;
  /** The signal is there and does not arrive. */
  static final int BEAM_BROKEN = 2;

  private float mCenterX;
  private float mCenterY;
  private float mEarthRadius = 1;

  /** Row-major 3x3, the Earth frame to the screen frame. */
  private double[] mRotation = identity();
  private final double[] mAnomalyDeg = new double[SATELLITES];
  private final boolean[] mOn = new boolean[SATELLITES];
  private double mPhaseDeg;

  private boolean mDragging;
  private boolean mAnimated = true;
  /** The unit axis, in the screen frame, of the spin left by a flick. */
  private final double[] mSpinAxis = {0, 1, 0};
  private double mSpinRadPerMs;

  GlobeScene()
  {
    for (int plane = 0; plane < PLANES; plane++)
    {
      for (int slot = 0; slot < SATS_PER_PLANE; slot++)
      {
        final int i = plane * SATS_PER_PLANE + slot;
        mAnomalyDeg[i] = slot * ANOMALY_STEP_DEG + plane * PLANE_ANOMALY_OFFSET_DEG;
        mOn[i] = true;
      }
    }
    faceJam();
  }

  // Size and projection.

  void setSize(float widthDp, float heightDp)
  {
    mCenterX = widthDp / 2;
    mCenterY = heightDp / 2;
    mEarthRadius = EARTH_RADIUS_FRACTION * Math.min(widthDp, heightDp);
  }

  float earthRadius()
  {
    return mEarthRadius;
  }

  float centerX()
  {
    return mCenterX;
  }

  float centerY()
  {
    return mCenterY;
  }

  /**
   * Orthographic: writes the place on the screen of p to out[0], out[1].
   *
   * @return whether p is on the side of the viewer
   */
  boolean project(double[] p, float[] out)
  {
    out[0] = mCenterX + (float) (mEarthRadius * p[0]);
    out[1] = mCenterY - (float) (mEarthRadius * p[1]);
    return p[2] > 0;
  }

  // Rotation.

  double[] rotation()
  {
    return mRotation.clone();
  }

  void setRotation(double[] matrix)
  {
    mRotation = matrix.clone();
  }

  /** The Earth turned so that the jammed area is in the middle of the scene. */
  void faceJam()
  {
    mRotation = multiply(rotationX(Math.toRadians(JAM_LAT_DEG)), rotationY(-Math.toRadians(JAM_LON_DEG)));
  }

  /** A point of the Earth, in the frame of the screen. */
  double[] fromEarth(double latDeg, double lonDeg)
  {
    final double lat = Math.toRadians(latDeg);
    final double lon = Math.toRadians(lonDeg);
    return apply(mRotation, new double[] {Math.cos(lat) * Math.sin(lon), Math.sin(lat), Math.cos(lat) * Math.cos(lon)});
  }

  /** A point of the Earth frame, in the frame of the screen, written to out: no allocation per frame. */
  void rotate(double x, double y, double z, double[] out)
  {
    out[0] = mRotation[0] * x + mRotation[1] * y + mRotation[2] * z;
    out[1] = mRotation[3] * x + mRotation[4] * y + mRotation[5] * z;
    out[2] = mRotation[6] * x + mRotation[7] * y + mRotation[8] * z;
  }

  // Motion.

  /** Without it the globe does not turn on its own, a flick does not carry and the satellites stand. */
  void setAnimated(boolean animated)
  {
    mAnimated = animated;
    if (!animated)
      mSpinRadPerMs = 0;
  }

  boolean isAnimated()
  {
    return mAnimated;
  }

  void beginDrag()
  {
    mDragging = true;
    mSpinRadPerMs = 0;
  }

  /** The finger moved by (dx, dy) px, y down: the point under it follows. */
  void drag(float dx, float dy)
  {
    final double length = Math.hypot(dx, dy);
    if (length == 0)
      return;
    final double[] axis = {dy / length, dx / length, 0};
    mRotation = multiply(axisAngle(axis, length / mEarthRadius), mRotation);
  }

  /** The finger is up, moving at (vx, vy) px/s. */
  void endDrag(float vx, float vy)
  {
    mDragging = false;
    final double speed = Math.hypot(vx, vy);
    if (!mAnimated || speed == 0)
    {
      mSpinRadPerMs = 0;
      return;
    }
    mSpinAxis[0] = vy / speed;
    mSpinAxis[1] = vx / speed;
    mSpinAxis[2] = 0;
    mSpinRadPerMs = speed / mEarthRadius / 1000;
    if (spinDegPerS() < STOP_SPEED_DEG_PER_S)
      mSpinRadPerMs = 0;
  }

  double spinDegPerS()
  {
    return Math.toDegrees(mSpinRadPerMs) * 1000;
  }

  /** One frame: the satellites go on, the flick slows down, the idle spin takes over when it is spent. */
  void step(double dtMs)
  {
    if (!mAnimated)
      return;
    mPhaseDeg = (mPhaseDeg + 360 * dtMs / ORBIT_PERIOD_MS) % 360;
    if (mDragging)
      return;
    if (mSpinRadPerMs > 0)
    {
      mRotation = multiply(axisAngle(mSpinAxis, mSpinRadPerMs * dtMs), mRotation);
      mSpinRadPerMs *= Math.pow(SPIN_DAMPING, dtMs);
      if (spinDegPerS() < STOP_SPEED_DEG_PER_S)
        mSpinRadPerMs = 0;
    }
    else
    {
      mRotation = multiply(mRotation, rotationY(Math.toRadians(IDLE_SPIN_DEG_PER_S * dtMs / 1000)));
    }
  }

  // Satellites.

  /** The place of satellite i in the frame of the screen, in Earth radii. */
  double[] satellite(int i)
  {
    final double u = Math.toRadians(mAnomalyDeg[i] + mPhaseDeg);
    final double raan = Math.toRadians((i / SATS_PER_PLANE) * RAAN_STEP_DEG);
    final double inc = Math.toRadians(INCLINATION_DEG);
    // In the orbit plane, then inclined about the line of nodes (x), then turned about the pole.
    final double x = Math.cos(u);
    final double y = -Math.sin(u) * Math.sin(inc);
    final double z = Math.sin(u) * Math.cos(inc);
    return new double[] {ORBIT_RADIUS_FACTOR * (x * Math.cos(raan) + z * Math.sin(raan)), ORBIT_RADIUS_FACTOR * y,
                         ORBIT_RADIUS_FACTOR * (-x * Math.sin(raan) + z * Math.cos(raan))};
  }

  /** Behind the Earth: the disc hides it. */
  boolean isHidden(double[] p)
  {
    return p[2] < 0 && p[0] * p[0] + p[1] * p[1] < 1;
  }

  boolean isOn(int i)
  {
    return mOn[i];
  }

  void toggle(int i)
  {
    mOn[i] = !mOn[i];
  }

  int onCount()
  {
    int count = 0;
    for (final boolean on : mOn)
    {
      if (on)
        count++;
    }
    return count;
  }

  /** The nearest satellite on the side of the viewer within SAT_TAP_RADIUS_DP of the point, or -1. */
  int satelliteAt(float x, float y)
  {
    int best = -1;
    double bestDistance = SAT_TAP_RADIUS_DP;
    final float[] out = new float[2];
    for (int i = 0; i < SATELLITES; i++)
    {
      if (!project(satellite(i), out))
        continue;
      final double d = Math.hypot(out[0] - x, out[1] - y);
      if (d <= bestDistance)
      {
        best = i;
        bestDistance = d;
      }
    }
    return best;
  }

  // The car and the beams.

  /** The car, in the frame of the screen: it stands in the middle of the jammed area. */
  double[] car()
  {
    return fromEarth(JAM_LAT_DEG, JAM_LON_DEG);
  }

  /** Always true: the car never leaves the jammed area. The flag is here so the scene tells why a beam is broken. */
  boolean isCarJammed()
  {
    return angleDeg(JAM_LAT_DEG, JAM_LON_DEG, JAM_LAT_DEG, JAM_LON_DEG) <= JAM_RADIUS_DEG;
  }

  /** The line from satellite i to the car: none below the horizon of the car or when it is off, broken when jammed. */
  int beam(int i)
  {
    if (!mOn[i])
      return BEAM_NONE;
    final double[] s = satellite(i);
    final double[] c = car();
    if (s[0] * c[0] + s[1] * c[1] + s[2] * c[2] <= 0)
      return BEAM_NONE;
    return isCarJammed() ? BEAM_BROKEN : BEAM_REACHES;
  }

  private static double angleDeg(double lat1, double lon1, double lat2, double lon2)
  {
    final double a = Math.toRadians(lat1);
    final double b = Math.toRadians(lat2);
    final double cos = Math.sin(a) * Math.sin(b) + Math.cos(a) * Math.cos(b) * Math.cos(Math.toRadians(lon1 - lon2));
    return Math.toDegrees(Math.acos(Math.max(-1, Math.min(1, cos))));
  }

  // 3x3 matrices, row-major.

  static double[] identity()
  {
    return new double[] {1, 0, 0, 0, 1, 0, 0, 0, 1};
  }

  static double[] rotationX(double a)
  {
    final double c = Math.cos(a);
    final double s = Math.sin(a);
    return new double[] {1, 0, 0, 0, c, -s, 0, s, c};
  }

  static double[] rotationY(double a)
  {
    final double c = Math.cos(a);
    final double s = Math.sin(a);
    return new double[] {c, 0, s, 0, 1, 0, -s, 0, c};
  }

  /** Rodrigues: the rotation by a radians about the unit axis. */
  static double[] axisAngle(double[] u, double a)
  {
    final double c = Math.cos(a);
    final double s = Math.sin(a);
    final double t = 1 - c;
    return new double[] {t * u[0] * u[0] + c,        t * u[0] * u[1] - s * u[2], t * u[0] * u[2] + s * u[1],
                         t * u[0] * u[1] + s * u[2], t * u[1] * u[1] + c,        t * u[1] * u[2] - s * u[0],
                         t * u[0] * u[2] - s * u[1], t * u[1] * u[2] + s * u[0], t * u[2] * u[2] + c};
  }

  static double[] multiply(double[] a, double[] b)
  {
    final double[] r = new double[9];
    for (int row = 0; row < 3; row++)
    {
      for (int col = 0; col < 3; col++)
        r[row * 3 + col] = a[row * 3] * b[col] + a[row * 3 + 1] * b[3 + col] + a[row * 3 + 2] * b[6 + col];
    }
    return r;
  }

  static double[] apply(double[] m, double[] p)
  {
    return new double[] {m[0] * p[0] + m[1] * p[1] + m[2] * p[2], m[3] * p[0] + m[4] * p[1] + m[5] * p[2],
                         m[6] * p[0] + m[7] * p[1] + m[8] * p[2]};
  }
}
