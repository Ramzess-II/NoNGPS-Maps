/// The bar of the speed calibration: it slides out of the speed to the side while the car drives at a speed GPS has
/// not measured, and celebrates every range GPS measures. The speed table is learned only with accurate GPS, and the
/// user would not know it otherwise. A tap opens the speed calibration.
final class NoGpsSpeedHintView: UIControl {
  enum Constants {
    static let height = NoGpsSpeedView.side
    // The bar starts under the speed, its text after it.
    static let textInset = CGFloat(42)
    static let endInset = CGFloat(14)
    static let maxWidth = CGFloat(380)
    static let accent = UIColor(red: 0x24 / 255, green: 0x56 / 255, blue: 0xE0 / 255, alpha: 1)
    static let done = UIColor(red: 0x15 / 255, green: 0x80 / 255, blue: 0x3D / 255, alpha: 1)
    static let gold = UIColor(red: 1, green: 0xD5 / 255, blue: 0x4A / 255, alpha: 1)
    static let confettiColors: [UIColor] = [
      gold, UIColor(red: 1, green: 0x6B / 255, blue: 0x6B / 255, alpha: 1),
      UIColor(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255, alpha: 1),
      UIColor(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255, alpha: 1),
      UIColor(red: 0xF4 / 255, green: 0x72 / 255, blue: 0xB6 / 255, alpha: 1), .white,
    ]
    static let openDuration: TimeInterval = 0.52
    static let closeDuration: TimeInterval = 0.28
    static let celebrationDuration: TimeInterval = 2.8
    static let milestoneDuration: TimeInterval = 4.5
    static let segmentGap = CGFloat(3)
    static let segmentHeight = CGFloat(5)
    static let ranges = 14
    // As in SpeedTable of the core.
    static let rangeKmh = 10
    static let minKmh = 5
    static let minDistanceM = 300.0
  }

  /// What the bar says.
  struct Texts: Equatable {
    var title: String
    var subtitle: String
    var left: String?
    var noGps = false
  }

  private let bar = UIView()
  private let content = UIStackView()
  private let noGpsIcon = UIImageView(image: UIImage(systemName: "location.slash.fill"))
  private let star = UIImageView(image: UIImage(systemName: "star.fill"))
  private let title = UILabel()
  private let left = UILabel()
  private let subtitle = UILabel()
  private let meter = UIStackView()
  private var segments: [Segment] = []
  private let flash = UIView()
  private var widthConstraint = NSLayoutConstraint()
  private var contentWidth = NSLayoutConstraint()
  private var fullWidth = CGFloat(0)
  private(set) var isOpen = false
  /// The bar shows the status of the event until then, not the one of the next refresh.
  private var celebrationEnd: Date?
  private var celebrationTimer: Timer?

