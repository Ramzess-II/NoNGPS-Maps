@testable import Organic_Maps__Debug_
import simd
import XCTest

/// The same cases as GlobeSceneTest.java.
final class NoGpsGlobeTests: XCTestCase {
  private typealias Scene = GlobeScene
  private let width: CGFloat = 360
  private var scene = GlobeScene()

  override func setUp() {
    super.setUp()
    scene = GlobeScene()
    scene.setSize(CGSize(width: width, height: Scene.sceneHeightPt))
    scene.setRotation(matrix_identity_double3x3)
  }

  func testConstellationIsSixPlanesOfFour() {
    XCTAssertEqual(Scene.satellites, 24)
    XCTAssertEqual(Scene.planes * Scene.satsPerPlane, Scene.satellites)
    for i in 0 ..< Scene.satellites {
      XCTAssertEqual(simd_length(scene.satellite(i)), Scene.orbitRadiusFactor, accuracy: 1e-6)
      // 55 degrees inclined to the equator.
      XCTAssertLessThanOrEqual(abs(scene.satellite(i).y), Scene.orbitRadiusFactor * sin(55 * Double.pi / 180) + 1e-9)
    }
    // Satellites of a plane are 90 degrees apart.
    XCTAssertEqual(simd_dot(scene.satellite(0), scene.satellite(1)), 0, accuracy: 1e-9)
  }

  func testOrbitsAreToScaleAndInsideTheScene() {
    XCTAssertEqual(Scene.orbitRadiusFactor, 4.16)
    for turn in [(0.0, 0.0), (40.0, -25.0), (-130.0, 70.0)] {
      scene.setRotation(matrix_identity_double3x3)
      scene.drag(dx: CGFloat(turn.0), dy: CGFloat(turn.1))
      for _ in 0 ..< 60 {
        scene.step(dtMs: Scene.orbitPeriodMs / 60)
        for i in 0 ..< Scene.satellites {
          let p = scene.project(scene.satellite(i)).point
          XCTAssertGreaterThanOrEqual(p.x, Scene.satMarginPt - 1e-6)
          XCTAssertLessThanOrEqual(p.x, width - Scene.satMarginPt + 1e-6)
          XCTAssertGreaterThanOrEqual(p.y, Scene.satMarginPt - 1e-6)
          XCTAssertLessThanOrEqual(p.y, Scene.sceneHeightPt - Scene.satMarginPt + 1e-6)
        }
      }
    }
  }

  func testEarthRadiusFollowsTheSceneSize() {
    XCTAssertEqual(scene.earthRadius, (Scene.sceneHeightPt / 2 - Scene.satMarginPt) / 4.16, accuracy: 1e-4)
    scene.setSize(CGSize(width: 300, height: 500))
    XCTAssertEqual(scene.earthRadius, (150 - Scene.satMarginPt) / 4.16, accuracy: 1e-4)
    XCTAssertEqual(scene.center, CGPoint(x: 150, y: 250))
  }

  func testElevationMask() {
    let p = SIMD3<Double>(0, 0, 1)
    let east = SIMD3<Double>(1, 0, 0)
    // A satellite at the orbit seen from p at an elevation of e degrees, towards the east.
    func at(_ e: Double) -> SIMD3<Double> {
      let el = e * .pi / 180
      let dir = cos(el) * east + sin(el) * p
      // |p + t dir| = orbit: t^2 + 2 t sin(el) + 1 - orbit^2 = 0.
      let t = -sin(el) + (sin(el) * sin(el) + Scene.orbitRadiusFactor * Scene.orbitRadiusFactor - 1).squareRoot()
      return p + t * dir
    }
    XCTAssertTrue(Scene.isAboveMask(Scene.orbitRadiusFactor * p, from: p))
    XCTAssertFalse(Scene.isAboveMask(at(9), from: p))
    XCTAssertTrue(Scene.isAboveMask(at(11), from: p))
    XCTAssertFalse(Scene.isAboveMask(at(-5), from: p))
    XCTAssertFalse(Scene.isAboveMask(-Scene.orbitRadiusFactor * p, from: p))
  }

