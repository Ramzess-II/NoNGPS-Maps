package app.organicmaps.nogps;

/**
 * The model of the globe of About NonGPS Maps: the Earth, 24 GPS satellites around it and the jammed area with the
 * car. No view in it, so it is tested on the JVM. GlobeScene.swift does the same with the same names and constants.
 *
 * <p>Points of the scene are in the frame of the screen: x to the right, y up, z to the viewer, the unit is the Earth
 * radius. The Earth turns in it by {@link #rotation()}, which maps the frame of the Earth (y is the polar axis, lon 0
 * is +z) to the frame of the screen. The satellites orbit in the orbit frame, whose y is the polar axis too: a drag or
 * a flick turns the view, so both frames turn together, and the idle spin turns the Earth alone under the orbits.
 * Distances on the screen are in dp.
 */
final class GlobeScene
{
  static final float SCENE_HEIGHT_DP = 400;
  /** The real orbit, 26 560 km over an Earth of 6 371 km: the coverage on the ground depends on it. */
  static final double ORBIT_RADIUS_FACTOR = 4.16;
  /** The orbit stays this far inside the scene, so the dot of a satellite is never cut. */
  static final float SAT_MARGIN_DP = 6;
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
  /** A receiver needs this many satellites for a fix. */
  static final int FIX_SATELLITES = 4;
  /** A satellite lower over the horizon than this does not count, as in a receiver. */
  static final double ELEVATION_MASK_DEG = 10;
  private static final double SIN_ELEVATION_MASK = Math.sin(Math.toRadians(ELEVATION_MASK_DEG));

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
  /** Row-major 3x3, the orbit frame to the screen frame: mRotation is it times the turn of the Earth about its pole. */
  private double[] mOrbitFrame = identity();
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
    mEarthRadius = (float) ((Math.min(widthDp, heightDp) / 2 - SAT_MARGIN_DP) / ORBIT_RADIUS_FACTOR);
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
    mOrbitFrame = matrix.clone();
  }

  /** The Earth turned so that the jammed area is in the middle of the scene. */
  void faceJam()
  {
    setRotation(multiply(rotationX(Math.toRadians(JAM_LAT_DEG)), rotationY(-Math.toRadians(JAM_LON_DEG))));
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
    turnView(axisAngle(axis, length / mEarthRadius));
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

  /** The Earth and the orbits turn together. */
  private void turnView(double[] turn)
  {
    mRotation = multiply(turn, mRotation);
    mOrbitFrame = multiply(turn, mOrbitFrame);
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
      turnView(axisAngle(mSpinAxis, mSpinRadPerMs * dtMs));
      mSpinRadPerMs *= Math.pow(SPIN_DAMPING, dtMs);
      if (spinDegPerS() < STOP_SPEED_DEG_PER_S)
        mSpinRadPerMs = 0;
    }
    else
    {
      // The Earth alone, about its pole: the orbits stay.
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
    final double r = ORBIT_RADIUS_FACTOR;
    final double[] o = mOrbitFrame;
    final double ox = r * (x * Math.cos(raan) + z * Math.sin(raan));
    final double oy = r * y;
    final double oz = r * (-x * Math.sin(raan) + z * Math.cos(raan));
    return new double[] {o[0] * ox + o[1] * oy + o[2] * oz, o[3] * ox + o[4] * oy + o[5] * oz,
                         o[6] * ox + o[7] * oy + o[8] * oz};
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

  // Land.

  /** The cells of GlobeCoastline.LAND_RUNS, row by row from the north, each row from lon -180. */
  private static final boolean[] LAND_CELLS = decodeLand();

  private static boolean[] decodeLand()
  {
    final int step = GlobeCoastline.LAND_STEP_DEG;
    final boolean[] cells = new boolean[(180 / step) * (360 / step)];
    final short[] runs = GlobeCoastline.LAND_RUNS;
    int cell = 0;
    for (int i = 0; i < runs.length; i += runs[i] + 1)
    {
      boolean land = false;
      for (int k = 1; k <= runs[i]; k++)
      {
        for (int n = 0; n < runs[i + k]; n++)
          cells[cell++] = land;
        land = !land;
      }
    }
    return cells;
  }

  /** Whether the unit point (x, y, z) of the frame of the Earth is on land. */
  static boolean isLand(double x, double y, double z)
  {
    final double step = GlobeCoastline.LAND_STEP_DEG;
    final int rows = (int) (180 / step);
    final int cols = (int) (360 / step);
    final double lat = Math.toDegrees(Math.asin(Math.max(-1, Math.min(1, y))));
    final double lon = Math.toDegrees(Math.atan2(x, z));
    final int row = Math.min((int) ((90 - lat) / step), rows - 1);
    final int col = Math.min((int) ((lon + 180) / step), cols - 1);
    return LAND_CELLS[row * cols + col];
  }

  // Coverage.

  /**
   * Whether the satellite at s stands at least ELEVATION_MASK_DEG above the horizon of the unit point p of the Earth:
   * the line to it rises from the plane tangent at p by at least the mask.
   */
  static boolean isAboveMask(double[] s, double px, double py, double pz)
  {
    final double dx = s[0] - px;
    final double dy = s[1] - py;
    final double dz = s[2] - pz;
    return dx * px + dy * py + dz * pz >= Math.sqrt(dx * dx + dy * dy + dz * dz) * SIN_ELEVATION_MASK;
  }

  static boolean isAboveMask(double[] s, double[] p)
  {
    return isAboveMask(s, p[0], p[1], p[2]);
  }

  /** Where the satellites that are on are now. */
  double[][] onSatellites()
  {
    final double[][] out = new double[onCount()][];
    int k = 0;
    for (int i = 0; i < SATELLITES; i++)
    {
      if (mOn[i])
        out[k++] = satellite(i);
    }
    return out;
  }

  /** How many of the satellites stand above the mask of the unit point p, counted up to limit. */
  static int visibleCount(double px, double py, double pz, double[][] satellites, int limit)
  {
    int count = 0;
    for (final double[] s : satellites)
    {
      if (isAboveMask(s, px, py, pz) && ++count >= limit)
        break;
    }
    return count;
  }

  /** A receiver at p has a fix: the view takes the satellites once per frame and asks for every point of the disc. */
  static boolean isCovered(double px, double py, double pz, double[][] satellites)
  {
    return visibleCount(px, py, pz, satellites, FIX_SATELLITES) >= FIX_SATELLITES;
  }

  /** The satellites that are on and above the mask of the unit point p, in the frame of the screen. */
  int visibleCount(double[] p)
  {
    return visibleCount(p[0], p[1], p[2], onSatellites(), Integer.MAX_VALUE);
  }

  boolean isCovered(double[] p)
  {
    return isCovered(p[0], p[1], p[2], onSatellites());
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

  /**
   * The line from satellite i to the car: only for a satellite the car would count, on and above the elevation mask
   * of the car, and broken when jammed. Above the mask is above the horizon, so a beam never crosses the disc.
   */
  int beam(int i)
  {
    if (!mOn[i] || !isAboveMask(satellite(i), car()))
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