  init() {
    super.init(frame: .zero)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var isCelebrating: Bool { celebrationEnd.map { $0 > Date() } ?? false }

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
    bar.backgroundColor = Constants.accent
    bar.layer.cornerRadius = Constants.height / 2
    bar.clipsToBounds = true
    addSubview(bar)

    flash.translatesAutoresizingMaskIntoConstraints = false
    flash.backgroundColor = .white
    flash.alpha = 0
    bar.addSubview(flash)

    for icon in [noGpsIcon, star] {
      icon.contentMode = .scaleAspectFit
      icon.setContentHuggingPriority(.required, for: .horizontal)
      icon.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    noGpsIcon.tintColor = .white
    noGpsIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    star.tintColor = Constants.gold
    star.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    star.isHidden = true
    title.font = .systemFont(ofSize: 14, weight: .bold)
    title.textColor = .white
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    left.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    left.textColor = .white
    left.setContentHuggingPriority(.required, for: .horizontal)
    left.setContentCompressionResistancePriority(.required, for: .horizontal)
    let line = UIStackView(arrangedSubviews: [noGpsIcon, star, title, left])
    line.spacing = 6
    line.alignment = .center
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = UIColor.white.withAlphaComponent(0.9)
    subtitle.lineBreakMode = .byTruncatingTail

    meter.axis = .horizontal
    meter.spacing = Constants.segmentGap
    meter.distribution = .fillEqually
    for _ in 0 ..< Constants.ranges {
      let segment = Segment()
      segments.append(segment)
      meter.addArrangedSubview(segment)
    }

    content.axis = .vertical
    content.spacing = 3
    for view in [line, subtitle, meter] as [UIView] {
      content.addArrangedSubview(view)
    }
    content.setCustomSpacing(5, after: subtitle)
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
      flash.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      flash.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      flash.topAnchor.constraint(equalTo: bar.topAnchor),
      flash.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
      // The text keeps its width while the bar slides: it is uncovered, not laid out again.
      content.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Constants.textInset),
      content.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      contentWidth,
      meter.heightAnchor.constraint(equalToConstant: Constants.segmentHeight),
      noGpsIcon.widthAnchor.constraint(equalToConstant: 15),
      star.widthAnchor.constraint(equalToConstant: 17),
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

  // MARK: - Texts

  static func rangeKmh(_ range: Int) -> (from: Int, to: Int) {
    (max(Constants.minKmh, range * Constants.rangeKmh), (range + 1) * Constants.rangeKmh)
  }

  static func isMeasured(_ status: NoGpsStatus, _ range: Int) -> Bool {
    range < status.gpsSpeedTableScale.count && status.gpsSpeedTableScale[range].doubleValue > 0
  }

  static func measuredCount(_ status: NoGpsStatus) -> Int {
    status.gpsSpeedTableScale.filter { $0.doubleValue > 0 }.count
  }

  /// The bar is shown while the core asks for it, unless the box asks to be calibrated: that comes first, and both are
  /// at the bottom of the map.
  static func isShown(_ status: NoGpsStatus) -> Bool {
    status.speedHintShown && !NoGpsBoxPage.needsCalibration(status)
  }

  /// While the car drives at a speed GPS has not measured.
  static func texts(_ status: NoGpsStatus) -> Texts {
    let (from, to) = rangeKmh(status.speedHintRange)
    guard status.speedHintGps else {
      return Texts(title: String(format: L("nogps_speed_hint_not_calibrated"), from, to),
                   subtitle: L("nogps_speed_hint_turn_gps_on"), left: nil, noGps: true)
    }
    let range = status.speedHintRange
    let carM = range < status.gpsSpeedTableCarM.count ? status.gpsSpeedTableCarM[range].doubleValue : 0
    let leftM = max(1, Int((Constants.minDistanceM - carM).rounded(.up)))
    return Texts(title: String(format: L("nogps_speed_hint_calibrating"), from, to),
                 subtitle: L("nogps_speed_hint_keep_gps"), left: String(format: L("nogps_speed_table_left"), leftM))
  }

  /// When GPS has measured the range of the status.
  static func celebrationTexts(_ status: NoGpsStatus) -> Texts {
    let all = status.gpsSpeedTableScale.count
    switch status.speedMilestone {
    case .city: return Texts(title: L("nogps_speed_hint_city"), subtitle: L("nogps_speed_hint_city_hint"))
    case .outOfTown:
      return Texts(title: L("nogps_speed_hint_out_of_town"), subtitle: L("nogps_speed_hint_out_of_town_hint"))
    case .full: return Texts(title: L("nogps_speed_hint_full"), subtitle: String(format: L("nogps_speed_hint_full_hint"), all))
    default:
      let (from, to) = rangeKmh(status.speedHintRange)
      return Texts(title: String(format: L("nogps_speed_hint_done"), from, to),
                   subtitle: String(format: L("nogps_speed_hint_done_count"), measuredCount(status), all))
    }
  }

  // MARK: - State

  /// Shows the bar for the status once a second. Not during a celebration: it ends by itself.
  /// \param speedShown the bar slides out of the speed, not without it.
  func update(status: NoGpsStatus, speedShown: Bool) {
    guard !isCelebrating else { return }
    guard speedShown, Self.isShown(status) else {
      close()
      return
    }
    let texts = Self.texts(status)
    apply(texts)
    bar.backgroundColor = Constants.accent
    for (i, segment) in segments.enumerated() {
      let measured = Self.isMeasured(status, i)
      let carM = i < status.gpsSpeedTableCarM.count ? status.gpsSpeedTableCarM[i].doubleValue : 0
      let current = i == status.speedHintRange && !measured
      segment.set(fraction: measured ? 1 : min(1, carM / Constants.minDistanceM), outlined: current,
                  pulsing: current && status.speedHintGps, gold: false)
    }
    open()
  }

  private func apply(_ texts: Texts) {
    noGpsIcon.isHidden = !texts.noGps
    title.text = texts.title
    left.text = texts.left
    left.isHidden = texts.left == nil
    subtitle.text = texts.subtitle
    accessibilityLabel = [texts.title, texts.left, texts.subtitle].compactMap { $0 }.joined(separator: ". ")
  }

  private func open() {
    guard !isOpen else { return }
    isOpen = true
    isHidden = false
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
  }

  private func close() {
    guard isOpen else { return }
    isOpen = false
    widthConstraint.constant = 0
    UIView.animate(withDuration: 0.14) { self.content.alpha = 0 }
    UIView.animate(withDuration: Constants.closeDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState],
                   animations: { self.superview?.layoutIfNeeded() },
                   completion: { _ in
                     if !self.isOpen {
                       self.isHidden = true
                       self.star.isHidden = true
                     }
                   })
  }