  /// Unit points over the whole sphere, about 10 degrees apart.
  private func sphereGrid() -> [SIMD3<Double>] {
    stride(from: -90.0, through: 90, by: 10).flatMap { lat in
      stride(from: 0.0, to: 360, by: 10).map { lon in Scene.earthVector(latDeg: lat, lonDeg: lon) }
    }
  }

  func testAllSatellitesOnCoverTheWholeEarth() {
    let grid = sphereGrid()
    for _ in 0 ..< 24 {
      scene.step(dtMs: Scene.orbitPeriodMs / 24 + 7)
      for p in grid {
        XCTAssertTrue(scene.isCovered(at: p), "\(p)")
        XCTAssertGreaterThanOrEqual(scene.visibleCount(at: p), Scene.fixSatellites)
      }
    }
  }

  func testSwitchedOffSatellitesCutAGap() {
    let p = Scene.earthVector(latDeg: 20, lonDeg: 50)
    var seen = (0 ..< Scene.satellites).filter { Scene.isAboveMask(scene.satellite($0), from: p) }
    XCTAssertGreaterThanOrEqual(seen.count, Scene.fixSatellites)
    while seen.count > Scene.fixSatellites {
      scene.toggle(seen.removeLast())
    }
    XCTAssertEqual(scene.visibleCount(at: p), Scene.fixSatellites)
    XCTAssertTrue(scene.isCovered(at: p))
    scene.toggle(seen.removeLast())
    XCTAssertEqual(scene.visibleCount(at: p), Scene.fixSatellites - 1)
    XCTAssertFalse(scene.isCovered(at: p))

    for i in 0 ..< Scene.satellites where scene.isOn(i) {
      scene.toggle(i)
    }
    XCTAssertTrue(sphereGrid().allSatisfy { !scene.isCovered(at: $0) })
  }

  func testPolesProjectToTopAndBottomOfTheDisc() {
    let r = scene.earthRadius
    let north = scene.project(SIMD3(0, 1, 0)).point
    XCTAssertEqual(north.x, width / 2, accuracy: 1e-4)
    XCTAssertEqual(north.y, Scene.sceneHeightPt / 2 - r, accuracy: 1e-4)
    XCTAssertEqual(scene.project(SIMD3(0, -1, 0)).point.y, Scene.sceneHeightPt / 2 + r, accuracy: 1e-4)
    XCTAssertTrue(scene.project(SIMD3(0, 0, 0.5)).isFront)
    XCTAssertFalse(scene.project(SIMD3(0, 0, -0.5)).isFront)
  }

  func testDragMovesThePointUnderTheFinger() {
    let before = scene.fromEarth(latDeg: 0, lonDeg: 0)
    // A drag of d points turns the globe by d / R radians: pi * R is half a turn.
    scene.beginDrag()
    scene.drag(dx: .pi * scene.earthRadius, dy: 0)
    let after = scene.fromEarth(latDeg: 0, lonDeg: 0)
    XCTAssertEqual(after.z, -before.z, accuracy: 1e-6)
    XCTAssertEqual(acos(simd_dot(before, after)) * 180 / .pi, 180, accuracy: 1e-4)

    // A short drag: the point follows the finger, R sin(d / R) along it.
    scene.setRotation(matrix_identity_double3x3)
    scene.drag(dx: 10, dy: -10)
    let p = scene.project(scene.fromEarth(latDeg: 0, lonDeg: 0)).point
    let r = Double(scene.earthRadius)
    let along = CGFloat(r * sin(200.0.squareRoot() / r) / 2.0.squareRoot())
    XCTAssertEqual(p.x, width / 2 + along, accuracy: 1e-3)
    XCTAssertEqual(p.y, Scene.sceneHeightPt / 2 - along, accuracy: 1e-3)
  }

