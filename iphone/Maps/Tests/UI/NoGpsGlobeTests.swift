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

  func testPolesProjectToTopAndBottomOfTheDisc() {
    let r = scene.earthRadius
    XCTAssertEqual(r, Scene.earthRadiusFraction * Scene.sceneHeightPt, accuracy: 1e-4)
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

    scene.setRotation(matrix_identity_double3x3)
    scene.drag(dx: 10, dy: -10)
    let p = scene.project(scene.fromEarth(latDeg: 0, lonDeg: 0)).point
    XCTAssertEqual(p.x, width / 2 + 9.9, accuracy: 0.3)
    XCTAssertEqual(p.y, Scene.sceneHeightPt / 2 - 9.9, accuracy: 0.3)
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
    for i in 0 ..< Scene.satellites {
      if simd_dot(scene.satellite(i), car) > 1 {
        XCTAssertEqual(scene.beam(i), .broken)
        beams += 1
      } else {
        XCTAssertEqual(scene.beam(i), .none)
        none += 1
      }
    }
    XCTAssertGreaterThan(beams, 0)
    XCTAssertGreaterThan(none, 0)
    // A switched-off satellite above the horizon has no beam.
    let above = try XCTUnwrap((0 ..< Scene.satellites).first { simd_dot(scene.satellite($0), car) > 1 })
    scene.toggle(above)
    XCTAssertEqual(scene.beam(above), .none)
  }

  func testASatelliteBehindTheEarthHasNoBeam() {
    // The idle spin carries the car towards the limb: a satellite hidden by the disc must never get a beam over it.
    scene.faceJam()
    var hidden = 0
    for _ in 0 ..< 7500 {
      scene.step(dtMs: 16)
      guard scene.car.z > 0 else { continue }
      for i in 0 ..< Scene.satellites where scene.isHidden(scene.satellite(i)) {
        hidden += 1
        XCTAssertEqual(scene.beam(i), .none)
      }
    }
    XCTAssertGreaterThan(hidden, 0)
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
