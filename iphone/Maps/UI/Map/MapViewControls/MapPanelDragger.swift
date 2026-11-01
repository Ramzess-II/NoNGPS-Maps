/// Moves a panel of map buttons up and down its free area, where a hand or a car holder may cover it. A long press lifts
/// the panel, the finger drags it, a quick release flings it on with a bounce at the ends. Its place is kept as a
/// fraction of the distance it can travel, so it stays when the area or the panel changes size.
@objc
final class MapPanelDragger: NSObject {
  enum Constants {
    /// A slower release leaves the panel where it is, pt/s.
    static let flingSpeed = CGFloat(800)
    /// The speed of a fling is multiplied by it every ms, as UIScrollView.DecelerationRate.normal.
    static let deceleration = CGFloat(0.998)
    /// The part of the speed kept by a bounce at an end.
    static let bounce = CGFloat(0.6)
    /// A fling stops below it, pt/s.
    static let stopSpeed = CGFloat(30)
    /// The release speed is taken from the movement of the finger in this time before it.
    static let speedWindow: CFTimeInterval = 0.1
    /// The middle of the area.
    static let defaultFraction = CGFloat(0.5)
  }

  /// One frame of a fling: the place and the speed after dt seconds. The speed goes down as in a scroll view, the panel
  /// bounces back from min and max and stops at a low speed.
  static func step(y: CGFloat, v: CGFloat, dt: CGFloat, min: CGFloat, max: CGFloat) -> (y: CGFloat, v: CGFloat) {
    let rate = log(Constants.deceleration) * 1000
    let decay = exp(rate * dt)
    var y = y + v * (decay - 1) / rate
    var v = v * decay
    if y > max {
      y = max - (y - max) * Constants.bounce
      v = -v * Constants.bounce
    } else if y < min {
      y = min + (min - y) * Constants.bounce
      v = -v * Constants.bounce
    }
    if abs(v) < Constants.stopSpeed {
      v = 0
    }
    return (Swift.min(Swift.max(y, min), max), v)
  }

  /// Whether a release with the speed v flings the panel on.
  static func flings(_ v: CGFloat) -> Bool {
    abs(v) >= Constants.flingSpeed
  }

  /// From 0 at the top of the area to 1 at the bottom.
  @objc private(set) var fraction: CGFloat
  /// A hidden panel can't be moved.
  @objc var isEnabled = true {
    didSet {
      gesture.isEnabled = isEnabled
      if !isEnabled {
        drop()
      }
    }
  }

  /// The panel follows the finger or flies: its place is not animated.
  @objc private(set) var isMoving = false

  private let key: String
  private let travel: () -> CGFloat
  private let onLift: (Bool) -> Void
  private let onMove: () -> Void
  private let gesture = UILongPressGestureRecognizer()
  private var displayLink: CADisplayLink?
  private var y = CGFloat(0)
  private var v = CGFloat(0)
  private var startY = CGFloat(0)
  private var startTouch = CGFloat(0)
  private var touches = [(time: CFTimeInterval, y: CGFloat)]()
  private var lastFrame: CFTimeInterval = 0

  /// - Parameters:
  ///   - view: takes the long press, over the buttons on it too.
  ///   - key: of the place in UserDefaults.
  ///   - travel: the distance the panel can move, pt.
  ///   - onLift: shows the panel lifted or put down.
  ///   - onMove: places the panel at fraction.
  @objc
  init(view: UIView, key: String, travel: @escaping () -> CGFloat, onLift: @escaping (Bool) -> Void,
       onMove: @escaping () -> Void) {
    self.key = key
    self.travel = travel
    self.onLift = onLift
    self.onMove = onMove
    fraction = (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) } ?? Constants.defaultFraction
    super.init()
    // The touch is taken from the button under the finger, it does not fire.
    gesture.addTarget(self, action: #selector(onPress))
    view.addGestureRecognizer(gesture)
  }

  @objc
  private func onPress(_ gesture: UILongPressGestureRecognizer) {
    let touch = gesture.location(in: nil).y
    switch gesture.state {
    case .began:
      stopFling()
      y = fraction * travel()
      startY = y
      startTouch = touch
      touches = []
      addTouch(touch)
      lift(true)
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    case .changed:
      addTouch(touch)
      move(to: startY + touch - startTouch)
    case .ended:
      addTouch(touch)
      let speed = releaseSpeed()
      if Self.flings(speed), travel() > 0 {
        fling(speed)
      } else {
        drop()
      }
    default:
      drop()
    }
  }

  private func addTouch(_ y: CGFloat) {
    let now = CACurrentMediaTime()
    touches.removeAll { now - $0.time > Constants.speedWindow }
    touches.append((now, y))
  }

  /// Zero when the finger has stood before the release.
  private func releaseSpeed() -> CGFloat {
    let now = CACurrentMediaTime()
    let recent = touches.filter { now - $0.time <= Constants.speedWindow }
    guard let first = recent.first, let last = recent.last, last.time > first.time else { return 0 }
    return (last.y - first.y) / CGFloat(last.time - first.time)
  }

  private func move(to y: CGFloat) {
    let travel = travel()
    guard travel > 0 else { return }
    self.y = Swift.min(Swift.max(y, 0), travel)
    fraction = self.y / travel
    onMove()
  }

  private func fling(_ speed: CGFloat) {
    v = speed
    lastFrame = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(onFrame))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc
  private func onFrame(_ link: CADisplayLink) {
    let dt = CGFloat(Swift.max(0, link.timestamp - lastFrame))
    lastFrame = link.timestamp
    let travel = travel()
    (y, v) = Self.step(y: y, v: v, dt: dt, min: 0, max: travel)
    move(to: y)
    if v == 0 {
      drop()
    }
  }

  private func stopFling() {
    // The display link keeps its target.
    displayLink?.invalidate()
    displayLink = nil
  }

  /// Puts the panel down where it is.
  private func drop() {
    stopFling()
    guard isMoving else { return }
    UserDefaults.standard.set(Double(fraction), forKey: key)
    lift(false)
  }

  private func lift(_ lifted: Bool) {
    isMoving = lifted
    onLift(lifted)
  }
}
