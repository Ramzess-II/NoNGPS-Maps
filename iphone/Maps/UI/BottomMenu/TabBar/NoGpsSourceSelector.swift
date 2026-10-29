/// Chooses where the position of the car comes from: GPS while it is good with the sensor box taking over by itself,
/// or the box alone with GPS ignored. Each segment shows how its source works now, tapping the chosen one tells more.
final class NoGpsSourceSelector: UIView {
  private enum Constants {
    static let height = CGFloat(40)
    static let inset = CGFloat(2)
    static let cornerRadius = CGFloat(11)
    static let thumbCornerRadius = CGFloat(9)
    static let gpsSymbol = "antenna.radiowaves.left.and.right"
    static let boxSymbol = "cpu"
    static let goodColor = UIColor { $0.userInterfaceStyle == .dark
      ? UIColor(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255, alpha: 1)
      : UIColor(red: 0x1E / 255, green: 0x8E / 255, blue: 0x3E / 255, alpha: 1)
    }

    static let thumbColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.39, alpha: 1) : .white }
  }

  private weak static var shared: NoGpsSourceSelector?

  private let thumb = UIView()
  private let segments = UIStackView()
  private let gps = Segment(title: L("nogps_status_gps"))
  private let box = Segment(title: L("nogps_source_box"))
  private var status = NoGps.status()

  init() {
    super.init(frame: .zero)
    Self.shared = self
    setupViews()
    apply(status)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static func update(_ status: NoGpsStatus) {
    shared?.apply(status)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The segments are laid out by the stack view, the thumb takes the place of the chosen one.
    segments.layoutIfNeeded()
    let chosen = gps.isChosen ? gps : box
    thumb.frame = segments.convert(chosen.frame, to: self)
  }

  // MARK: - Views

  private func setupViews() {
    backgroundColor = .tertiarySystemFill
    layer.cornerRadius = Constants.cornerRadius
    layer.cornerCurve = .continuous
    heightAnchor.constraint(equalToConstant: Constants.height).isActive = true

    thumb.backgroundColor = Constants.thumbColor
    thumb.layer.cornerRadius = Constants.thumbCornerRadius
    thumb.layer.cornerCurve = .continuous
    thumb.layer.shadowColor = UIColor.black.cgColor
    thumb.layer.shadowOpacity = 0.15
    thumb.layer.shadowRadius = 2
    thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
    addSubview(thumb)

    segments.axis = .horizontal
    segments.distribution = .fillEqually
    segments.translatesAutoresizingMaskIntoConstraints = false
    segments.addArrangedSubview(gps)
    segments.addArrangedSubview(box)
    addSubview(segments)
    NSLayoutConstraint.activate([
      segments.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.inset),
      segments.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.inset),
      segments.topAnchor.constraint(equalTo: topAnchor, constant: Constants.inset),
      segments.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.inset),
    ])
    gps.addTarget(self, action: #selector(gpsTapped), for: .touchUpInside)
    box.addTarget(self, action: #selector(boxTapped), for: .touchUpInside)
  }

  // MARK: - State

  private func apply(_ status: NoGpsStatus) {
    self.status = status
    let gpsChosen = !status.gpsDisabled
    let moved = gpsChosen != gps.isChosen
    gps.isChosen = gpsChosen
    box.isChosen = !gpsChosen
    applyGps(status)
    applyBox(status)
    if moved, window != nil {
      setNeedsLayout()
      UIView.animate(withDuration: AppConstants.defaultAnimationDuration) { self.layoutIfNeeded() }
    }
  }

  private func applyGps(_ status: NoGpsStatus) {
    gps.accessibilityValue = Self.gpsText(status)
    let antenna = UIImage(systemName: Constants.gpsSymbol)
    if status.gpsSpoofed {
      gps.show(antenna, color: .systemOrange, badge: ("exclamationmark", .systemOrange))
    } else if status.workingGpsAccuracyM >= 0 {
      // Also while it is ignored or not trusted yet.
      gps.show(antenna, color: Constants.goodColor)
    } else {
      gps.show(UIImage(systemName: Constants.gpsSymbol + ".slash") ?? antenna, color: .systemRed)
    }
  }

  private func applyBox(_ status: NoGpsStatus) {
    box.accessibilityValue = status.inertialStarted ? NoGpsSensorsViewController.boxStateText(status) : nil
    let chip = UIImage(systemName: Constants.boxSymbol)
    guard status.inertialEnabled else {
      box.show(chip, color: .secondaryLabel)
      return
    }
    switch status.sourceState {
    case .connected: box.show(chip, color: Constants.goodColor)
    case .updating: box.show(chip, color: .label, badge: ("arrow.down", .systemBlue))
    case .boxSleeping, .obdSleeping: box.show(chip, color: .secondaryLabel, badge: ("moon.fill", .systemGray))
    case .noCarData, .obdDisabled, .obdConnecting, .obdError, .noAdapter:
      box.show(chip, color: .label, badge: ("exclamationmark", .systemOrange))
    case .disconnected, .connecting: showBoxSearch(status)
    @unknown default: showBoxSearch(status)
    }
  }

  /// The box is not heard yet: first the phone looks for it by Bluetooth (red), then waits for its data (blue).
  private func showBoxSearch(_ status: NoGpsStatus) {
    switch status.bleState {
    case .connected: box.show(UIImage(systemName: Constants.boxSymbol), color: .systemBlue, pulsing: true)
    case .off, .noPermission, .disabled: box.show(UIImage(resource: .icNogpsBluetoothOff), color: .secondaryLabel)
    case .searching, .pairingClosed, .connecting, .pairing:
      box.show(UIImage(resource: .icNogpsBluetooth), color: .systemRed, pulsing: true)
    @unknown default: box.show(UIImage(resource: .icNogpsBluetooth), color: .systemRed, pulsing: true)
    }
  }

  private static func gpsText(_ status: NoGpsStatus) -> String {
    if status.gpsSpoofed {
      return L("nogps_status_gps_spoofed")
    }
    guard status.workingGpsAccuracyM >= 0 else { return L("nogps_status_no_gps") }
    return L("nogps_status_gps") + " · ±" + NoGpsControls.formatAccuracy(status.workingGpsAccuracyM)
  }

  // MARK: - Actions

  @objc
  private func gpsTapped() {
    if gps.isChosen {
      Toast.show(withText: Self.gpsText(status))
    } else {
      choose(gpsDisabled: false)
    }
  }

  @objc
  private func boxTapped() {
    // No box is connected: the sensors screen offers to connect one, GPS stays the source.
    guard NoGps.status().inertialEnabled else {
      NoGpsControls.showSensors()
      return
    }
    if !box.isChosen {
      choose(gpsDisabled: true)
      // The box drives the car, nothing to tell.
      if status.sourceState == .connected {
        return
      }
    }
    // The sensors screen tells why the box doesn't drive the car. GPS comes back if the user leaves it unconnected.
    NoGpsControls.showSensors { [weak self] in
      if NoGps.status().sourceState != .connected {
        self?.choose(gpsDisabled: false)
      }
    }
  }

  private func choose(gpsDisabled: Bool) {
    NoGps.setGpsDisabled(gpsDisabled)
    apply(NoGps.status())
  }
}

