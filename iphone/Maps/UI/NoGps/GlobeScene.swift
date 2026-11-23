import CoreGraphics
import simd

/// The model of the globe of About NonGPS Maps: the Earth, 24 GPS satellites around it and the jammed area with the
/// car. No view in it, so it is tested without one. GlobeScene.java does the same with the same names and constants.
///
/// Points of the scene are in the frame of the screen: x to the right, y up, z to the viewer, the unit is the Earth
/// radius. The Earth turns in it by `rotation`, which maps the frame of the Earth (y is the polar axis, lon 0 is +z)
/// to the frame of the screen. The satellites orbit in the frame of the screen: the Earth turns under them.
/// Distances on the screen are in pt.
final class GlobeScene {
  static let sceneHeightPt: CGFloat = 260
  static let earthRadiusFraction: CGFloat = 0.26
  /// The real orbit is 4.16 Earth radii: the satellites would be off the screen.
  static let orbitRadiusFactor = 2.1
  static let planes = 6
  static let satsPerPlane = 4
  static let inclinationDeg = 55.0
  static let raanStepDeg = 60.0
  static let anomalyStepDeg = 90.0
  static let planeAnomalyOffsetDeg = 22.5
  /// The real period is 11 h 58 min.
  static let orbitPeriodMs = 24000.0
  static let idleSpinDegPerS = 6.0
  /// Per ms, as MapPanelDragger.Constants.deceleration.
  static let spinDamping = 0.998
  static let stopSpeedDegPerS = 3.0
  static let satTapRadiusPt: CGFloat = 22
  static let jamLatDeg = 49.0
  static let jamLonDeg = 32.0
  static let jamRadiusDeg = 18.0
  /// A beam inside the jammed area stops this far from the car.
  static let beamGapPt: CGFloat = 26

  static let satellites = planes * satsPerPlane

  enum Beam {
    case none
    case reaches
    /// The signal is there and does not arrive.
    case broken
  }

  private(set) var center = CGPoint.zero
  private(set) var earthRadius: CGFloat = 1

  /// The Earth frame to the screen frame.
  private(set) var rotation = matrix_identity_double3x3
  private var anomalyDeg = [Double](repeating: 0, count: satellites)
  private var on = [Bool](repeating: true, count: satellites)
  private var phaseDeg = 0.0

  private var isDragging = false
  /// Without it the globe does not turn on its own, a flick does not carry and the satellites stand.
  private(set) var isAnimated = true
  /// The unit axis, in the screen frame, of the spin left by a flick.
  private var spinAxis = SIMD3<Double>(0, 1, 0)
  private var spinRadPerMs = 0.0

  init() {
    for plane in 0 ..< Self.planes {
      for slot in 0 ..< Self.satsPerPlane {
        anomalyDeg[plane * Self.satsPerPlane + slot] = Double(slot) * Self.anomalyStepDeg
          + Double(plane) * Self.planeAnomalyOffsetDeg
      }
    }
    faceJam()
  }

  // MARK: - Size and projection

  func setSize(_ size: CGSize) {
    center = CGPoint(x: size.width / 2, y: size.height / 2)
    earthRadius = Self.earthRadiusFraction * min(size.width, size.height)
  }

  /// Orthographic: the place on the screen of p, and whether p is on the side of the viewer.
  func project(_ p: SIMD3<Double>) -> (point: CGPoint, isFront: Bool) {
    (CGPoint(x: center.x + earthRadius * CGFloat(p.x), y: center.y - earthRadius * CGFloat(p.y)), p.z > 0)
  }

  // MARK: - Rotation

  func setRotation(_ matrix: simd_double3x3) {
    rotation = matrix
  }

  /// The Earth turned so that the jammed area is in the middle of the scene.
  func faceJam() {
    rotation = Self.rotation(about: SIMD3(1, 0, 0), by: Self.jamLatDeg.radians)
      * Self.rotation(about: SIMD3(0, 1, 0), by: -Self.jamLonDeg.radians)
  }

  /// A point of the Earth, in the frame of the screen.
  func fromEarth(latDeg: Double, lonDeg: Double) -> SIMD3<Double> {
    rotation * Self.earthVector(latDeg: latDeg, lonDeg: lonDeg)
  }

  static func earthVector(latDeg: Double, lonDeg: Double) -> SIMD3<Double> {
    let lat = latDeg.radians
    let lon = lonDeg.radians
    return SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
  }

  static func rotation(about axis: SIMD3<Double>, by radians: Double) -> simd_double3x3 {
    simd_double3x3(simd_quatd(angle: radians, axis: axis))
  }

  // MARK: - Motion

  func setAnimated(_ animated: Bool) {
    isAnimated = animated
    if !animated {
      spinRadPerMs = 0
    }
  }

  func beginDrag() {
    isDragging = true
    spinRadPerMs = 0
  }

