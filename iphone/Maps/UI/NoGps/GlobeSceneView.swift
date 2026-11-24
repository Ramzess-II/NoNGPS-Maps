import simd
import UIKit

/// The globe of About NonGPS Maps: the Earth, the GPS constellation and the jammed area with the car, which the
/// finger spins. The model is GlobeScene, this view draws it and turns touches into its calls. GlobeSceneView.java is
/// the same on Android.
final class GlobeSceneView: UIView {
  private enum Constants {
    static let graticuleStepDeg = 30
    static let sampleStepDeg = 6
    static let jamRingPoints = 48
    /// A frame after a pause, e.g. a backgrounded app, is not a jump of the whole pause.
    static let maxFrameMs = 100.0
    static let satelliteRadius: CGFloat = 3.5
    static let panelLength: CGFloat = 5.5
    static let breakSize: CGFloat = 5
    static let dimAlpha: CGFloat = 0.35
    static let backGraticuleAlpha: CGFloat = 0.35
    /// The coverage is computed for a pixel of the bitmap per pt of the disc, and drawn scaled with filtering.
    static let coveragePixelsPerPt: CGFloat = 1
  }

  private struct Palette {
    let sea: UIColor
    let graticule: UIColor
    let land: UIColor
    let satellite: UIColor
    let satelliteOff: UIColor
    let beam: UIColor
    let jam: UIColor
    let car: UIColor
    let carOutline: UIColor
    /// The green of the coast: the coast stays drawn over it.
    let landFill: UIColor
    /// Translucent, as the outage: the graticule, the coast and the jam stay readable over them.
    let coverage: UIColor
    let outage: UIColor

    static func color(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> UIColor {
      UIColor { trait in
        let hex = trait.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
      }
    }

    static let current = Palette(sea: color(0xDCEBF5, 0x22384A),
                                 graticule: color(0x7FA3C0, 0x6E97B8),
                                 land: color(0x4F8A5E, 0x6FA77C),
                                 satellite: color(0x2B3A4A, 0xE3EEF8),
                                 satelliteOff: color(0x9AA0A6, 0x7B8086),
                                 beam: color(0x2F6FA8, 0x5BB4E6),
                                 jam: color(0xE67700, 0xFFA040),
                                 car: color(0xFFD500, 0xFFD500),
                                 carOutline: color(0x1E2226, 0x1E2226),
                                 landFill: color(0x4F8A5E, 0x6FA77C, alpha: 0.8),
                                 coverage: color(0x2F6FA8, 0x5BB4E6, alpha: 0.45),
                                 outage: color(0xD0342C, 0xFF6B5E, alpha: 0.45))
  }

  // The unit vectors of the Earth frame, which do not change: the graticule, the coast and the rim of the jam.
  private static let graticule = buildGraticule()
  private static let coast = buildCoast()
  private static let jamRing = buildJamRing()

