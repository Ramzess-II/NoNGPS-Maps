/// The bar of the calibration of the sensor box when the car stands still: it slides out of the speed to the side after
/// a tap on the warning to calibrate the box. It shows how much the box shakes in the last 3 s, so the user sees
/// whether the car is still enough: the core calibrates the box by itself when it is. A tap cancels it and opens the
/// calibration page.
final class NoGpsCalibrationBarView: UIControl {
  enum Constants {
    static let height = NoGpsSpeedView.side
    // The bar starts under the speed, its text after it.
    static let textInset = CGFloat(42)
    static let endInset = CGFloat(14)
    static let maxWidth = CGFloat(380)
    static let done = UIColor(red: 0x15 / 255, green: 0x80 / 255, blue: 0x3D / 255, alpha: 1)
    static let openDuration: TimeInterval = 0.52
    static let closeDuration: TimeInterval = 0.28
    static let doneDuration: TimeInterval = 2.8
    static let traceHeight = CGFloat(18)
    // The trace shows this much of the shake, the dashed line is at the limit of the stillness (100).
    static let tracePercent = 200.0
    static let limitPercent = 100.0
    // The box sends a line every 20 ms: the trace of 3 s has so many.
    static let traceLines = 150
    static let traceRefreshInterval: TimeInterval = 0.05
  }

  /// What the bar tells while the core waits for the car and calibrates.
  enum State: Equatable {
    case waiting
    case calibrating
    case moved

    var text: String {
      switch self {
      case .waiting: return L("nogps_calibrate_still_hold")
      case .calibrating: return L("nogps_calibrate_still_calibrating")
      case .moved: return L("nogps_calibrate_still_moved")
      }
    }
  }

  private let bar = UIView()
  private let progress = UIView()
  private let content = UIStackView()
  private let title = UILabel()
  private let trace = ShakeTraceView()
  private var widthConstraint = NSLayoutConstraint()
  private var contentWidth = NSLayoutConstraint()
  private var fullWidth = CGFloat(0)
  private var progressFraction = CGFloat(0)
  private(set) var isOpen = false
  /// The core has calibrated the box: the bar is green until then.
  private var doneEnd: Date?
  private var doneTimer: Timer?
  private var traceTimer: Timer?
  /// The core has sent the calibration to the box since it was armed.
  private var sawCalibrating = false
  private var wasArmed = false

  init() {
    super.init(frame: .zero)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    traceTimer?.invalidate()
    doneTimer?.invalidate()
  }

  var isDone: Bool { doneEnd.map { $0 > Date() } ?? false }
  /// The bar is on the screen: the warning to calibrate the box waits.
  var isShown: Bool { isOpen || isDone }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true
    isAccessibilityElement = true
    accessibilityTraits = [.button, .updatesFrequently]
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.28
    layer.shadowRadius = 4
    layer.shadowOffset = CGSize(width: 0, height: 2)

    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.isUserInteractionEnabled = false
    bar.backgroundColor = .systemOrange
    bar.layer.cornerRadius = Constants.height / 2
    bar.clipsToBounds = true
    addSubview(bar)

    progress.backgroundColor = UIColor.white.withAlphaComponent(0.3)
    bar.addSubview(progress)

    title.font = .systemFont(ofSize: 14, weight: .bold)
    title.textColor = .white
    title.lineBreakMode = .byTruncatingTail
    trace.translatesAutoresizingMaskIntoConstraints = false

    content.axis = .vertical
    content.spacing = 5
    content.addArrangedSubview(title)
    content.addArrangedSubview(trace)
    content.translatesAutoresizingMaskIntoConstraints = false
    content.isUserInteractionEnabled = false
    bar.addSubview(content)

