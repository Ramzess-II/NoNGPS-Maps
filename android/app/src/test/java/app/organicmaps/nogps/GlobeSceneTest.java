package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Before;
import org.junit.Test;

public class GlobeSceneTest
{
  private static final float W = 360;
  private static final float H = GlobeScene.SCENE_HEIGHT_DP;

  private GlobeScene mScene;

  @Before
  public void setUp()
  {
    mScene = new GlobeScene();
    mScene.setSize(W, H);
    mScene.setRotation(GlobeScene.identity());
  }

  private static double length(double[] p)
  {
    return Math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
  }

  private static double dot(double[] a, double[] b)
  {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  }

  /** The satellite in front that is the nearest to the point, and its place on the screen. */
  private float[] projected(int i)
  {
    final float[] xy = new float[2];
    mScene.project(mScene.satellite(i), xy);
    return xy;
  }

  @Test
  public void constellationIsSixPlanesOfFour()
  {
    assertEquals(24, GlobeScene.SATELLITES);
    assertEquals(GlobeScene.PLANES * GlobeScene.SATS_PER_PLANE, GlobeScene.SATELLITES);
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
      assertEquals(GlobeScene.ORBIT_RADIUS_FACTOR, length(mScene.satellite(i)), 1e-6);
    // Satellites of a plane are 90 degrees apart, the planes 60 degrees about the pole.
    assertEquals(0, dot(mScene.satellite(0), mScene.satellite(1)), 1e-9);
    final double[] n0 = {0, Math.sin(Math.toRadians(55)), Math.cos(Math.toRadians(55))};
    // Every satellite is 55 degrees inclined to the equator: |y| <= sin(55) radii of orbit.
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
      assertTrue(Math.abs(mScene.satellite(i)[1]) <= GlobeScene.ORBIT_RADIUS_FACTOR * n0[1] + 1e-9);
  }

  @Test
  public void orbitsAreToScaleAndInsideTheScene()
  {
    assertEquals(4.16, GlobeScene.ORBIT_RADIUS_FACTOR, 0);
    final float m = GlobeScene.SAT_MARGIN_DP;
    final float[][] turns = {{0, 0}, {40, -25}, {-130, 70}};
    for (final float[] turn : turns)
    {
      mScene.setRotation(GlobeScene.identity());
      mScene.drag(turn[0], turn[1]);
      for (int f = 0; f < 60; f++)
      {
        mScene.step(GlobeScene.ORBIT_PERIOD_MS / 60);
        for (int i = 0; i < GlobeScene.SATELLITES; i++)
        {
          final float[] xy = projected(i);
          assertTrue(xy[0] >= m - 1e-3 && xy[0] <= W - m + 1e-3);
          assertTrue(xy[1] >= m - 1e-3 && xy[1] <= H - m + 1e-3);
        }
      }
    }
  }

  @Test
  public void earthRadiusFollowsTheSceneSize()
  {
    // The smaller side sets it.
    assertEquals((Math.min(W, H) / 2 - GlobeScene.SAT_MARGIN_DP) / 4.16, mScene.earthRadius(), 1e-4);
    mScene.setSize(300, 500);
    assertEquals((150 - GlobeScene.SAT_MARGIN_DP) / 4.16, mScene.earthRadius(), 1e-4);
    assertEquals(150, mScene.centerX(), 0);
    assertEquals(250, mScene.centerY(), 0);
  }

  /** A satellite at the orbit seen from (0, 0, 1) at an elevation of e degrees, towards the east. */
  private static double[] atElevation(double e)
  {
    final double el = Math.toRadians(e);
    final double orbit = GlobeScene.ORBIT_RADIUS_FACTOR;
    // |p + t dir| = orbit: t^2 + 2 t sin(el) + 1 - orbit^2 = 0.
    final double t = -Math.sin(el) + Math.sqrt(Math.sin(el) * Math.sin(el) + orbit * orbit - 1);
    return new double[] {t * Math.cos(el), 0, 1 + t * Math.sin(el)};
  }

  @Test
  public void elevationMask()
  {
    final double[] p = {0, 0, 1};
    final double orbit = GlobeScene.ORBIT_RADIUS_FACTOR;
    assertTrue(GlobeScene.isAboveMask(new double[] {0, 0, orbit}, p));
    assertFalse(GlobeScene.isAboveMask(atElevation(9), p));
    assertTrue(GlobeScene.isAboveMask(atElevation(11), p));
    assertFalse(GlobeScene.isAboveMask(atElevation(-5), p));
    assertFalse(GlobeScene.isAboveMask(new double[] {0, 0, -orbit}, p));
  }

