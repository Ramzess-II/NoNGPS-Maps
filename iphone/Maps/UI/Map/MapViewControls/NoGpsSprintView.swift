/// The texts of the timed runs from a standing start, on the card on the map and in the Box sheet.
enum NoGpsSprintText {
  /// What the card says. Not a record: only `main`. A record: `kind` small, `main` big, `was` small.
  struct Card: Equatable {
    var kind: String?
    var main: String
    var was: String?
    var isRecord: Bool
  }

  private static let separator = " · "

  static func kindTitle(_ kind: NoGpsSprintKind) -> String {
    kind == .to100 ? L("nogps_sprint_to100") : L("nogps_sprint_quarter_mile")
  }

  /// The trap speed is told for the quarter mile only.
  private static func titleWithTrap(_ kind: NoGpsSprintKind, trapKmh: Int) -> String {
    kind == .quarterMile ? [kindTitle(kind), speed(trapKmh)].joined(separator: separator) : kindTitle(kind)
  }

  private static func speed(_ kmh: Int) -> String {
    String(format: L("nogps_speed_kmh"), kmh)
  }

  static func seconds(_ sec: Double, decimals: Int, locale: Locale = .current) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = decimals
    formatter.maximumFractionDigits = decimals
    formatter.usesGroupingSeparator = false
    return String(format: L("nogps_sprint_seconds"), formatter.string(from: NSNumber(value: sec)) ?? "")
  }

  /// A time with its trap speed as the best one and the list tell it: "15.21 s · 142 km/h".
  static func result(kind: NoGpsSprintKind, sec: Double, trapKmh: Int, locale: Locale = .current) -> String {
    var parts = [seconds(sec, decimals: 2, locale: locale)]
    if kind == .quarterMile {
      parts.append(speed(trapKmh))
    }
    return parts.joined(separator: separator)
  }

  /// - Parameter bestSec: the best time of the kind before this result, 0 for none.
  static func card(kind: NoGpsSprintKind, sec: Double, trapKmh: Int, bestSec: Double, record: Bool,
                   locale: Locale = .current) -> Card {
    guard record else {
      var parts = [kindTitle(kind), seconds(sec, decimals: 1, locale: locale)]
      if kind == .quarterMile {
        parts.append(speed(trapKmh))
      }
      return Card(kind: nil, main: parts.joined(separator: separator), was: nil, isRecord: false)
    }
    // A record by a hundredth would read "8.4 s, was 8.4 s": both get the hundredths then.
    let hasBest = bestSec > 0
    let tie = hasBest && seconds(sec, decimals: 1, locale: locale) == seconds(bestSec, decimals: 1, locale: locale)
    let decimals = tie ? 2 : 1
    return Card(kind: titleWithTrap(kind, trapKmh: trapKmh),
                main: L("nogps_sprint_record") + " " + seconds(sec, decimals: decimals, locale: locale),
                was: hasBest ? String(format: L("nogps_sprint_was"), seconds(bestSec, decimals: decimals, locale: locale))
                  : nil,
                isRecord: true)
  }

  static func card(_ status: NoGpsStatus, locale: Locale = .current) -> Card {
    card(kind: status.sprintKind, sec: status.sprintSec, trapKmh: status.sprintTrapKmh,
         bestSec: status.sprintBestSec, record: status.sprintRecord, locale: locale)
  }

  /// The results of the kind, in the order they come: newest first.
  static func results(of kind: NoGpsSprintKind, in sprints: [NoGpsSprint]) -> [NoGpsSprint] {
    sprints.filter { $0.kind == kind }
  }

  /// The fastest one, the older of equal times.
  static func best(of kind: NoGpsSprintKind, in sprints: [NoGpsSprint]) -> NoGpsSprint? {
    results(of: kind, in: sprints).reversed().min { $0.sec < $1.sec }
  }

  /// The best time of the kind for the row of the car, "—" for none.
  static func bestText(of kind: NoGpsSprintKind, in sprints: [NoGpsSprint], locale: Locale = .current) -> String {
    guard let best = best(of: kind, in: sprints) else { return L("nogps_unknown") }
    return result(kind: kind, sec: best.sec, trapKmh: best.trapKmh, locale: locale)
  }

  static func dateText(_ date: Date, locale: Locale = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

/// The card on the map with the result of a timed run: one line, or for a record the kind, the time big and the old
/// time, with confetti. It hides by itself, a tap hides it at once.
final class NoGpsSprintView: UIControl {
  enum Constants {
    static let showSeconds: TimeInterval = 5
    static let recordSeconds: TimeInterval = 8
    static let maxWidth = CGFloat(340)
    static let cornerRadius = CGFloat(16)
    static let insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    static let gold = NoGpsSpeedHintView.Constants.gold
    static let accent = NoGpsSpeedHintView.Constants.accent
  }

  private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
  private let kindLabel = UILabel()
  private let mainLabel = UILabel()
  private let wasLabel = UILabel()
  private let stack = UIStackView()
  private var widthLimit = NSLayoutConstraint()
  private var hideTimer: Timer?
  /// A hide that was started before a new result is not finished.
  private var generation = 0

  init() {
    super.init(frame: .zero)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true
    isAccessibilityElement = true
    accessibilityTraits = [.button, .staticText]
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.28
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: 2)
    addTarget(self, action: #selector(tapped), for: .touchUpInside)

    background.translatesAutoresizingMaskIntoConstraints = false
    background.isUserInteractionEnabled = false
    background.layer.cornerRadius = Constants.cornerRadius
    background.clipsToBounds = true
    addSubview(background)

    for label in [kindLabel, mainLabel, wasLabel] {
      label.textAlignment = .center
      label.numberOfLines = 0
      label.adjustsFontSizeToFitWidth = true
      label.minimumScaleFactor = 0.7
    }
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 2
    for label in [kindLabel, mainLabel, wasLabel] {
      stack.addArrangedSubview(label)
    }
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.isUserInteractionEnabled = false
    background.contentView.addSubview(stack)

    widthLimit = widthAnchor.constraint(lessThanOrEqualToConstant: Constants.maxWidth)
    NSLayoutConstraint.activate([
      widthLimit,
      background.leadingAnchor.constraint(equalTo: leadingAnchor),
      background.trailingAnchor.constraint(equalTo: trailingAnchor),
      background.topAnchor.constraint(equalTo: topAnchor),
      background.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: Constants.insets.left),
      stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -Constants.insets.right),
      stack.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: Constants.insets.top),
      stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -Constants.insets.bottom),
    ])
  }

  /// The most the card is wide: the free area of the map without the margins.
  func setMaxWidth(_ width: CGFloat) {
    widthLimit.constant = min(Constants.maxWidth, max(0, width))
  }

  /// Shows the result of the status. A card still shown is replaced.
  func show(status: NoGpsStatus) {
    show(NoGpsSprintText.card(status))
  }

  func show(_ card: NoGpsSprintText.Card) {
    generation += 1
    hideTimer?.invalidate()
    layer.removeAllAnimations()

    let onAccent = card.isRecord
    background.contentView.backgroundColor = onAccent ? Constants.accent : nil
    kindLabel.text = card.kind
    kindLabel.isHidden = card.kind == nil
    kindLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    kindLabel.textColor = onAccent ? UIColor.white.withAlphaComponent(0.9) : .secondaryLabel
    mainLabel.text = card.main
    mainLabel.font = card.isRecord ? .monospacedDigitSystemFont(ofSize: 28, weight: .heavy)
      : .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
    mainLabel.textColor = onAccent ? Constants.gold : .label
    wasLabel.text = card.was
    wasLabel.isHidden = card.was == nil
    wasLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    wasLabel.textColor = onAccent ? UIColor.white.withAlphaComponent(0.9) : .secondaryLabel
    accessibilityLabel = [card.kind, card.main, card.was].compactMap { $0 }.joined(separator: ". ")
    if let label = accessibilityLabel {
      UIAccessibility.post(notification: .announcement, argument: label)
    }

    let wasHidden = isHidden
    isHidden = false
    if wasHidden || alpha < 1 {
      alpha = 0
      transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
    }
    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5,
                   options: [.beginFromCurrentState, .allowUserInteraction],
                   animations: {
                     self.alpha = 1
                     self.transform = .identity
                   })
    if card.isRecord {
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      layoutIfNeeded()
      burstConfetti()
    }
    let seconds = card.isRecord ? Constants.recordSeconds : Constants.showSeconds
    hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
  }

  @objc
  private func tapped() {
    hide()
  }

  private func hide() {
    hideTimer?.invalidate()
    hideTimer = nil
    guard !isHidden else { return }
    let current = generation
    UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseIn],
                   animations: { self.alpha = 0 },
                   completion: { _ in
                     if self.generation == current {
                       self.isHidden = true
                     }
                   })
  }

  /// From the top of the card, up and falling back.
  private func burstConfetti() {
    guard let host = superview else { return }
    let emitter = CAEmitterLayer()
    let frame = convert(bounds, to: host)
    emitter.emitterPosition = CGPoint(x: frame.midX, y: frame.minY)
    emitter.emitterSize = CGSize(width: frame.width, height: 1)
    emitter.emitterShape = .line
    let cells = NoGpsSpeedHintView.confettiCells(velocity: 260, birthRate: 14, lifetime: 1.6)
    for cell in cells {
      cell.emissionLongitude = -.pi / 2
      cell.emissionRange = .pi / 3
    }
    emitter.emitterCells = cells
    emitter.beginTime = CACurrentMediaTime()
    host.layer.addSublayer(emitter)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { emitter.birthRate = 0 }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { emitter.removeFromSuperlayer() }
  }
}
