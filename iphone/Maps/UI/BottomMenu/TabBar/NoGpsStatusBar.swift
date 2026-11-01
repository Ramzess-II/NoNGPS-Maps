/// The middle of the bottom bar: the sensor box, where the position of the car comes from with its accuracy, and GPS.
/// The box and GPS show their state by the shape and the color of the icon, and open their sheets.
final class NoGpsStatusBar: UIView {
  private enum Constants {
    static let buttonSize = CGFloat(48)
    static let spacing = CGFloat(4)
    // The word shrinks to fit, but stays readable.
    static let minScale = CGFloat(0.75)
    static let gpsSymbol = "antenna.radiowaves.left.and.right"
    static let boxSymbol = "cpu"
    static let goodColor = UIColor { $0.userInterfaceStyle == .dark
      ? UIColor(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255, alpha: 1)
      : UIColor(red: 0x1E / 255, green: 0x8E / 255, blue: 0x3E / 255, alpha: 1)
    }
  }

  /// How a state is drawn: the icon, its color, a badge and if it pulses while something is in progress.
  struct Look {
    let image: UIImage?
    let color: UIColor
    var badge: (symbol: String, color: UIColor)?
    var pulsing = false
  }

  private weak static var shared: NoGpsStatusBar?

  private let box = StateButton()
  private let word = UILabel()
  private let accuracy = UILabel()
  private let text = UIStackView()
  private let gps = StateButton()

