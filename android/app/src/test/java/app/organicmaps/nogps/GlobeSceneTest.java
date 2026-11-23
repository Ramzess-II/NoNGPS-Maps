package app.organicmaps.nogps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;

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
  public void polesProjectToTopAndBottomOfTheDisc()
  {
    final float[] xy = new float[2];
    final float r = mScene.earthRadius();
    assertEquals(GlobeScene.EARTH_RADIUS_FRACTION * H, r, 1e-4);
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
    // A short drag in a direction: the point follows the finger on the screen.
    mScene.setRotation(GlobeScene.identity());
    mScene.drag(10, -10);
    final float[] xy = new float[2];
    mScene.project(mScene.fromEarth(0, 0), xy);
    assertEquals(W / 2 + 10 * 0.99f, xy[0], 0.3);
    assertEquals(H / 2 - 10 * 0.99f, xy[1], 0.3);
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
    final double[] satellite = mScene.satellite(5);
    mScene.beginDrag();
    mScene.drag(20, 0);
    mScene.endDrag(3000, 0);
    assertEquals(0, mScene.spinDegPerS(), 0);
    final double[] turned = mScene.rotation();
    mScene.step(1000);
    for (int i = 0; i < 9; i++)
      assertEquals(turned[i], mScene.rotation()[i], 0);
    for (int k = 0; k < 3; k++)
      assertEquals(satellite[k], mScene.satellite(5)[k], 0);
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
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      final boolean above = dot(mScene.satellite(i), car) > 0;
      final int beam = mScene.beam(i);
      if (above)
      {
        assertEquals(GlobeScene.BEAM_BROKEN, beam);
        beams++;
      }
      else
      {
        assertEquals(GlobeScene.BEAM_NONE, beam);
        none++;
      }
      assertNotEquals(GlobeScene.BEAM_REACHES, beam);
    }
    assertTrue(beams > 0);
    assertTrue(none > 0);
    // A switched-off satellite above the horizon has no beam.
    for (int i = 0; i < GlobeScene.SATELLITES; i++)
    {
      if (dot(mScene.satellite(i), car) > 0)
      {
        mScene.toggle(i);
        assertEquals(GlobeScene.BEAM_NONE, mScene.beam(i));
        return;
      }
    }
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