  private static var direction: CGFloat {
    UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? -1 : 1
  }

  // MARK: - Celebration

  /// GPS has measured the range of the status: the bar turns green with a star, the segment pops gold, confetti bursts
  /// from the bar and a ring from the speed. A milestone rains confetti over the map for longer.
  /// \param speed the speed view, the ring goes out of it.
  func celebrate(status: NoGpsStatus, speed: UIView) {
    guard !NoGpsBoxPage.needsCalibration(status) else { return }
    let milestone = status.speedMilestone != .range
    let duration = milestone ? Constants.milestoneDuration : Constants.celebrationDuration
    celebrationEnd = Date().addingTimeInterval(duration)
    celebrationTimer?.invalidate()
    celebrationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
      self?.celebrationEnd = nil
      self?.close()
    }

    let texts = Self.celebrationTexts(status)
    apply(texts)
    noGpsIcon.isHidden = true
    for (i, segment) in segments.enumerated() {
      let measured = Self.isMeasured(status, i)
      segment.set(fraction: measured ? 1 : 0, outlined: false, pulsing: false, gold: i == status.speedHintRange)
    }
    open()
    content.alpha = 1
    content.transform = .identity

    UINotificationFeedbackGenerator().notificationOccurred(.success)
    flash.alpha = 0.85
    UIView.animate(withDuration: 0.52, delay: 0, options: [.curveEaseOut]) { self.flash.alpha = 0 }
    UIView.animate(withDuration: 0.25) { self.bar.backgroundColor = Constants.done }
    star.isHidden = false
    star.transform = CGAffineTransform(scaleX: 0.01, y: 0.01).rotated(by: -2.4)
    UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.8,
                   animations: { self.star.transform = .identity })
    for view in [title, subtitle] {
      view.alpha = 0
      view.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.85, y: 0.85)
    }
    UIView.animate(withDuration: 0.48, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.5,
                   animations: { self.title.alpha = 1
                     self.title.transform = .identity
                   })
    UIView.animate(withDuration: 0.48, delay: 0.09, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.5,
                   animations: { self.subtitle.alpha = 1
                     self.subtitle.transform = .identity
                   })
    if status.speedHintRange < segments.count {
      segments[status.speedHintRange].pop()
    }
    ring(around: speed)
    burstConfetti()
    if milestone {
      rainConfetti()
    }
  }

  private func ring(around speed: UIView) {
    guard let host = superview else { return }
    let frame = speed.convert(speed.bounds, to: host)
    let ring = CAShapeLayer()
    ring.frame = frame
    ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: frame.size)).cgPath
    ring.fillColor = nil
    ring.strokeColor = Constants.gold.cgColor
    ring.lineWidth = 3
    ring.opacity = 0
    host.layer.addSublayer(ring)
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1
    scale.toValue = 2
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = 0.9
    group.repeatCount = 2
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ring.add(group, forKey: "ring")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { ring.removeFromSuperlayer() }
  }

  static func confettiCells(velocity: CGFloat, birthRate: Float, lifetime: Float) -> [CAEmitterCell] {
    Constants.confettiColors.map { color in
      let cell = CAEmitterCell()
      cell.contents = confettiImage.cgImage
      cell.color = color.cgColor
      cell.birthRate = birthRate
      cell.lifetime = lifetime
      cell.velocity = velocity
      cell.velocityRange = velocity / 2
      cell.yAcceleration = 300
      cell.spin = 4
      cell.spinRange = 8
      cell.scale = 1
      cell.scaleRange = 0.4
      cell.alphaSpeed = -1 / lifetime
      return cell
    }
  }

  private static let confettiImage = UIGraphicsImageRenderer(size: CGSize(width: 7, height: 11)).image { _ in
    UIColor.white.setFill()
    UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 7, height: 11), cornerRadius: 2).fill()
  }

  /// From the top of the bar, up and falling back.
  private func burstConfetti() {
    guard let host = superview else { return }
    let emitter = CAEmitterLayer()
    let frame = convert(bounds, to: host)
    emitter.emitterPosition = CGPoint(x: frame.minX + min(frame.width, 260) / 2 + 30, y: frame.minY)
    emitter.emitterSize = CGSize(width: min(frame.width, 260), height: 1)
    emitter.emitterShape = .line
    let cells = Self.confettiCells(velocity: 260, birthRate: 12, lifetime: 1.4)
    for cell in cells {
      cell.emissionLongitude = -.pi / 2
      cell.emissionRange = .pi / 3
    }
    emitter.emitterCells = cells
    emit(emitter, in: host, for: 0.3, lifetime: 1.4)
  }

  /// Over the whole map from its top.
  private func rainConfetti() {
    guard let host = superview else { return }
    let emitter = CAEmitterLayer()
    emitter.emitterPosition = CGPoint(x: host.bounds.midX, y: -16)
    emitter.emitterSize = CGSize(width: host.bounds.width, height: 1)
    emitter.emitterShape = .line
    let lifetime = Float(host.bounds.height / 260) + 0.5
    let cells = Self.confettiCells(velocity: 60, birthRate: 6, lifetime: lifetime)
    for cell in cells {
      cell.emissionLongitude = .pi / 2
      cell.emissionRange = .pi / 8
      cell.yAcceleration = 120
      cell.alphaSpeed = 0
    }
    emitter.emitterCells = cells
    emit(emitter, in: host, for: 1.6, lifetime: TimeInterval(lifetime))
  }

  private func emit(_ emitter: CAEmitterLayer, in host: UIView, for seconds: TimeInterval, lifetime: TimeInterval) {
    emitter.beginTime = CACurrentMediaTime()
    host.layer.addSublayer(emitter)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { emitter.birthRate = 0 }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + lifetime) { emitter.removeFromSuperlayer() }
  }
}