  init() {
    super.init(frame: .zero)
    Self.shared = self
    setupViews()
    apply(NoGps.status())
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static func update(_ status: NoGpsStatus) {
    shared?.apply(status)
  }

  /// The background of the buttons of the bar, Search and Menu too.
  static func styleButton(_ button: UIView) {
    button.backgroundColor = .tertiarySystemFill
    button.layer.cornerRadius = 12
    button.layer.cornerCurve = .continuous
  }

  // MARK: - Views

  private func setupViews() {
    word.font = .systemFont(ofSize: 15, weight: .semibold)
    word.textColor = .label
    word.textAlignment = .center
    word.adjustsFontSizeToFitWidth = true
    word.minimumScaleFactor = Constants.minScale
    word.baselineAdjustment = .alignCenters
    accuracy.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    accuracy.textColor = .secondaryLabel
    accuracy.textAlignment = .center
    accuracy.adjustsFontSizeToFitWidth = true
    accuracy.minimumScaleFactor = Constants.minScale
    text.addArrangedSubview(word)
    text.addArrangedSubview(accuracy)
    text.axis = .vertical
    text.alignment = .fill
    text.isAccessibilityElement = true
    text.accessibilityTraits = .staticText
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    box.accessibilityLabel = L("nogps_box_title")
    gps.accessibilityLabel = L("nogps_status_gps")
    for button in [box, gps] {
      Self.styleButton(button)
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: Constants.buttonSize),
        button.heightAnchor.constraint(equalToConstant: Constants.buttonSize),
      ])
    }
    box.addTarget(self, action: #selector(boxTapped), for: .touchUpInside)
    gps.addTarget(self, action: #selector(gpsTapped), for: .touchUpInside)

    let row = UIStackView(arrangedSubviews: [box, text, gps])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = Constants.spacing
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - State

  private func apply(_ status: NoGpsStatus) {
    let source = Self.sourceText(status)
    word.text = source.word
    accuracy.text = source.accuracy
    accuracy.isHidden = source.accuracy == nil
    text.accessibilityLabel = [source.word, source.accuracy].compactMap { $0 }.joined(separator: " ")
    box.show(Self.boxLook(status))
    box.accessibilityValue = status.inertialEnabled ? NoGpsSensorsViewController.boxStateText(status) : nil
    gps.show(Self.gpsLook(status))
    gps.accessibilityValue = Self.gpsStateText(status)
  }

  private static func sourceText(_ status: NoGpsStatus) -> (word: String, accuracy: String?) {
    let word: String
    switch status.source {
    case .gps: word = L("nogps_status_gps")
    case .network: word = L("nogps_bar_network")
    case .manual: word = L("nogps_bar_manual")
    case .inertial: word = L("nogps_bar_inertial")
    case .none: return ("—", nil)
    @unknown default: return ("—", nil)
    }
    return (word, "±" + NoGpsControls.formatAccuracy(status.accuracyM))
  }

  static func gpsLook(_ status: NoGpsStatus) -> Look {
    let antenna = UIImage(systemName: Constants.gpsSymbol)
    let slashed = UIImage(systemName: Constants.gpsSymbol + ".slash") ?? antenna
    if LocationManager.isLocationProhibited() {
      return Look(image: slashed, color: .secondaryLabel)
    }
    let look: Look
    switch status.gpsState {
    case .good: look = Look(image: antenna, color: Constants.goodColor)
    case .checking: look = Look(image: antenna, color: .systemBlue, pulsing: true)
    case .coarse: look = Look(image: antenna, color: .systemOrange)
    case .spoofed: look = Look(image: antenna, color: .systemOrange, badge: ("exclamationmark", .systemOrange))
    case .none: look = Look(image: slashed, color: .systemRed)
    @unknown default: look = Look(image: slashed, color: .systemRed)
    }
    // The car doesn't follow GPS: its signal is told by the shape only.
    return status.gpsDisabled ? Look(image: look.image, color: .secondaryLabel, badge: look.badge) : look
  }

  static func boxLook(_ status: NoGpsStatus) -> Look {
    let chip = UIImage(systemName: Constants.boxSymbol)
    guard status.inertialEnabled else { return Look(image: chip, color: .secondaryLabel) }
    switch status.sourceState {
    case .connected: return Look(image: chip, color: Constants.goodColor)
    case .updating: return Look(image: chip, color: .systemBlue, badge: ("arrow.down", .systemBlue), pulsing: true)
    case .boxSleeping, .obdSleeping: return Look(image: chip, color: .secondaryLabel, badge: ("moon.fill", .systemGray))
    case .noCarData, .obdDisabled, .obdConnecting, .obdError, .noAdapter:
      return Look(image: chip, color: .label, badge: ("exclamationmark", .systemOrange))
    case .disconnected, .connecting: return boxSearchLook(status)
    @unknown default: return boxSearchLook(status)
    }
  }

  /// The box is not heard yet: the phone looks for it by Bluetooth, then waits for its data.
  private static func boxSearchLook(_ status: NoGpsStatus) -> Look {
    switch status.bleState {
    case .connected: return Look(image: UIImage(systemName: Constants.boxSymbol), color: .systemBlue, pulsing: true)
    case .off, .noPermission, .disabled:
      return Look(image: UIImage(resource: .icNogpsBluetoothOff), color: .secondaryLabel)
    case .searching, .pairingClosed, .connecting, .pairing:
      return Look(image: UIImage(resource: .icNogpsBluetooth), color: .systemBlue, pulsing: true)
    @unknown default: return Look(image: UIImage(resource: .icNogpsBluetooth), color: .systemBlue, pulsing: true)
    }
  }

  static func gpsStateText(_ status: NoGpsStatus) -> String {
    if LocationManager.isLocationProhibited() {
      return L("nogps_status_gps_off")
    }
    switch status.gpsState {
    case .good: return L("nogps_gps_state_good")
    case .checking: return L("nogps_gps_state_checking")
    case .coarse: return L("nogps_gps_state_coarse")
    case .spoofed: return L("nogps_gps_state_spoofed")
    case .none: return L("nogps_gps_state_none")
    @unknown default: return L("nogps_gps_state_none")
    }
  }

  /// Why GPS is in its state, and if the car follows it.
  static func gpsWhyText(_ status: NoGpsStatus) -> String? {
    if LocationManager.isLocationProhibited() {
      return nil
    }
    if status.gpsDisabled {
      return L("nogps_gps_why_ignored")
    }
    switch status.gpsState {
    case .good: return L("nogps_gps_why_used")
    // Good positions are checked in the manual mode, the satellites are searched after the start.
    case .checking: return L(status.manualMode ? "nogps_gps_why_checking" : "nogps_gps_why_searching")
    case .coarse:
      return L(status.workingNetworkAccuracyM >= 0 && status.workingGpsAccuracyM < 0 ? "nogps_gps_why_network"
        : "nogps_gps_why_coarse")
    case .spoofed: return L("nogps_gps_why_spoofed")
    case .none: return L("nogps_gps_why_none")
    @unknown default: return nil
    }
  }

  // MARK: - Actions

  @objc
  private func gpsTapped() {
    NoGpsGpsSheet.show()
  }

  @objc
  private func boxTapped() {
    NoGpsBoxSheet.show()
  }
}

/// A button of the bar showing a state: its icon with a badge.
final class StateButton: UIControl {
  private enum Constants {
    static let iconSize = CGFloat(24)
    static let badgeSize = CGFloat(11)
    static let pulseKey = "pulse"
    static let pulseDuration: CFTimeInterval = 0.7
    static let pulseOpacity = Float(0.3)
    static let badgeSymbol = UIImage.SymbolConfiguration(pointSize: 7, weight: .black)
  }

  private let icon = UIImageView()
  private let badge = UIImageView()

  init() {
    super.init(frame: .zero)
    isAccessibilityElement = true
    accessibilityTraits = .button
    translatesAutoresizingMaskIntoConstraints = false

    icon.contentMode = .scaleAspectFit
    icon.isUserInteractionEnabled = false
    icon.translatesAutoresizingMaskIntoConstraints = false
    badge.contentMode = .center
    badge.tintColor = .white
    badge.layer.cornerRadius = Constants.badgeSize / 2
    badge.clipsToBounds = true
    badge.isHidden = true
    badge.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)
    icon.addSubview(badge)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: Constants.iconSize),
      icon.heightAnchor.constraint(equalToConstant: Constants.iconSize),
      icon.centerXAnchor.constraint(equalTo: centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      badge.widthAnchor.constraint(equalToConstant: Constants.badgeSize),
      badge.heightAnchor.constraint(equalToConstant: Constants.badgeSize),
      badge.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -2),
      badge.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -2),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.5 : 1 }
  }

  func show(_ look: NoGpsStatusBar.Look) {
    icon.image = look.image
    icon.tintColor = look.color
    badge.isHidden = look.badge == nil
    if let badgeLook = look.badge {
      badge.image = UIImage(systemName: badgeLook.symbol, withConfiguration: Constants.badgeSymbol)
      badge.backgroundColor = badgeLook.color
    }
    pulse(look.pulsing)
  }

  private func pulse(_ on: Bool) {
    // The system removes the animation in the background, the next update adds it again.
    let layer = icon.layer
    guard on != (layer.animation(forKey: Constants.pulseKey) != nil) else { return }
    guard on else {
      layer.removeAnimation(forKey: Constants.pulseKey)
      return
    }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = Constants.pulseOpacity
    animation.duration = Constants.pulseDuration
    animation.autoreverses = true
    animation.repeatCount = .infinity
    layer.add(animation, forKey: Constants.pulseKey)
  }
}