  private let scene = GlobeScene()
  private var displayLink: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0
  private var lastTranslation = CGPoint.zero
  /// The coverage of the disc, made again only when its size changes.
  private var coverageBitmap: CGContext?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
    isAccessibilityElement = true
    accessibilityLabel = L("nogps_about_globe_hint")
    scene.setAnimated(!UIAccessibility.isReduceMotionEnabled)
    addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned)))
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                           name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
  }

  /// The palette is resolved in draw(); without the display link nothing else redraws on a theme change.
  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
      setNeedsDisplay()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Frames

  /// A backgrounded screen draws nothing: the link lives only while the view is in a window.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    stopFrames()
    if window != nil {
      startFrames()
    }
  }

  private func startFrames() {
    scene.setAnimated(!UIAccessibility.isReduceMotionEnabled)
    guard scene.isAnimated, displayLink == nil else { return }
    lastTimestamp = 0
    let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopFrames() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func reduceMotionChanged() {
    stopFrames()
    if window != nil {
      startFrames()
    }
    setNeedsDisplay()
  }

  @objc private func frame(_ link: CADisplayLink) {
    let dtMs = lastTimestamp == 0 ? 0 : min((link.timestamp - lastTimestamp) * 1000, Constants.maxFrameMs)
    lastTimestamp = link.timestamp
    scene.step(dtMs: dtMs)
    setNeedsDisplay()
  }

  // MARK: - Touch

  override func layoutSubviews() {
    super.layoutSubviews()
    scene.setSize(bounds.size)
  }

  @objc private func panned(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: self)
    switch gesture.state {
    case .began:
      scene.beginDrag()
      lastTranslation = .zero
      fallthrough
    case .changed:
      scene.drag(dx: translation.x - lastTranslation.x, dy: translation.y - lastTranslation.y)
      lastTranslation = translation
    case .ended:
      let velocity = gesture.velocity(in: self)
      scene.endDrag(vx: velocity.x, vy: velocity.y)
    case .cancelled, .failed:
      scene.endDrag(vx: 0, vy: 0)
    default:
      break
    }
    setNeedsDisplay()
  }

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    guard let i = scene.satelliteAt(gesture.location(in: self)) else { return }
    scene.toggle(i)
    setNeedsDisplay()
  }

  // MARK: - Drawing

  override func draw(_: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    let palette = Palette.current
    let center = scene.center
    let radius = scene.earthRadius
    let color = { (c: UIColor) in c.resolvedColor(with: self.traitCollection) }
    context.setLineCap(.round)
    context.setLineJoin(.round)

    for i in 0 ..< GlobeScene.satellites where scene.satellite(i).z <= 0 {
      drawSatellite(context, i, behind: true, palette: palette)
    }

    let disc = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    context.setFillColor(color(palette.sea).cgColor)
    context.fillEllipse(in: disc)
    drawGround(context, disc: disc, palette: palette)
    context.setLineWidth(1)
    context.setStrokeColor(color(palette.graticule).cgColor)
    context.strokeEllipse(in: disc)

    // The far side first and faint, so the globe reads as a sphere.
    context.setLineWidth(0.8)
    context.setStrokeColor(color(palette.graticule).withAlphaComponent(Constants.backGraticuleAlpha).cgColor)
    addLines(context, Self.graticule, front: false)
    context.strokePath()
    context.setStrokeColor(color(palette.graticule).cgColor)
    addLines(context, Self.graticule, front: true)
    context.strokePath()

    context.setLineWidth(1.4)
    context.setStrokeColor(color(palette.land).cgColor)
    addLines(context, Self.coast, front: true)
    context.strokePath()

    drawJam(context, palette: palette)
    drawBeams(context, palette: palette)
    drawCar(context, palette: palette)

    for i in 0 ..< GlobeScene.satellites where scene.satellite(i).z > 0 {
      drawSatellite(context, i, behind: false, palette: palette)
    }
  }

  /// The land and, over it and the sea, the coverage: the ground of the front half that sees enough satellites for a
  /// fix carries the coverage tint, the rest the outage tint. Each pixel of the bitmap is the front point of the unit
  /// disc under it: `satellite(i)` is in the frame of the screen too, and only the land needs the frame of the Earth.
  private func drawGround(_ context: CGContext, disc: CGRect, palette: Palette) {
    let side = Int((disc.width * Constants.coveragePixelsPerPt).rounded(.up))
    guard side > 0 else { return }
    if coverageBitmap?.width != side {
      coverageBitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 4 * side,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                   | CGBitmapInfo.byteOrder32Big.rawValue)
    }
    guard let bitmap = coverageBitmap, let data = bitmap.data else { return }
    // Indexed by [covered][land]: a tint over the land fill, or over the sea drawn under the bitmap.
    let land = premultiplied(palette.landFill)
    let tints = [premultiplied(palette.outage), premultiplied(palette.coverage)]
    let colors = tints.map { tint in [tint, tint + land * (1 - tint.w)].map(Self.bytes) }
    let none: [UInt8] = [0, 0, 0, 0]
    let pixels = data.bindMemory(to: UInt8.self, capacity: 4 * side * side)
    let satellites = scene.onSatellites()
    let toEarth = scene.rotation.transpose
    for row in 0 ..< side {
      // Row 0 is the top of the disc, y up.
      let y = 1 - 2 * (Double(row) + 0.5) / Double(side)
      for col in 0 ..< side {
        let x = 2 * (Double(col) + 0.5) / Double(side) - 1
        let r2 = x * x + y * y
        var color = none
        if r2 < 1 {
          let p = SIMD3(x, y, (1 - r2).squareRoot())
          let covered = GlobeScene.isCovered(at: p, by: satellites) ? 1 : 0
          color = colors[covered][GlobeScene.isLand(toEarth * p) ? 1 : 0]
        }
        let offset = 4 * (row * side + col)
        for k in 0 ..< 4 {
          pixels[offset + k] = color[k]
        }
      }
    }
    guard let image = bitmap.makeImage() else { return }
    context.saveGState()
    context.addEllipse(in: disc)
    context.clip()
    context.interpolationQuality = .medium
    // The UIKit context is flipped: without this, the first row of the image would be drawn at the bottom.
    context.translateBy(x: 0, y: disc.minY + disc.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: disc)
    context.restoreGState()
  }

  /// RGBA with the alpha multiplied in, so a colour over another is `top + bottom * (1 - top.w)`.
  private func premultiplied(_ color: UIColor) -> SIMD4<Double> {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
    return SIMD4(Double(r * a), Double(g * a), Double(b * a), Double(a))
  }

  /// The bytes of a pixel of the bitmap, in their order in memory.
  private static func bytes(_ color: SIMD4<Double>) -> [UInt8] {
    [color.x, color.y, color.z, color.w].map { UInt8(($0 * 255).rounded()) }
  }

  /// The segments of the lines on one side of the globe. A line is a row of unit vectors of the Earth frame, nil
  /// between two lines.
  private func addLines(_ context: CGContext, _ lines: [SIMD3<Double>?], front: Bool) {
    var previous: (point: CGPoint, isFront: Bool)?
    for p in lines {
      guard let p else {
        previous = nil
        continue
      }
      let next = scene.project(scene.rotation * p)
      if let previous, previous.isFront == next.isFront, next.isFront == front {
        context.addLine(to: next.point)
      } else {
        context.move(to: next.point)
      }
      previous = next
    }
  }

  private func drawJam(_ context: CGContext, palette: Palette) {
    // A point on the far side is pushed to the rim of the disc: what shows is the part of the cap in front of it.
    var anyFront = false
    var points = [CGPoint]()
    for case let p? in Self.jamRing {
      let rotated = scene.rotation * p
      var (point, isFront) = scene.project(rotated)
      anyFront = anyFront || isFront
      let length = hypot(rotated.x, rotated.y)
      if !isFront, length > 0 {
        point = CGPoint(x: scene.center.x + scene.earthRadius * CGFloat(rotated.x / length),
                        y: scene.center.y - scene.earthRadius * CGFloat(rotated.y / length))
      }
      points.append(point)
    }
    guard anyFront else { return }
    let jam = palette.jam.resolvedColor(with: traitCollection)
    context.addLines(between: points)
    context.closePath()
    context.setFillColor(jam.withAlphaComponent(0.28).cgColor)
    context.fillPath()

    context.setLineWidth(1.6)
    context.setStrokeColor(jam.cgColor)
    context.setLineDash(phase: 0, lengths: [5, 4])
    addLines(context, Self.jamRing, front: true)
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
  }

  private func drawBeams(_ context: CGContext, palette: Palette) {
    let carProjection = scene.project(scene.car)
    guard carProjection.isFront else { return }
    let car = carProjection.point
    context.setLineWidth(1)
    context.setStrokeColor(palette.beam.resolvedColor(with: traitCollection).withAlphaComponent(0.8).cgColor)
    for i in 0 ..< GlobeScene.satellites {
      let beam = scene.beam(i)
      if beam == .none {
        continue
      }
      let from = scene.project(scene.satellite(i)).point
      let dx = car.x - from.x
      let dy = car.y - from.y
      let length = hypot(dx, dy)
      context.move(to: from)
      if beam == .reaches || length <= GlobeScene.beamGapPt {
        context.addLine(to: car)
        context.strokePath()
        continue
      }
      // Stops short of the car and ends in a broken stub: the signal is there and does not arrive.
      let ux = dx / length
      let uy = dy / length
      let end = CGPoint(x: car.x - ux * GlobeScene.beamGapPt, y: car.y - uy * GlobeScene.beamGapPt)
      let b = Constants.breakSize
      context.addLine(to: end)
      context.move(to: CGPoint(x: end.x - uy * b - ux * b, y: end.y + ux * b - uy * b))
      context.addLine(to: CGPoint(x: end.x + uy * b + ux * b, y: end.y - ux * b + uy * b))
      context.strokePath()
    }
  }

  private func drawCar(_ context: CGContext, palette: Palette) {
    let (p, isFront) = scene.project(scene.car)
    guard isFront else { return }
    let body = CGMutablePath()
    body.addPath(CGPath(roundedRect: CGRect(x: p.x - 7, y: p.y - 3.5, width: 14, height: 7), cornerWidth: 2.5,
                        cornerHeight: 2.5, transform: nil))
    body.addPath(CGPath(roundedRect: CGRect(x: p.x - 3.5, y: p.y - 6, width: 7, height: 4), cornerWidth: 2,
                        cornerHeight: 2, transform: nil))
    // The outline first and twice as wide, so the fill covers its inner half and the seam of the two shapes.
    context.setLineWidth(2)
    context.setStrokeColor(palette.carOutline.resolvedColor(with: traitCollection).cgColor)
    context.addPath(body)
    context.strokePath()
    context.setFillColor(palette.car.resolvedColor(with: traitCollection).cgColor)
    context.addPath(body)
    context.fillPath()
    context.setFillColor(palette.sea.resolvedColor(with: traitCollection).cgColor)
    for dx: CGFloat in [-4, 4] {
      context.fillEllipse(in: CGRect(x: p.x + dx - 1.8, y: p.y + 3.5 - 1.8, width: 3.6, height: 3.6))
    }
  }

  private func drawSatellite(_ context: CGContext, _ i: Int, behind: Bool, palette: Palette) {
    let p = scene.project(scene.satellite(i)).point
    let on = scene.isOn(i)
    var color = (on ? palette.satellite : palette.satelliteOff).resolvedColor(with: traitCollection)
    if behind {
      color = color.withAlphaComponent(Constants.dimAlpha)
    }
    let r = Constants.satelliteRadius
    context.setStrokeColor(color.cgColor)
    context.setFillColor(color.cgColor)
    if on {
      context.setLineWidth(2.4)
      context.setLineCap(.butt)
      context.move(to: CGPoint(x: p.x - r - Constants.panelLength, y: p.y))
      context.addLine(to: CGPoint(x: p.x - r, y: p.y))
      context.move(to: CGPoint(x: p.x + r, y: p.y))
      context.addLine(to: CGPoint(x: p.x + r + Constants.panelLength, y: p.y))
      context.strokePath()
      context.setLineCap(.round)
      context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    } else {
      // Off: hollow and grey.
      context.setLineWidth(1.4)
      context.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
  }

  // MARK: - The unit vectors of the Earth frame

  private static func buildGraticule() -> [SIMD3<Double>?] {
    var points = [SIMD3<Double>?]()
    for lon in stride(from: 0, to: 360, by: Constants.graticuleStepDeg) {
      for lat in stride(from: -90, through: 90, by: Constants.sampleStepDeg) {
        points.append(GlobeScene.earthVector(latDeg: Double(lat), lonDeg: Double(lon)))
      }
      points.append(nil)
    }
    for lat in stride(from: -90 + Constants.graticuleStepDeg, to: 90, by: Constants.graticuleStepDeg) {
      for lon in stride(from: 0, through: 360, by: Constants.sampleStepDeg) {
        points.append(GlobeScene.earthVector(latDeg: Double(lat), lonDeg: Double(lon)))
      }
      points.append(nil)
    }
    return points
  }

  private static func buildCoast() -> [SIMD3<Double>?] {
    var points = [SIMD3<Double>?]()
    let flat = GlobeCoastline.points
    let scale = Double(GlobeCoastline.scale)
    for i in stride(from: 0, to: flat.count - 1, by: 2) {
      if flat[i] == GlobeCoastline.separator {
        points.append(nil)
      } else {
        points.append(GlobeScene.earthVector(latDeg: Double(flat[i]) / scale, lonDeg: Double(flat[i + 1]) / scale))
      }
    }
    return points
  }

  /// The circle of `jamRadiusDeg` about the jam centre, closed.
  private static func buildJamRing() -> [SIMD3<Double>?] {
    let lat = GlobeScene.jamLatDeg * .pi / 180
    let lon = GlobeScene.jamLonDeg * .pi / 180
    let r = GlobeScene.jamRadiusDeg * .pi / 180
    let center = GlobeScene.earthVector(latDeg: GlobeScene.jamLatDeg, lonDeg: GlobeScene.jamLonDeg)
    // East and north at the centre.
    let east = SIMD3(cos(lon), 0, -sin(lon))
    let north = SIMD3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
    return (0 ... Constants.jamRingPoints).map { i in
      let bearing = 2 * Double.pi * Double(i) / Double(Constants.jamRingPoints)
      return cos(r) * center + sin(r) * (sin(bearing) * east + cos(bearing) * north)
    }
  }
}