/// A source: its state icon with a badge and its name.
private final class Segment: UIControl {
  private enum Constants {
    static let iconSize = CGFloat(22)
    static let badgeSize = CGFloat(11)
    static let spacing = CGFloat(6)
    static let pulseKey = "pulse"
    static let pulseDuration: CFTimeInterval = 0.7
    static let pulseOpacity = Float(0.3)
    static let badgeSymbol = UIImage.SymbolConfiguration(pointSize: 7, weight: .black)
  }

  private let icon = UIImageView()
  private let badge = UIImageView()
  private let label = UILabel()

  var isChosen = false {
    didSet {
      label.textColor = isChosen ? .label : .secondaryLabel
      updateTraits()
    }
  }

  init(title: String) {
    super.init(frame: .zero)
    isAccessibilityElement = true
    accessibilityLabel = title

    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    badge.contentMode = .center
    badge.tintColor = .white
    badge.layer.cornerRadius = Constants.badgeSize / 2
    badge.clipsToBounds = true
    badge.isHidden = true
    badge.translatesAutoresizingMaskIntoConstraints = false
    icon.addSubview(badge)

    label.text = title
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.textColor = .secondaryLabel

    let content = UIStackView(arrangedSubviews: [icon, label])
    content.axis = .horizontal
    content.alignment = .center
    content.spacing = Constants.spacing
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: Constants.iconSize),
      icon.heightAnchor.constraint(equalToConstant: Constants.iconSize),
      badge.widthAnchor.constraint(equalToConstant: Constants.badgeSize),
      badge.heightAnchor.constraint(equalToConstant: Constants.badgeSize),
      badge.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -2),
      badge.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -2),
      content.centerXAnchor.constraint(equalTo: centerXAnchor),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
    ])
    updateTraits()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(_ image: UIImage?, color: UIColor, badge badgeLook: (symbol: String, color: UIColor)? = nil,
            pulsing: Bool = false) {
    icon.image = image
    icon.tintColor = color
    badge.isHidden = badgeLook == nil
    if let badgeLook {
      badge.image = UIImage(systemName: badgeLook.symbol, withConfiguration: Constants.badgeSymbol)
      badge.backgroundColor = badgeLook.color
    }
    pulse(pulsing)
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

  private func updateTraits() {
    var traits: UIAccessibilityTraits = .button
    if isChosen {
      traits.insert(.selected)
    }
    accessibilityTraits = traits
  }
}