/// A range of the speed table in the bar: filled as GPS has measured it.
private final class Segment: UIView {
  private let fill = CALayer()
  private var fraction = CGFloat(0)

  init() {
    super.init(frame: .zero)
    backgroundColor = UIColor.white.withAlphaComponent(0.3)
    layer.cornerRadius = NoGpsSpeedHintView.Constants.segmentHeight / 2
    layer.borderColor = UIColor.white.cgColor
    fill.backgroundColor = UIColor.white.cgColor
    fill.cornerRadius = layer.cornerRadius
    layer.addSublayer(fill)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func set(fraction: Double, outlined: Bool, pulsing: Bool, gold: Bool) {
    self.fraction = CGFloat(fraction)
    layer.borderWidth = outlined ? 1.5 : 0
    fill.backgroundColor = (gold ? NoGpsSpeedHintView.Constants.gold : UIColor.white).cgColor
    if pulsing, fill.animation(forKey: "pulse") == nil {
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 1
      pulse.toValue = 0.5
      pulse.duration = 0.5
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      fill.add(pulse, forKey: "pulse")
    } else if !pulsing {
      fill.removeAnimation(forKey: "pulse")
    }
    setNeedsLayout()
  }

  func pop() {
    transform = .identity
    UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseOut],
                   animations: { self.transform = CGAffineTransform(scaleX: 1.6, y: 2.6) },
                   completion: { _ in
                     UIView.animate(withDuration: 0.39, delay: 0, usingSpringWithDamping: 0.5,
                                    initialSpringVelocity: 0, animations: { self.transform = .identity })
                   })
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let width = bounds.width * fraction
    let leading = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - width : 0
    fill.frame = CGRect(x: leading, y: 0, width: width, height: bounds.height)
    CATransaction.commit()
  }
}