  func testFlickSlowsDownThenIdleSpinTakesOver() {
    scene.beginDrag()
    scene.drag(dx: 30, dy: 5)
    scene.endDrag(vx: 1500, vy: 250)
    XCTAssertGreaterThan(scene.spinDegPerS, Scene.stopSpeedDegPerS)
    var steps = 0
    while scene.spinDegPerS > 0 {
      scene.step(dtMs: 16)
      steps += 1
      XCTAssertLessThan(steps, 2000, "the flick never stops")
    }
    // The idle spin: about the polar axis of the Earth, idleSpinDegPerS.
    let pole = scene.rotation * SIMD3<Double>(0, 1, 0)
    let equator = scene.fromEarth(latDeg: 0, lonDeg: 0)
    scene.step(dtMs: 1000)
    XCTAssertEqual(simd_length(scene.rotation * SIMD3<Double>(0, 1, 0) - pole), 0, accuracy: 1e-9)
    XCTAssertEqual(acos(simd_dot(equator, scene.fromEarth(latDeg: 0, lonDeg: 0))) * 180 / .pi,
                   Scene.idleSpinDegPerS, accuracy: 1e-6)
  }

  func testNothingTurnsWhileTheFingerIsDown() {
    scene.beginDrag()
    let before = scene.rotation
    scene.step(dtMs: 1000)
    XCTAssertEqual(scene.rotation, before)
  }

  func testReducedMotionHasNoIdleSpinNoFlickAndStandingSatellites() {
    scene.setAnimated(false)
    let satellite = scene.satellite(5)
    scene.beginDrag()
    scene.drag(dx: 20, dy: 0)
    scene.endDrag(vx: 3000, vy: 0)
    XCTAssertEqual(scene.spinDegPerS, 0)
    let turned = scene.rotation
    scene.step(dtMs: 1000)
    XCTAssertEqual(scene.rotation, turned)
    XCTAssertEqual(scene.satellite(5), satellite)
  }

  func testSlowReleaseDoesNotFlick() {
    scene.beginDrag()
    scene.endDrag(vx: 1, vy: 0)
    XCTAssertEqual(scene.spinDegPerS, 0)
  }

  func testTapPicksTheNearestFrontSatelliteInsideTheRadius() {
    func place(_ i: Int) -> CGPoint { scene.project(scene.satellite(i)).point }
    // The front satellite with the most room around it, so that the radius is what is tested.
    var best = (index: -1, room: CGFloat(0))
    for i in 0 ..< Scene.satellites where scene.satellite(i).z > 0 {
      let nearest = (0 ..< Scene.satellites).filter { $0 != i && scene.satellite($0).z > 0 }
        .map { hypot(place(i).x - place($0).x, place(i).y - place($0).y) }.min() ?? .greatestFiniteMagnitude
      if nearest > best.room {
        best = (i, nearest)
      }
    }
    XCTAssertGreaterThan(best.room, 2 * Scene.satTapRadiusPt)
    let p = place(best.index)
    XCTAssertEqual(scene.satelliteAt(p), best.index)
    XCTAssertEqual(scene.satelliteAt(CGPoint(x: p.x + Scene.satTapRadiusPt - 1, y: p.y)), best.index)
    XCTAssertEqual(scene.satelliteAt(CGPoint(x: p.x, y: p.y - Scene.satTapRadiusPt + 1)), best.index)
    XCTAssertNotEqual(scene.satelliteAt(CGPoint(x: p.x + Scene.satTapRadiusPt + 1, y: p.y)), best.index)
    XCTAssertNil(scene.satelliteAt(.zero))
  }

  func testTapNeverPicksASatelliteBehindTheGlobe() {
    for i in 0 ..< Scene.satellites where scene.satellite(i).z < 0 {
      let picked = scene.satelliteAt(scene.project(scene.satellite(i)).point)
      XCTAssertNotEqual(picked, i)
      if let picked {
        XCTAssertGreaterThan(scene.satellite(picked).z, 0)
      }
    }
  }

  func testSwitchedOffSatelliteCanBeSwitchedOnAndIsCounted() {
    XCTAssertEqual(scene.onCount, 24)
    scene.toggle(3)
    XCTAssertFalse(scene.isOn(3))
    XCTAssertEqual(scene.onCount, 23)
    scene.toggle(3)
    XCTAssertEqual(scene.onCount, 24)
  }

