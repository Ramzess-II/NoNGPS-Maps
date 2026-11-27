import CoreGraphics
import simd

/// The model of the globe of About NonGPS Maps: the Earth, 24 GPS satellites around it and the jammed area with the
/// car. No view in it, so it is tested without one. GlobeScene.java does the same with the same names and constants.
///
/// Points of the scene are in the frame of the screen: x to the right, y up, z to the viewer, the unit is the Earth
/// radius. The Earth turns in it by `rotation`, which maps the frame of the Earth (y is the polar axis, lon 0 is +z)
/// to the frame of the screen. The satellites orbit in `orbitFrame`, whose y is the polar axis too: a drag or a flick
/// turns the view, so both frames turn together, and the idle spin turns the Earth alone under the orbits.
/// Distances on the screen are in pt.
final class GlobeScene {
  /// The largest height of the globe on screen; About gives it less when the page would not fit, and the scene works at
  /// any size.
  static let sceneHeightPt: CGFloat = 400
  /// The real orbit, 26 560 km over an Earth of 6 371 km: the coverage on the ground depends on it.
  static let orbitRadiusFactor = 4.16
  /// The orbit stays this far inside the scene, so the dot of a satellite is never cut.
  static let satMarginPt: CGFloat = 6
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
  /// A receiver needs this many satellites for a fix.
  static let fixSatellites = 4
  /// A satellite lower over the horizon than this does not count, as in a receiver.
  static let elevationMaskDeg = 10.0
  private static let sinElevationMask = sin(elevationMaskDeg.radians)

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
  /// The frame of the orbits to the screen frame: `rotation` is it times the turn of the Earth about its pole.
  private var orbitFrame = matrix_identity_double3x3
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
    earthRadius = (min(size.width, size.height) / 2 - Self.satMarginPt) / CGFloat(Self.orbitRadiusFactor)
  }

  /// Orthographic: the place on the screen of p, and whether p is on the side of the viewer.
  func project(_ p: SIMD3<Double>) -> (point: CGPoint, isFront: Bool) {
    (CGPoint(x: center.x + earthRadius * CGFloat(p.x), y: center.y - earthRadius * CGFloat(p.y)), p.z > 0)
  }

  // MARK: - Rotation

  func setRotation(_ matrix: simd_double3x3) {
    rotation = matrix
    orbitFrame = matrix
  }

  /// The Earth turned so that the jammed area is in the middle of the scene.
  func faceJam() {
    setRotation(Self.rotation(about: SIMD3(1, 0, 0), by: Self.jamLatDeg.radians)
      * Self.rotation(about: SIMD3(0, 1, 0), by: -Self.jamLonDeg.radians))
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
    turnView(Self.rotation(about: axis, by: length / Double(earthRadius)))
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

  /// The Earth and the orbits turn together.
  private func turnView(_ turn: simd_double3x3) {
    rotation = turn * rotation
    orbitFrame = turn * orbitFrame
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
      turnView(Self.rotation(about: spinAxis, by: spinRadPerMs * dtMs))
      spinRadPerMs *= pow(Self.spinDamping, dtMs)
      if spinDegPerS < Self.stopSpeedDegPerS {
        spinRadPerMs = 0
      }
    } else {
      // The Earth alone, about its pole: the orbits stay.
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
    return Self.orbitRadiusFactor * (orbitFrame * (Self.rotation(about: SIMD3(0, 1, 0), by: raan) * inPlane))
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

  // MARK: - Land

  /// The cells of `GlobeCoastline.landRuns`, row by row from the north, each row from lon -180.
  private static let landCells: [Bool] = {
    let runs = GlobeCoastline.landRuns
    var cells = [Bool]()
    var i = 0
    while i < runs.count {
      let count = Int(runs[i])
      var isLand = false
      for k in 1 ... count {
        cells += repeatElement(isLand, count: Int(runs[i + k]))
        isLand.toggle()
      }
      i += count + 1
    }
    return cells
  }()

  /// Whether the unit point p of the frame of the Earth is on land.
  static func isLand(_ p: SIMD3<Double>) -> Bool {
    let step = Double(GlobeCoastline.landStepDeg)
    let rows = Int(180 / step)
    let cols = Int(360 / step)
    let lat = asin(max(-1, min(1, p.y))).degrees
    let lon = atan2(p.x, p.z).degrees
    let row = min(Int((90 - lat) / step), rows - 1)
    let col = min(Int((lon + 180) / step), cols - 1)
    return landCells[row * cols + col]
  }

  // MARK: - Coverage

  /// Whether the satellite at s stands at least `elevationMaskDeg` above the horizon of the unit point p of the
  /// Earth: the line to it rises from the plane tangent at p by at least the mask.
  static func isAboveMask(_ s: SIMD3<Double>, from p: SIMD3<Double>) -> Bool {
    let d = s - p
    return simd_dot(d, p) >= simd_length(d) * sinElevationMask
  }

  /// Where the satellites that are on are now.
  func onSatellites() -> [SIMD3<Double>] {
    (0 ..< Self.satellites).filter { on[$0] }.map { satellite($0) }
  }

  /// How many of the satellites stand above the mask of the unit point p, counted up to `limit`.
  static func visibleCount(at p: SIMD3<Double>, of satellites: [SIMD3<Double>], upTo limit: Int = .max) -> Int {
    var count = 0
    for s in satellites where isAboveMask(s, from: p) {
      count += 1
      if count >= limit {
        break
      }
    }
    return count
  }

  /// A receiver at p has a fix: the view takes the satellites once per frame and asks for every point of the disc.
  static func isCovered(at p: SIMD3<Double>, by satellites: [SIMD3<Double>]) -> Bool {
    visibleCount(at: p, of: satellites, upTo: fixSatellites) >= fixSatellites
  }

  /// The satellites that are on and above the mask of the unit point p, in the frame of the screen.
  func visibleCount(at p: SIMD3<Double>) -> Int {
    Self.visibleCount(at: p, of: onSatellites())
  }

  func isCovered(at p: SIMD3<Double>) -> Bool {
    Self.isCovered(at: p, by: onSatellites())
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

  /// The line from satellite i to the car: only for a satellite the car would count, on and above the elevation mask
  /// of the car, and broken when jammed. Above the mask is above the horizon, so a beam never crosses the disc.
  func beam(_ i: Int) -> Beam {
    guard on[i], Self.isAboveMask(satellite(i), from: car) else { return .none }
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