  /** Unit points over the whole sphere, about 10 degrees apart. */
  private static double[][] sphereGrid()
  {
    final double[][] grid = new double[19 * 36][];
    int k = 0;
    for (int lat = -90; lat <= 90; lat += 10)
    {
      for (int lon = 0; lon < 360; lon += 10)
      {
        final double a = Math.toRadians(lat);
        final double b = Math.toRadians(lon);
        grid[k++] = new double[] {Math.cos(a) * Math.sin(b), Math.sin(a), Math.cos(a) * Math.cos(b)};
      }
    }
    return grid;
  }

  @Test
  public void allSatellitesOnCoverTheWholeEarth()
  {
    final double[][] grid = sphereGrid();
    for (int f = 0; f < 24; f++)
    {
      mScene.step(GlobeScene.ORBIT_PERIOD_MS / 24 + 7);
      for (final double[] p : grid)
      {
        assertTrue(mScene.isCovered(p));
        assertTrue(mScene.visibleCount(p) >= GlobeScene.FIX_SATELLITES);
      }
    }
  }

  @Test
  public void switchedOffSatellitesCutAGap()
  {
    final double[] p = sphereGrid()[11 * 36 + 5];
    final java.util.List<Integer> seen = new java.util.ArrayList<>();
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (GlobeScene.isAboveMask(mScene.satellite(i), p))
        seen.add(i);
    }
    assertTrue(seen.size() >= GlobeScene.FIX_SATELLITES);
    while (seen.size() > GlobeScene.FIX_SATELLITES)
      mScene.toggle(seen.remove(seen.size() - 1));
    assertEquals(GlobeScene.FIX_SATELLITES, mScene.visibleCount(p));
    assertTrue(mScene.isCovered(p));
    mScene.toggle(seen.remove(seen.size() - 1));
    assertEquals(GlobeScene.FIX_SATELLITES - 1, mScene.visibleCount(p));
    assertFalse(mScene.isCovered(p));

    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (mScene.isOn(i))
        mScene.toggle(i);
    }
    for (final double[] q : sphereGrid())
      assertFalse(mScene.isCovered(q));
  }

  @Test
  public void polesProjectToTopAndBottomOfTheDisc()
  {
    final float[] xy = new float[2];
    final float r = mScene.earthRadius();
    mScene.project(new double[] {0, 1, 0}, xy);
    assertEquals(W / 2, xy[0], 1e-4);
    assertEquals(H / 2 - r, xy[1], 1e-4);
    mScene.project(new double[] {0, -1, 0}, xy);
    assertEquals(H / 2 + r, xy[1], 1e-4);
    assertTrue(mScene.project(new double[] {0, 0, 0.5}, xy));
    assertFalse(mScene.project(new double[] {0, 0, -0.5}, xy));
  }

  @Test
  public void dragMovesThePointUnderTheFinger()
  {
    final double[] before = mScene.fromEarth(0, 0);
    final float r = mScene.earthRadius();
    // A drag of d points turns the globe by d / R radians: pi * R is half a turn.
    mScene.beginDrag();
    mScene.drag((float) (Math.PI * r), 0);
    final double[] after = mScene.fromEarth(0, 0);
    assertEquals(-before[2], after[2], 1e-6);
    assertEquals(180, Math.toDegrees(Math.acos(dot(before, after))), 1e-4);
    // A short drag: the point follows the finger, R sin(d / R) along it.
    mScene.setRotation(GlobeScene.identity());
    mScene.drag(10, -10);
    final float[] xy = new float[2];
    mScene.project(mScene.fromEarth(0, 0), xy);
    final double along = r * Math.sin(Math.sqrt(200) / r) / Math.sqrt(2);
    assertEquals(W / 2 + along, xy[0], 1e-3);
    assertEquals(H / 2 - along, xy[1], 1e-3);
  }

  @Test
  public void flickSlowsDownThenIdleSpinTakesOver()
  {
    mScene.beginDrag();
    mScene.drag(30, 5);
    mScene.endDrag(1500, 250);
    assertTrue(mScene.spinDegPerS() > GlobeScene.STOP_SPEED_DEG_PER_S);
    int steps = 0;
    while (mScene.spinDegPerS() > 0)
    {
      final double[] poleBefore = GlobeScene.apply(mScene.rotation(), new double[] {0, 1, 0});
      mScene.step(16);
      // The flick is about its own axis: the pole moves, which the idle spin about the pole would not do.
      final double[] poleNow = GlobeScene.apply(mScene.rotation(), new double[] {0, 1, 0});
      assertTrue(
          length(new double[] {poleBefore[0] - poleNow[0], poleBefore[1] - poleNow[1], poleBefore[2] - poleNow[2]})
          > 1e-6);
      assertTrue("the flick never stops", ++steps < 2000);
    }
    // The idle spin: about the polar axis of the Earth, kIdleSpinDegPerS.
    final double[] pole = GlobeScene.apply(mScene.rotation(), new double[] {0, 1, 0});
    final double[] equator = mScene.fromEarth(0, 0);
    mScene.step(1000);
    final double[] poleAfter = GlobeScene.apply(mScene.rotation(), new double[] {0, 1, 0});
    final double[] equatorAfter = mScene.fromEarth(0, 0);
    assertEquals(0, length(new double[] {pole[0] - poleAfter[0], pole[1] - poleAfter[1], pole[2] - poleAfter[2]}),
                 1e-9);
    assertEquals(GlobeScene.IDLE_SPIN_DEG_PER_S, Math.toDegrees(Math.acos(dot(equator, equatorAfter))), 1e-6);
  }

  @Test
  public void fingerDownStopsEverythingButTheOrbits()
  {
    mScene.beginDrag();
    final double[] before = mScene.rotation();
    mScene.step(1000);
    assertEquals(0, mScene.spinDegPerS(), 0);
    for (int i = 0; i < 9; i++)
      assertEquals(before[i], mScene.rotation()[i], 0);
  }

  @Test
  public void reducedMotionHasNoIdleSpinAndNoFlick()
  {
    mScene.setAnimated(false);
    mScene.beginDrag();
    mScene.drag(20, 0);
    mScene.endDrag(3000, 0);
    assertEquals(0, mScene.spinDegPerS(), 0);
    final double[] turned = mScene.rotation();
    final double[] satellite = mScene.satellite(5);
    mScene.step(1000);
    for (int i = 0; i < 9; i++)
      assertEquals(turned[i], mScene.rotation()[i], 0);
    for (int k = 0; k < 3; k++)
      assertEquals(satellite[k], mScene.satellite(5)[k], 0);
  }

  /** Satellite i in the frame of the Earth: the rotation is orthonormal, so its inverse is its transpose. */
  private double[] onEarth(int i)
  {
    final double[] m = mScene.rotation();
    final double[] t = {m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]};
    return GlobeScene.apply(t, mScene.satellite(i));
  }

  private static double distance(double[] a, double[] b)
  {
    return length(new double[] {a[0] - b[0], a[1] - b[1], a[2] - b[2]});
  }

  @Test
  public void aDragTurnsTheOrbitsWithTheEarth()
  {
    mScene.setAnimated(false);
    final double[][] before = new double[GlobeScene.SATELLITES][];
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
      before[i] = onEarth(i);
    mScene.beginDrag();
    mScene.drag(50, -35);
    mScene.endDrag(0, 0);
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
      assertEquals(0, distance(onEarth(i), before[i]), 1e-9);
  }

  /** The unit normal of the plane of satellites 0 and 1. */
  private double[] firstPlaneNormal()
  {
    final double[] a = mScene.satellite(0);
    final double[] b = mScene.satellite(1);
    final double[] n = {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
    final double l = length(n);
    return new double[] {n[0] / l, n[1] / l, n[2] / l};
  }

  @Test
  public void theIdleSpinTurnsTheEarthUnderTheOrbits()
  {
    final double[] planeBefore = firstPlaneNormal();
    final double[] earthBefore = onEarth(0);
    mScene.step(500);
    assertEquals(0, distance(firstPlaneNormal(), planeBefore), 1e-9);
    assertTrue(distance(onEarth(0), earthBefore) > 0.1);
  }

  @Test
  public void orbitsAreInclinedToTheEquatorWhateverTheView()
  {
    mScene.faceJam();
    mScene.drag(70, 40);
    for (int f = 0; f < 50; f++)
    {
      mScene.step(300);
      final double[] pole = GlobeScene.apply(mScene.rotation(), new double[] {0, 1, 0});
      for (int i = 0; i < GlobeScene.SATELLITES; i++)
      {
        final double[] s = mScene.satellite(i);
        final double latitude = Math.toDegrees(Math.asin(dot(s, pole) / length(s)));
        assertTrue(Math.abs(latitude) <= GlobeScene.INCLINATION_DEG + 1e-6);
      }
    }
  }

  @Test
  public void slowReleaseDoesNotFlick()
  {
    mScene.beginDrag();
    mScene.endDrag(1, 0);
    assertEquals(0, mScene.spinDegPerS(), 0);
  }

  @Test
  public void tapPicksTheNearestFrontSatelliteInsideTheRadius()
  {
    // The front satellite with the most room around it, so that the radius is what is tested.
    int front = -1;
    double room = 0;
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (mScene.satellite(i)[2] <= 0)
        continue;
      final float[] a = projected(i);
      double nearest = Double.MAX_VALUE;
      for (int j = 0; j < GlobeScene.SATELLITES; j++)
      {
        if (j == i || mScene.satellite(j)[2] <= 0)
          continue;
        final float[] b = projected(j);
        nearest = Math.min(nearest, Math.hypot(a[0] - b[0], a[1] - b[1]));
      }
      if (nearest > room)
      {
        room = nearest;
        front = i;
      }
    }
    assertTrue(room > 2 * GlobeScene.SAT_TAP_RADIUS_DP);
    final float[] xy = projected(front);
    assertEquals(front, mScene.satelliteAt(xy[0], xy[1]));
    assertEquals(front, mScene.satelliteAt(xy[0] + GlobeScene.SAT_TAP_RADIUS_DP - 1, xy[1]));
    assertEquals(front, mScene.satelliteAt(xy[0], xy[1] - GlobeScene.SAT_TAP_RADIUS_DP + 1));
    assertNotEquals(front, mScene.satelliteAt(xy[0] + GlobeScene.SAT_TAP_RADIUS_DP + 1, xy[1]));
    // Far from every satellite, in the corner of the scene.
    assertEquals(-1, mScene.satelliteAt(0, 0));
  }

  @Test
  public void tapNeverPicksASatelliteBehindTheGlobe()
  {
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (mScene.satellite(i)[2] >= 0)
        continue;
      final float[] xy = projected(i);
      final int picked = mScene.satelliteAt(xy[0], xy[1]);
      assertNotEquals(i, picked);
      if (picked >= 0)
        assertTrue(mScene.satellite(picked)[2] > 0);
    }
  }

  @Test
  public void switchedOffSatelliteCanBeSwitchedOnAndIsCounted()
  {
    assertEquals(24, mScene.onCount());
    mScene.toggle(3);
    assertFalse(mScene.isOn(3));
    assertEquals(23, mScene.onCount());
    mScene.toggle(3);
    assertEquals(24, mScene.onCount());
  }

  @Test
  public void beamsFollowTheHorizonOfTheCarAndAreAlwaysBroken()
  {
    mScene.faceJam();
    final double[] car = mScene.car();
    assertEquals(1, car[2], 1e-9);
    assertTrue(mScene.isCarJammed());
    int beams = 0;
    int none = 0;
    int lowOverHorizon = 0;
    // Over an orbit period: some satellite passes between the horizon and the mask.
    for (int f = 0; f < 240; f++)
    {
      mScene.step(100);
      final double[] c = mScene.car();
      for (int i = 0; i < GlobeScene.SATELLITES; i++)
      {
        final double[] s = mScene.satellite(i);
        final double[] d = {s[0] - c[0], s[1] - c[1], s[2] - c[2]};
        final double elevationDeg = Math.toDegrees(Math.asin(dot(d, c) / length(d)));
        final int beam = mScene.beam(i);
        if (elevationDeg >= GlobeScene.ELEVATION_MASK_DEG)
        {
          assertEquals(GlobeScene.BEAM_BROKEN, beam);
          beams++;
        }
        else
        {
          assertEquals(GlobeScene.BEAM_NONE, beam);
          none++;
          if (elevationDeg > 0)
            lowOverHorizon++;
        }
        assertNotEquals(GlobeScene.BEAM_REACHES, beam);
      }
    }
    assertTrue(beams > 0);
    assertTrue(none > 0);
    assertTrue(lowOverHorizon > 0);
    // A switched-off satellite above the mask has no beam.
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (mScene.beam(i) != GlobeScene.BEAM_NONE)
      {
        mScene.toggle(i);
        assertEquals(GlobeScene.BEAM_NONE, mScene.beam(i));
        return;
      }
    }
    fail("no beam");
  }

  @Test
  public void aBeamNeverCrossesTheEarth()
  {
    // The idle spin carries the car towards the limb: the line to a satellite must never pass through the Earth.
    mScene.faceJam();
    int beams = 0;
    for (int frame = 0; frame < 7500; frame++)
    {
      mScene.step(16);
      final double[] c = mScene.car();
      for (int i = 0; i < GlobeScene.SATELLITES; i++)
      {
        if (mScene.beam(i) == GlobeScene.BEAM_NONE)
          continue;
        beams++;
        final double[] s = mScene.satellite(i);
        final double[] d = {s[0] - c[0], s[1] - c[1], s[2] - c[2]};
        // The point of the segment nearest to the centre of the Earth.
        final double t = Math.min(1, Math.max(0, -dot(c, d) / dot(d, d)));
        assertTrue(length(new double[] {c[0] + t * d[0], c[1] + t * d[1], c[2] + t * d[2]}) >= 1 - 1e-9);
      }
    }
    assertTrue(beams > 0);
  }

  @Test
  public void carStaysInTheJammedAreaWhateverTheRotation()
  {
    mScene.beginDrag();
    mScene.drag(77, -31);
    assertTrue(mScene.isCarJammed());
    final double[] car = mScene.car();
    final double[] centre = mScene.fromEarth(GlobeScene.JAM_LAT_DEG, GlobeScene.JAM_LON_DEG);
    for (int k = 0; k < 3; k++)
      assertEquals(centre[k], car[k], 1e-12);
  }

  @Test
  public void anOrbitPeriodBringsTheSatellitesBack()
  {
    final double[][] start = new double[GlobeScene.SATELLITES][];
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
      start[i] = mScene.satellite(i);
    final int frames = (int) (GlobeScene.ORBIT_PERIOD_MS / 16);
    for (int f = 0; f < frames; f++)
      mScene.step(16);
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      final double[] now = mScene.satellite(i);
      final double cos = dot(start[i], now) / (length(start[i]) * length(now));
      assertTrue(Math.toDegrees(Math.acos(Math.min(1, cos))) < 1e-3);
    }
  }

  @Test
  public void landRowsCoverTheGlobe()
  {
    final short[] runs = GlobeCoastline.LAND_RUNS;
    int rows = 0;
    for (int i = 0; i < runs.length; i += runs[i] + 1)
    {
      int cells = 0;
      for (int k = 1; k <= runs[i]; k++)
        cells += runs[i + k];
      assertEquals(360 / GlobeCoastline.LAND_STEP_DEG, cells);
      rows++;
    }
    assertEquals(180 / GlobeCoastline.LAND_STEP_DEG, rows);
  }

  private static boolean land(double latDeg, double lonDeg)
  {
    final double lat = Math.toRadians(latDeg);
    final double lon = Math.toRadians(lonDeg);
    return GlobeScene.isLand(Math.cos(lat) * Math.sin(lon), Math.sin(lat), Math.cos(lat) * Math.cos(lon));
  }

  @Test
  public void landKnowsTheContinents()
  {
    assertTrue(land(GlobeScene.JAM_LAT_DEG, GlobeScene.JAM_LON_DEG));
    assertTrue(land(23, 10)); // Sahara
    assertTrue(land(-25, 134)); // Australia
    assertTrue(land(-89.9, 0));
    assertFalse(land(30, -40)); // Atlantic
    assertFalse(land(0, -150)); // Pacific
    assertFalse(land(89.9, 0));
    assertTrue(land(67, -179.5)); // Chukotka, on both sides of the antimeridian
    assertTrue(land(67, 179.5));
  }

  @Test
  public void coastlineStaysInItsCapAndRange()
  {
    final short[] points = GlobeCoastline.POINTS;
    assertEquals(0, points.length % 2);
    int count = 0;
    for (int i = 0; i < points.length; i += 2)
    {
      if (points[i] == GlobeCoastline.SEPARATOR)
      {
        assertEquals(GlobeCoastline.SEPARATOR, points[i + 1]);
        continue;
      }
      count++;
      assertTrue(Math.abs(points[i]) <= 90 * GlobeCoastline.SCALE);
      assertTrue(Math.abs(points[i + 1]) <= 180 * GlobeCoastline.SCALE);
    }
    assertTrue(count > 100);
    assertTrue(count <= GlobeCoastline.MAX_POINTS);
  }
}