  func testBeamsFollowTheHorizonOfTheCarAndAreAlwaysBroken() throws {
    scene.faceJam()
    let car = scene.car
    XCTAssertEqual(car.z, 1, accuracy: 1e-9)
    XCTAssertTrue(scene.isCarJammed)
    var beams = 0
    var none = 0
    var lowOverHorizon = 0
    // Over an orbit period: some satellite passes between the horizon and the mask.
    for _ in 0 ..< 240 {
      scene.step(dtMs: 100)
      let car = scene.car
      for i in 0 ..< Scene.satellites {
        let s = scene.satellite(i)
        let d = s - car
        let elevationDeg = asin(simd_dot(d, car) / simd_length(d)) * 180 / .pi
        if elevationDeg >= Scene.elevationMaskDeg {
          XCTAssertEqual(scene.beam(i), .broken)
          beams += 1
        } else {
          XCTAssertEqual(scene.beam(i), .none)
          none += 1
          if elevationDeg > 0 {
            lowOverHorizon += 1
          }
        }
      }
    }
    XCTAssertGreaterThan(beams, 0)
    XCTAssertGreaterThan(none, 0)
    XCTAssertGreaterThan(lowOverHorizon, 0)
    // A switched-off satellite above the mask has no beam.
    let above = try XCTUnwrap((0 ..< Scene.satellites).first { scene.beam($0) != .none })
    scene.toggle(above)
    XCTAssertEqual(scene.beam(above), .none)
  }

  func testABeamNeverCrossesTheEarth() {
    // The idle spin carries the car towards the limb: the line to a satellite must never pass through the Earth.
    scene.faceJam()
    var beams = 0
    for _ in 0 ..< 7500 {
      scene.step(dtMs: 16)
      let car = scene.car
      for i in 0 ..< Scene.satellites where scene.beam(i) != .none {
        beams += 1
        let d = scene.satellite(i) - car
        // The point of the segment nearest to the centre of the Earth.
        let t = min(1, max(0, -simd_dot(car, d) / simd_length_squared(d)))
        XCTAssertGreaterThanOrEqual(simd_length(car + t * d), 1 - 1e-9)
      }
    }
    XCTAssertGreaterThan(beams, 0)
  }

  func testCarStaysInTheJammedAreaWhateverTheRotation() {
    scene.beginDrag()
    scene.drag(dx: 77, dy: -31)
    XCTAssertTrue(scene.isCarJammed)
    XCTAssertEqual(scene.car, scene.fromEarth(latDeg: Scene.jamLatDeg, lonDeg: Scene.jamLonDeg))
  }

  func testAnOrbitPeriodBringsTheSatellitesBack() {
    let start = (0 ..< Scene.satellites).map { scene.satellite($0) }
    for _ in 0 ..< Int(Scene.orbitPeriodMs / 16) {
      scene.step(dtMs: 16)
    }
    for i in 0 ..< Scene.satellites {
      let now = scene.satellite(i)
      let cosAngle = simd_dot(start[i], now) / (simd_length(start[i]) * simd_length(now))
      XCTAssertLessThan(acos(min(1, cosAngle)) * 180 / .pi, 1e-3)
    }
  }

  func testCoastlineStaysInItsCapAndRange() {
    let points = GlobeCoastline.points
    XCTAssertEqual(points.count % 2, 0)
    var count = 0
    for i in stride(from: 0, to: points.count, by: 2) {
      if points[i] == GlobeCoastline.separator {
        XCTAssertEqual(points[i + 1], GlobeCoastline.separator)
        continue
      }
      count += 1
      XCTAssertLessThanOrEqual(abs(Int(points[i])), 90 * GlobeCoastline.scale)
      XCTAssertLessThanOrEqual(abs(Int(points[i + 1])), 180 * GlobeCoastline.scale)
    }
    XCTAssertGreaterThan(count, 100)
    XCTAssertLessThanOrEqual(count, GlobeCoastline.maxPoints)
  }
}
