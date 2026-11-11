/// The middle of the bottom bar: one button with the look of what moves the mark, the source word and the accuracy. A
/// badge tells about the other source. The button opens the Box sheet with the box and GPS.
final class NoGpsStatusBar: UIView {
  private enum Constants {
    static let gpsSymbol = "antenna.radiowaves.left.and.right"
    static let boxSymbol = "cpu"
  }

  /// GPS moves the mark.
  static let goodColor = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255, alpha: 1)
    : UIColor(red: 0x1E / 255, green: 0x8E / 255, blue: 0x3E / 255, alpha: 1)
  }

  /// The box moves the mark.
  static let inertialColor = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255, alpha: 1)
    : UIColor(red: 0x8E / 255, green: 0x44 / 255, blue: 0xC4 / 255, alpha: 1)
  }

  /// How a state is drawn: the icon, its color, a badge and if it pulses while something is in progress. A badge
  /// without a symbol is a dot.
  struct Look {
    let image: UIImage?
    let color: UIColor
    var badge: (symbol: String?, color: UIColor)?
    var pulsing = false
  }

  private weak static var shared: NoGpsStatusBar?
  /// The tile of the navigation sheet, it is shown while the bar is hidden.
  weak static var navTile: NavButton?

  private let button = NavButton(style: .bar)

  init() {
    super.init(frame: .zero)
    Self.shared = self
    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    button.show(NoGps.status())
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static func update(_ status: NoGpsStatus) {
    shared?.button.show(status)
    navTile?.show(status)
  }

  /// Where the position comes from: the box when the car follows it, or when the mark is set by hand with a box set up,
  /// else GPS.
  static func navShowsBox(source: NoGpsPositionSource, inertialEnabled: Bool) -> Bool {
    switch source {
    case .inertial: return true
    case .manual: return inertialEnabled
    case .gps, .network, .none: return false
    @unknown default: return false
    }
  }

  /// The look of the navigation button: of the source that moves the mark, with one badge. Its own badge comes first,
  /// then "+" without a box, then a dot in the color of the other source when that one is wrong.
  static func barLook(_ status: NoGpsStatus) -> Look {
    let isBox = navShowsBox(source: status.source, inertialEnabled: status.inertialEnabled)
    var look = isBox ? boxLook(status) : gpsLook(status)
    guard look.badge == nil else { return look }
    if !status.inertialEnabled {
      look.badge = ("plus", .systemBlue)
    } else {
      let other = isBox ? gpsLook(status) : boxLook(status)
      if other.color == .systemOrange || other.color == .systemRed {
        look.badge = (nil, other.color)
      }
    }
    return look
  }

  static func showNavSheet() {
    NoGpsBoxSheet.show()
  }

  /// The background of the buttons of the bar, Search and Menu too.
  static func styleButton(_ button: UIView) {
    button.backgroundColor = .tertiarySystemFill
    button.layer.cornerRadius = 12
    button.layer.cornerCurve = .continuous
  }

  /// The background of a look: its color, faint.
  static func tint(_ color: UIColor) -> UIColor {
    UIColor { color.resolvedColor(with: $0).withAlphaComponent($0.userInterfaceStyle == .dark ? 0.24 : 0.16) }
  }

  /// The icon of a look on its tinted square, for the rows of the sheets.
  static func tileImage(_ look: Look, side: CGFloat, traits: UITraitCollection) -> UIImage {
    let size = CGSize(width: side, height: side)
    return UIGraphicsImageRenderer(size: size).image { _ in
      tint(look.color).resolvedColor(with: traits).setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: side / 4).fill()
      guard let image = look.image else { return }
      let iconSide = side * 0.6
      let icon = image.withTintColor(look.color.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
      let scale = min(iconSide / icon.size.width, iconSide / icon.size.height)
      let iconSize = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
      icon.draw(in: CGRect(x: (side - iconSize.width) / 2, y: (side - iconSize.height) / 2, width: iconSize.width,
                           height: iconSize.height))
    }
  }

  static func sourceText(_ status: NoGpsStatus) -> (word: String, accuracy: String?) {
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
    var look: Look
    switch status.gpsState {
    case .good: look = Look(image: antenna, color: goodColor)
    case .checking: look = Look(image: antenna, color: .systemBlue, pulsing: true)
    case .coarse: look = Look(image: antenna, color: .systemOrange)
    case .spoofed: look = Look(image: antenna, color: .systemOrange, badge: ("exclamationmark", .systemOrange))
    case .none: look = Look(image: slashed, color: .systemRed)
    @unknown default: look = Look(image: slashed, color: .systemRed)
    }
    // The car doesn't follow GPS: the badge tells it, the color still tells the signal.
    if status.gpsDisabled, look.badge == nil {
      look.badge = ("pause.fill", .systemGray)
    }
    return look
  }

  static func boxLook(_ status: NoGpsStatus) -> Look {
    let chip = UIImage(systemName: Constants.boxSymbol)
    // No box: the button calls to set one up or to buy it.
    guard status.inertialEnabled else { return Look(image: chip, color: .secondaryLabel, badge: ("plus", .systemBlue)) }
    switch status.sourceState {
    case .connected: return Look(image: chip, color: inertialColor)
    case .updating: return Look(image: chip, color: .systemBlue, badge: ("arrow.down", .systemBlue), pulsing: true)
    case .boxSleeping:
      // The box is away or its radio is off: the phone keeps looking for it.
      var look = boxSearchLook(status)
      if look.pulsing {
        look.badge = ("moon.fill", .systemGray)
      }
      return look
    case .obdSleeping: return Look(image: chip, color: .secondaryLabel, badge: ("moon.fill", .systemGray))
    case .noCarData, .obdDisabled, .obdConnecting, .obdError, .noAdapter:
      return Look(image: chip, color: .systemOrange, badge: ("exclamationmark", .systemOrange))
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
  private func buttonTapped() {
    Self.showNavSheet()
  }
}

/// The navigation button: the icon of the source that moves the mark with a badge, on the tint of its color. In the
/// bottom bar it also has the source word, the accuracy and a chevron, as a tile in the navigation sheet only the
/// accuracy under the icon.
final class NavButton: UIControl {
  enum Style {
    case bar
    case tile
  }

  private enum Constants {
    static let iconSize = CGFloat(24)
    static let dotSize = CGFloat(11)
    static let badgeSize = CGFloat(14)
    static let badgeSymbol = UIImage.SymbolConfiguration(pointSize: 8, weight: .black)
    static let cornerRadius = CGFloat(14)
    static let barHeight = CGFloat(48)
    static let tileSide = CGFloat(56)
    static let pulseKey = "pulse"
    static let pulseDuration: CFTimeInterval = 0.7
    static let pulseOpacity = Float(0.3)
    /// The word shrinks to fit, but stays readable.
    static let minScale = CGFloat(0.75)
  }

  private let style: Style
  private let icon = UIImageView()
  private let badge = UIImageView()
  private var badgeWidth = NSLayoutConstraint()
  private var badgeHeight = NSLayoutConstraint()
  private let word = UILabel()
  private let accuracy = UILabel()

  init(style: Style) {
    self.style = style
    super.init(frame: .zero)
    isAccessibilityElement = true
    accessibilityTraits = .button
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = Constants.cornerRadius
    layer.cornerCurve = .continuous
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.5 : 1 }
  }

  private func setupViews() {
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    badge.contentMode = .center
    badge.tintColor = .white
    badge.clipsToBounds = true
    badge.isHidden = true
    badge.translatesAutoresizingMaskIntoConstraints = false
    icon.addSubview(badge)
    badgeWidth = badge.widthAnchor.constraint(equalToConstant: Constants.dotSize)
    badgeHeight = badge.heightAnchor.constraint(equalToConstant: Constants.dotSize)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: Constants.iconSize),
      icon.heightAnchor.constraint(equalToConstant: Constants.iconSize),
      badgeWidth,
      badgeHeight,
      badge.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -1),
      badge.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 1),
    ])

    accuracy.font = .monospacedDigitSystemFont(ofSize: style == .bar ? 13 : 12, weight: style == .bar ? .regular
      : .semibold)
    accuracy.textColor = .secondaryLabel
    accuracy.adjustsFontSizeToFitWidth = true
    accuracy.minimumScaleFactor = Constants.minScale

    let content: UIStackView
    switch style {
    case .bar:
      word.font = .systemFont(ofSize: 15, weight: .semibold)
      word.textColor = .label
      word.adjustsFontSizeToFitWidth = true
      word.minimumScaleFactor = Constants.minScale
      word.baselineAdjustment = .alignCenters
      let text = UIStackView(arrangedSubviews: [word, accuracy])
      text.axis = .vertical
      text.alignment = .leading
      text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let chevron = UIImageView(image: UIImage(systemName: "chevron.up",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 12,
                                                                                              weight: .bold)))
      chevron.tintColor = .secondaryLabel
      chevron.setContentHuggingPriority(.required, for: .horizontal)
      content = UIStackView(arrangedSubviews: [icon, text, chevron])
      content.axis = .horizontal
      content.alignment = .center
      content.spacing = 10
      heightAnchor.constraint(equalToConstant: Constants.barHeight).isActive = true
    case .tile:
      accuracy.textColor = .label
      content = UIStackView(arrangedSubviews: [icon, accuracy])
      content.axis = .vertical
      content.alignment = .center
      content.spacing = 3
      NSLayoutConstraint.activate([
        widthAnchor.constraint(equalToConstant: Constants.tileSide),
        heightAnchor.constraint(equalToConstant: Constants.tileSide),
      ])
    }
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    let inset = style == .bar ? UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
      : UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func show(_ status: NoGpsStatus) {
    let look = NoGpsStatusBar.barLook(status)
    backgroundColor = NoGpsStatusBar.tint(look.color)
    icon.image = look.image
    icon.tintColor = look.color
    badge.isHidden = look.badge == nil
    if let badgeLook = look.badge {
      let side = badgeLook.symbol == nil ? Constants.dotSize : Constants.badgeSize
      badgeWidth.constant = side
      badgeHeight.constant = side
      badge.layer.cornerRadius = side / 2
      badge.image = badgeLook.symbol.flatMap { UIImage(systemName: $0, withConfiguration: Constants.badgeSymbol) }
      badge.backgroundColor = badgeLook.color
    }
    Self.pulse(icon.layer, look.pulsing)

    let source = NoGpsStatusBar.sourceText(status)
    word.text = source.word
    accuracy.text = source.accuracy
    accuracy.isHidden = source.accuracy == nil && style == .bar
    accessibilityLabel = [source.word, source.accuracy].compactMap { $0 }.joined(separator: " ")
    // The states of both sources: the badge tells about the other one.
    var states = [NoGpsStatusBar.gpsStateText(status)]
    if status.gpsDisabled, let why = NoGpsStatusBar.gpsWhyText(status) {
      states.append(why)
    }
    if status.inertialEnabled {
      states.append(NoGpsSensorsViewController.boxStateText(status))
    }
    accessibilityValue = states.joined(separator: ". ")
  }

  /// Also the tiles of the Box sheet.
  static func pulse(_ layer: CALayer, _ on: Bool) {
    // The system removes the animation in the background, the next update adds it again.
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