  /// The finger moved by (dx, dy) pt, y down: the point under it follows.
  func drag(dx: CGFloat, dy: CGFloat) {
    let length = Double(hypot(dx, dy))
    guard length > 0 else { return }
    let axis = SIMD3(Double(dy) / length, Double(dx) / length, 0)
    rotation = Self.rotation(about: axis, by: length / Double(earthRadius)) * rotation
  }

  /// The finger is up, moving at (vx, vy) pt/s.
  func endDrag(vx: CGFloat, vy: CGFloat) {
    isDragging = false
    let speed = Double(hypot(vx, vy))
    guard isAnimated, speed > 0 else {
      spinRadPerMs = 0
      return
    }
    spinAxis = SIMD3(Double(vy) / speed, Double(vx) / speed, 0)
    spinRadPerMs = speed / Double(earthRadius) / 1000
    if spinDegPerS < Self.stopSpeedDegPerS {
      spinRadPerMs = 0
    }
  }

  var spinDegPerS: Double {
    (spinRadPerMs * 1000).degrees
  }

  /// One frame: the satellites go on, the flick slows down, the idle spin takes over when it is spent.
  func step(dtMs: Double) {
    guard isAnimated else { return }
    phaseDeg = (phaseDeg + 360 * dtMs / Self.orbitPeriodMs).truncatingRemainder(dividingBy: 360)
    guard !isDragging else { return }
    if spinRadPerMs > 0 {
      rotation = Self.rotation(about: spinAxis, by: spinRadPerMs * dtMs) * rotation
      spinRadPerMs *= pow(Self.spinDamping, dtMs)
      if spinDegPerS < Self.stopSpeedDegPerS {
        spinRadPerMs = 0
      }
    } else {
      rotation = rotation * Self.rotation(about: SIMD3(0, 1, 0), by: (Self.idleSpinDegPerS * dtMs / 1000).radians)
    }
  }

  // MARK: - Satellites

  /// The place of satellite i in the frame of the screen, in Earth radii.
  func satellite(_ i: Int) -> SIMD3<Double> {
    let u = (anomalyDeg[i] + phaseDeg).radians
    let raan = (Double(i / Self.satsPerPlane) * Self.raanStepDeg).radians
    let inc = Self.inclinationDeg.radians
    // In the orbit plane, then inclined about the line of nodes (x), then turned about the pole.
    let inPlane = SIMD3(cos(u), -sin(u) * sin(inc), sin(u) * cos(inc))
    return Self.orbitRadiusFactor * (Self.rotation(about: SIMD3(0, 1, 0), by: raan) * inPlane)
  }

  /// Behind the Earth: the disc hides it.
  func isHidden(_ p: SIMD3<Double>) -> Bool {
    p.z < 0 && p.x * p.x + p.y * p.y < 1
  }

  func isOn(_ i: Int) -> Bool {
    on[i]
  }

  func toggle(_ i: Int) {
    on[i].toggle()
  }

  var onCount: Int {
    on.filter { $0 }.count
  }

  /// The nearest satellite on the side of the viewer within `satTapRadiusPt` of the point, or nil.
  func satelliteAt(_ point: CGPoint) -> Int? {
    var best: Int?
    var bestDistance = Self.satTapRadiusPt
    for i in 0 ..< Self.satellites {
      let (p, isFront) = project(satellite(i))
      guard isFront else { continue }
      let d = hypot(p.x - point.x, p.y - point.y)
      if d <= bestDistance {
        best = i
        bestDistance = d
      }
    }
    return best
  }

  // MARK: - The car and the beams

  /// The car, in the frame of the screen: it stands in the middle of the jammed area.
  var car: SIMD3<Double> {
    fromEarth(latDeg: Self.jamLatDeg, lonDeg: Self.jamLonDeg)
  }

  /// Always true: the car never leaves the jammed area. The flag is here so the scene tells why a beam is broken.
  var isCarJammed: Bool {
    Self.angleDeg(Self.jamLatDeg, Self.jamLonDeg, Self.jamLatDeg, Self.jamLonDeg) <= Self.jamRadiusDeg
  }

  /// The line from satellite i to the car: none below the horizon of the car or when it is off, broken when jammed.
  /// The horizon of the car is the plane tangent to the Earth at it, and the unit is the Earth radius: a satellite
  /// above the horizon lies further than one radius along the car. The hemisphere of the car is not enough -- a
  /// satellite behind the Earth disc is in it and the beam would cross the disc.
  func beam(_ i: Int) -> Beam {
    guard on[i], simd_dot(satellite(i), car) > 1 else { return .none }
    return isCarJammed ? .broken : .reaches
  }

  private static func angleDeg(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let a = lat1.radians
    let b = lat2.radians
    let cosAngle = sin(a) * sin(b) + cos(a) * cos(b) * cos((lon1 - lon2).radians)
    return acos(max(-1, min(1, cosAngle))).degrees
  }
}

private extension Double {
  var radians: Double { self * .pi / 180 }
  var degrees: Double { self * 180 / .pi }
}
