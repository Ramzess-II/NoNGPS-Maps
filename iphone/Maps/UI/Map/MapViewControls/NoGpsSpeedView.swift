/// The speed of the car on the map, in and out of navigation, with the speed limit of its road as a road sign. Over the
/// limit the number is red, over the limit of a speed camera ahead in navigation the whole view is.
final class NoGpsSpeedView: UIView {
  static let side = CGFloat(60)

  private enum Constants {
    static let signSide = CGFloat(30)
    static let signOffset = CGFloat(8)
    static let signRing = CGFloat(3.5)
    static let background = UIColor { $0.userInterfaceStyle == .dark
      ? UIColor(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1) : .white
    }
  }

  private let speed = UILabel()
  private let units = UILabel()
  // A road sign: the same in the dark.
  private let sign = UIView()
  private let signLabel = UILabel()

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
    isAccessibilityElement = true
    accessibilityTraits = .updatesFrequently
    layer.cornerRadius = Self.side / 2
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.25
    layer.shadowRadius = 4
    layer.shadowOffset = CGSize(width: 0, height: 2)

    speed.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
    speed.adjustsFontSizeToFitWidth = true
    speed.minimumScaleFactor = 0.6
    speed.textAlignment = .center
    units.font = .systemFont(ofSize: 10, weight: .medium)
    units.adjustsFontSizeToFitWidth = true
    units.minimumScaleFactor = 0.7
    units.textAlignment = .center
    let text = UIStackView(arrangedSubviews: [speed, units])
    text.axis = .vertical
    text.alignment = .center
    text.translatesAutoresizingMaskIntoConstraints = false
    addSubview(text)

    sign.backgroundColor = .white
    sign.layer.cornerRadius = Constants.signSide / 2
    sign.layer.borderWidth = Constants.signRing
    sign.layer.borderColor = UIColor.systemRed.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
    sign.translatesAutoresizingMaskIntoConstraints = false
    signLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    signLabel.textColor = .black
    signLabel.textAlignment = .center
    signLabel.adjustsFontSizeToFitWidth = true
    signLabel.minimumScaleFactor = 0.7
    signLabel.translatesAutoresizingMaskIntoConstraints = false
    sign.addSubview(signLabel)
    addSubview(sign)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.side),
      heightAnchor.constraint(equalToConstant: Self.side),
      text.centerXAnchor.constraint(equalTo: centerXAnchor),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      text.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -10),
      sign.widthAnchor.constraint(equalToConstant: Constants.signSide),
      sign.heightAnchor.constraint(equalToConstant: Constants.signSide),
      sign.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Constants.signOffset),
      sign.topAnchor.constraint(equalTo: topAnchor, constant: -Constants.signOffset),
      signLabel.centerXAnchor.constraint(equalTo: sign.centerXAnchor),
      signLabel.centerYAnchor.constraint(equalTo: sign.centerYAnchor),
      signLabel.widthAnchor.constraint(equalTo: sign.widthAnchor, constant: -2 * Constants.signRing - 2),
    ])
  }

  /// Shows the speed of the position that moves the mark: hidden without one.
  func update(status: NoGpsStatus, location: CLLocation?) {
    guard status.source != .none, let location else {
      isHidden = true
      return
    }
    isHidden = false
    let measure = Measure(asSpeed: max(0, location.speed))
    // Whole numbers, as on Android and in the navigation of Organic Maps: a standing car shows 0, not 0.0.
    let value = Int(measure.value.rounded())
    speed.text = String(value)
    units.text = measure.unit

    // In the units of the speed, compared as shown: 50.4 shown as 50 is not over 50.
    let limit = status.speedLimitKmh > 0 ? Int(Measure(asSpeed: Double(status.speedLimitKmh) / 3.6).value.rounded())
      : nil
    sign.isHidden = status.speedLimitKmh < 0
    signLabel.text = limit.map(String.init) ?? "∞"
    let overLimit = limit.map { value > $0 } ?? false
    let overCamera = MWMRouter.isRoutingActive() && MWMRouter.isSpeedCamLimitExceeded()
    backgroundColor = overCamera ? .systemRed : Constants.background
    speed.textColor = overCamera ? .white : overLimit ? .systemRed : .label
    units.textColor = overCamera ? .white : .secondaryLabel

    accessibilityLabel = String(format: L("nogps_speed_view"), "\(value) " + measure.unit)
    if overCamera {
      accessibilityValue = L("nogps_speed_over_camera")
    } else if let limit {
      accessibilityValue = String(format: L("nogps_speed_limit"), "\(limit) " + measure.unit)
    } else {
      accessibilityValue = status.speedLimitKmh == 0 ? L("nogps_speed_no_limit") : nil
    }
  }
}
