/// The bar of the calibration of the sensor box when the car stands still: it slides out of the speed to the side when
/// the core waits for the car. It shows how much the box shakes in the last 3 s on a split scale, the last 2 s of it
/// shaded (the box wants the car still for so long), and a chip with the try, the time held or the peak: the core
/// calibrates the box by itself when the car is still. A tap cancels it and opens the calibration page.
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
    static let traceHeight = CGFloat(30)
    // The dashed line is at the limit of the stillness (100), at kTraceLimitFraction of the height from the top. Below
    // it the scale is linear from 0 to the limit, above it log10 up to traceTopPercent: a value over it is on the top
    // edge with a red tick.
    static let limitPercent = 100.0
    static let traceTopPercent = 1000.0
    static let traceLimitFraction = 0.45
    // The box sends a line every 20 ms: the trace of 3 s has so many.
    static let traceLines = 150
    static let lineMs = 20
    // The box wants the car still for this long to tell STILL, the last so many lines are shaded.
    static let holdMs = 2000
    static let holdLines = holdMs / lineMs
    // The chip says "peak" when nothing is held and the peak of the trace is this much of the limit.
    static let peakChipPercent = 300.0
    // Engine::kCalibrateWhenStillMaxFailures: the core gives up after so many tries.
    static let maxTries = 5
    static let traceRefreshInterval: TimeInterval = 0.05
  }

  /// What the bar tells while the core waits for the car and calibrates.
  enum State: Equatable {
    case waiting
    case calibrating
    case moved

    var text: String {
      switch self {
      case .waiting: return L("nogps_calibrate_bar_hold")
      case .calibrating: return L("nogps_calibrate_bar_measuring")
      case .moved: return L("nogps_calibrate_bar_moved")
      }
    }
  }

  private let bar = UIView()
  private let progress = UIView()
  private let content = UIStackView()
  private let title = UILabel()
  private let chip = ChipLabel()
  private let ready = UILabel()
  private let trace = ShakeTraceView()
  private var shake: [Double] = []
  private var lastStatus: NoGpsStatus?
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

    title.font = .systemFont(ofSize: 11.5, weight: .bold)
    title.textColor = .white
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    chip.setContentHuggingPriority(.required, for: .horizontal)
    chip.setContentCompressionResistancePriority(.required, for: .horizontal)
    let header = UIStackView(arrangedSubviews: [title, chip])
    header.spacing = 6
    header.alignment = .center
    trace.translatesAutoresizingMaskIntoConstraints = false
    ready.font = .systemFont(ofSize: 15, weight: .semibold)
    ready.textColor = .white
    ready.text = L("nogps_calibrate_bar_ready")
    ready.isHidden = true
    ready.translatesAutoresizingMaskIntoConstraints = false
    let body = UIView()
    body.addSubview(trace)
    body.addSubview(ready)

    content.axis = .vertical
    content.spacing = 4
    content.addArrangedSubview(header)
    content.addArrangedSubview(body)
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
      body.heightAnchor.constraint(equalToConstant: Constants.traceHeight),
      trace.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      trace.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      trace.topAnchor.constraint(equalTo: body.topAnchor),
      trace.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      ready.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      ready.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      ready.centerYAnchor.constraint(equalTo: body.centerYAnchor),
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
    // The first try of an arming can still see the failure of an earlier calibration: not a move of this one.
    case .failedMoving where status.calibrationTries >= 2: return .moved
    default: return .waiting
    }
  }

  /// The chip at the right of the first row, nil when there is nothing to say.
  /// \param values the trace of the shake in percent of the limit, the oldest first.
  static func chipText(_ status: NoGpsStatus, values: [Double]) -> String? {
    switch state(status) {
    case .calibrating:
      return "\(status.calibrationProgress) %"
    case .moved:
      return String(format: L("nogps_calibrate_bar_try"), status.calibrationTries, Constants.maxTries)
    case .waiting:
      let held = heldMs(values)
      if held >= Constants.holdMs, !status.boxStill {
        return L("nogps_calibrate_bar_waiting_box")
      }
      if held > 0 {
        let seconds = String(format: "%.1f", locale: Locale.current, Double(held) / 1000)
        return String(format: L("nogps_calibrate_bar_held"), seconds)
      }
      let peak = values.suffix(Constants.traceLines).max() ?? 0
      if peak >= Constants.peakChipPercent {
        return String(format: L("nogps_calibrate_bar_peak"), Int((peak / Constants.limitPercent).rounded()))
      }
      return nil
    }
  }

  /// How long the car has been still by the trace: the newest values under the limit in a row, at most holdMs.
  static func heldMs(_ values: [Double]) -> Int {
    let held = values.reversed().prefix { $0 < Constants.limitPercent }.count
    return min(held * Constants.lineMs, Constants.holdMs)
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
    lastStatus = status
    title.text = state.text
    accessibilityLabel = state.text
    setProgress(state == .calibrating ? CGFloat(status.calibrationProgress) / 100 : 0)
    trace.showsHold = state != .calibrating
    ready.isHidden = true
    trace.isHidden = false
    updateChip()
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
    title.text = L("nogps_calibrate_bar_done")
    accessibilityLabel = title.text
    chip.text = nil
    trace.isHidden = true
    ready.isHidden = false
    setProgress(0)
    UIView.animate(withDuration: 0.25) { self.bar.backgroundColor = Constants.done }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// The trace of the shake in percent of the stillness limit, the oldest first: the app polls it while the bar is open.
  func setShake(_ values: [NSNumber]) {
    shake = values.map(\.doubleValue)
    trace.values = shake
    if !isDone {
      updateChip()
    }
  }

  private func updateChip() {
    chip.text = lastStatus.flatMap { Self.chipText($0, values: shake) }
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

/// A small rounded label with the text of the chip, hidden without a text.
final class ChipLabel: UILabel {
  private static let insets = UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)

  override init(frame: CGRect) {
    super.init(frame: frame)
    font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
    textColor = .white
    backgroundColor = UIColor.white.withAlphaComponent(0.26)
    layer.cornerRadius = 7
    layer.masksToBounds = true
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var text: String? {
    didSet { isHidden = text == nil }
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: Self.insets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + Self.insets.left + Self.insets.right,
                  height: size.height + Self.insets.top + Self.insets.bottom)
  }
}

/// The trace of the shake on a white track. The dashed line is at the limit of the stillness, 45% from the top: below
/// it the scale is linear from 0 to the limit, above it log10 up to 10 times the limit, with faint guide lines at 3x
/// and 10x. The line of the trace is orange above the limit and green below. The last 2 s are shaded, green when all
/// of them are under the limit, a value over the top of the scale has a red tick on the top edge.
final class ShakeTraceView: UIView {
  var values: [Double] = [] {
    didSet { setNeedsLayout() }
  }

  /// The hold window is shaded: not while the box measures.
  var showsHold = true {
    didSet { setNeedsLayout() }
  }

  private let hold = CALayer()
  private let guides = CAShapeLayer()
  private let ticks = CAShapeLayer()
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
    layer.addSublayer(hold)
    guides.fillColor = nil
    guides.strokeColor = UIColor.black.withAlphaComponent(0.12).cgColor
    guides.lineWidth = 1
    layer.addSublayer(guides)
    for (shape, mask, color) in [(above, aboveMask, UIColor.systemOrange), (below, belowMask, UIColor.systemGreen)] {
      shape.fillColor = nil
      shape.strokeColor = color.cgColor
      shape.lineWidth = 1.5
      shape.lineJoin = .round
      mask.backgroundColor = UIColor.black.cgColor
      shape.mask = mask
      layer.addSublayer(shape)
    }
    ticks.fillColor = nil
    ticks.strokeColor = UIColor.systemRed.cgColor
    ticks.lineWidth = 2
    layer.addSublayer(ticks)
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

  /// y of a shake value in a view of |height|: 0 is the bottom, the limit is at traceLimitFraction from the top, the top
  /// of the scale and more is the top edge.
  static func y(_ value: Double, height: CGFloat) -> CGFloat {
    let c = NoGpsCalibrationBarView.Constants.self
    let limitY = height * CGFloat(c.traceLimitFraction)
    let value = max(value, 0)
    if value <= c.limitPercent {
      return height - (height - limitY) * CGFloat(value / c.limitPercent)
    }
    let above = log10(min(value, c.traceTopPercent) / c.limitPercent) / log10(c.traceTopPercent / c.limitPercent)
    return limitY * CGFloat(1 - above)
  }

  /// The points of the trace in the rect: the newest at the end, the oldest first, so it scrolls to the left.
  static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
    let lines = NoGpsCalibrationBarView.Constants.traceLines
    let step = size.width / CGFloat(lines - 1)
    let first = lines - min(values.count, lines)
    return values.suffix(lines).enumerated().map { i, value in
      CGPoint(x: CGFloat(first + i) * step, y: y(value, height: size.height))
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let c = NoGpsCalibrationBarView.Constants.self
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGMutablePath()
    let points = Self.points(values, in: bounds.size)
    if let start = points.first {
      path.move(to: start)
      points.dropFirst().forEach { path.addLine(to: $0) }
    }
    let limitY = Self.y(c.limitPercent, height: bounds.height)
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
    let guideLines = CGMutablePath()
    for percent in [3 * c.limitPercent, c.traceTopPercent] {
      let y = Self.y(percent, height: bounds.height)
      guideLines.move(to: CGPoint(x: 0, y: y))
      guideLines.addLine(to: CGPoint(x: bounds.width, y: y))
    }
    guides.frame = bounds
    guides.path = guideLines
    let tickPath = CGMutablePath()
    for (value, point) in zip(values.suffix(c.traceLines), points) where value > c.traceTopPercent {
      tickPath.move(to: CGPoint(x: point.x, y: 0))
      tickPath.addLine(to: CGPoint(x: point.x, y: 4))
    }
    ticks.frame = bounds
    ticks.path = tickPath
    // The last holdLines of the trace, also while the trace is shorter.
    let holdX = bounds.width * CGFloat(c.traceLines - c.holdLines) / CGFloat(c.traceLines - 1)
    hold.frame = CGRect(x: holdX, y: 0, width: bounds.width - holdX, height: bounds.height)
    let still = NoGpsCalibrationBarView.heldMs(values) >= c.holdMs
    hold.backgroundColor = (still ? UIColor.systemGreen : UIColor.systemOrange).withAlphaComponent(0.16).cgColor
    hold.isHidden = !showsHold
    CATransaction.commit()
  }
}