    widthConstraint = widthAnchor.constraint(equalToConstant: 0)
    contentWidth = content.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Constants.height),
      widthConstraint,
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bar.topAnchor.constraint(equalTo: topAnchor),
      bar.bottomAnchor.constraint(equalTo: bottomAnchor),
      // The text keeps its width while the bar slides: it is uncovered, not laid out again.
      content.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Constants.textInset),
      content.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      contentWidth,
      trace.heightAnchor.constraint(equalToConstant: Constants.traceHeight),
    ])
  }

  /// The width of the open bar, from the middle of the speed to the edge of the free area.
  func setFullWidth(_ width: CGFloat) {
    let width = min(Constants.maxWidth, max(0, width))
    guard width != fullWidth else { return }
    fullWidth = width
    contentWidth.constant = max(0, width - Constants.textInset - Constants.endInset)
    if isOpen {
      widthConstraint.constant = width
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width * progressFraction
    let leading = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - width : 0
    progress.frame = CGRect(x: leading, y: 0, width: width, height: bounds.height)
  }

  // MARK: - State

  static func state(_ status: NoGpsStatus) -> State {
    switch status.calibration {
    case .calibrating: return .calibrating
    case .failedMoving: return .moved
    default: return .waiting
    }
  }

  /// Shows the bar for the status once a second and right after the tap. Not while it is green: it ends by itself.
  /// \param speedShown the bar slides out of the speed, not without it.
  func update(status: NoGpsStatus, speedShown: Bool) {
    let armed = status.calibrationArmed
    defer { wasArmed = armed }
    guard !isDone else { return }
    guard armed, speedShown else {
      // The core is not armed after the box answers: calibrated, if it was seen to calibrate.
      if wasArmed, !armed, sawCalibrating, isOpen, status.calibration == .done {
        sawCalibrating = false
        celebrate()
      } else {
        sawCalibrating = false
        close()
      }
      return
    }
    let state = Self.state(status)
    sawCalibrating = sawCalibrating || state == .calibrating
    title.text = state.text
    accessibilityLabel = state.text
    setProgress(state == .calibrating ? CGFloat(status.calibrationProgress) / 100 : 0)
    open()
  }

  private func setProgress(_ fraction: CGFloat) {
    progressFraction = min(1, max(0, fraction))
    setNeedsLayout()
  }

  /// Hides the bar at once, e.g. after the tap on it.
  func cancel() {
    sawCalibrating = false
    doneEnd = nil
    doneTimer?.invalidate()
    close()
  }

  private func celebrate() {
    doneEnd = Date().addingTimeInterval(Constants.doneDuration)
    doneTimer?.invalidate()
    doneTimer = Timer.scheduledTimer(withTimeInterval: Constants.doneDuration, repeats: false) { [weak self] _ in
      self?.doneEnd = nil
      self?.close()
    }
    title.text = L("nogps_calibrate_still_done")
    accessibilityLabel = title.text
    setProgress(0)
    UIView.animate(withDuration: 0.25) { self.bar.backgroundColor = Constants.done }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// The trace of the shake in percent of the stillness limit, the oldest first: the app polls it while the bar is open.
  func setShake(_ values: [NSNumber]) {
    trace.values = values.map(\.doubleValue)
  }

  private func open() {
    guard !isOpen else { return }
    isOpen = true
    isHidden = false
    bar.backgroundColor = .systemOrange
    superview?.layoutIfNeeded()
    widthConstraint.constant = fullWidth
    content.alpha = 0
    content.transform = CGAffineTransform(translationX: -16 * Self.direction, y: 0)
    UIView.animate(withDuration: Constants.openDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                   options: [.beginFromCurrentState, .allowUserInteraction],
                   animations: { self.superview?.layoutIfNeeded() })
    UIView.animate(withDuration: 0.38, delay: 0.2, options: [.curveEaseOut, .allowUserInteraction],
                   animations: {
                     self.content.alpha = 1
                     self.content.transform = .identity
                   })
    traceTimer?.invalidate()
    // The core polls the box at 20 Hz while the bar is open: the status comes once a second, too seldom for a trace.
    let timer = Timer(timeInterval: Constants.traceRefreshInterval, repeats: true) { [weak self] _ in
      self?.setShake(NoGps.boxShake())
    }
    RunLoop.main.add(timer, forMode: .common)
    traceTimer = timer
  }

  private func close() {
    guard isOpen else { return }
    isOpen = false
    traceTimer?.invalidate()
    traceTimer = nil
    widthConstraint.constant = 0
    UIView.animate(withDuration: 0.14) { self.content.alpha = 0 }
    UIView.animate(withDuration: Constants.closeDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState],
                   animations: { self.superview?.layoutIfNeeded() },
                   completion: { _ in
                     if !self.isOpen {
                       self.isHidden = true
                     }
                   })
  }

  private static var direction: CGFloat {
    UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? -1 : 1
  }
}

/// The trace of the shake: a white track with a dashed line at the limit of the stillness, the line of the trace is
/// orange above it and green below.
final class ShakeTraceView: UIView {
  var values: [Double] = [] {
    didSet { setNeedsLayout() }
  }

  private let above = CAShapeLayer()
  private let below = CAShapeLayer()
  private let aboveMask = CALayer()
  private let belowMask = CALayer()
  private let limit = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.white.withAlphaComponent(0.92)
    layer.cornerRadius = 5
    layer.masksToBounds = true
    for (shape, mask, color) in [(above, aboveMask, UIColor.systemOrange), (below, belowMask, UIColor.systemGreen)] {
      shape.fillColor = nil
      shape.strokeColor = color.cgColor
      shape.lineWidth = 1.5
      shape.lineJoin = .round
      mask.backgroundColor = UIColor.black.cgColor
      shape.mask = mask
      layer.addSublayer(shape)
    }
    limit.fillColor = nil
    limit.strokeColor = UIColor.darkGray.cgColor
    limit.lineWidth = 1
    limit.lineDashPattern = [3, 3]
    layer.addSublayer(limit)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The points of the trace in the rect: the newest at the end, the oldest first, so it scrolls to the left.
  static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
    let lines = NoGpsCalibrationBarView.Constants.traceLines
    let top = NoGpsCalibrationBarView.Constants.tracePercent
    let step = size.width / CGFloat(lines - 1)
    let first = lines - min(values.count, lines)
    return values.suffix(lines).enumerated().map { i, value in
      CGPoint(x: CGFloat(first + i) * step, y: size.height * (1 - CGFloat(min(max(value, 0), top) / top)))
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGMutablePath()
    let points = Self.points(values, in: bounds.size)
    if let start = points.first {
      path.move(to: start)
      points.dropFirst().forEach { path.addLine(to: $0) }
    }
    let limitY = bounds.height * (1 - CGFloat(NoGpsCalibrationBarView.Constants.limitPercent
        / NoGpsCalibrationBarView.Constants.tracePercent))
    for shape in [above, below] {
      shape.frame = bounds
      shape.path = path
    }
    aboveMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: limitY)
    belowMask.frame = CGRect(x: 0, y: limitY, width: bounds.width, height: bounds.height - limitY)
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 0, y: limitY))
    line.addLine(to: CGPoint(x: bounds.width, y: limitY))
    limit.frame = bounds
    limit.path = line
    CATransaction.commit()
  }
}
