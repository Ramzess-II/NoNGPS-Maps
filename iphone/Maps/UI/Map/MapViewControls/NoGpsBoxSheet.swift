/// The sensor box: its state, the car speed, the firmware and what the user does with the box. Without a box it is
/// searched while the sheet is open, step by step, and the sheet offers to buy one.
final class NoGpsBoxSheet: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxCell"
    static let shopURL = URL(string: "https://non-gps.com")!
  }

  private enum Row {
    case state
    case search
    case name
    case speed
    case speedTable
    case firmware
    case calibrate
    case installFirmware
    case details
    case forget
    case buy
  }

  private struct Section {
    var header: String?
    let rows: [Row]
    var footer: String?
  }

  private var sections: [Section] = []
  private var status = NoGps.status()
  private var timer: Timer?
  // No box was set up when the sheet opened: it is searched until it is heard, and forgotten if the sheet is closed
  // before it is found.
  private var searching = false
  private let searchView = BoxSearchView()
  private var shownRows: [[Row]] = []

  static func show() {
    NoGpsControls.showSheet(NoGpsBoxSheet(style: .insetGrouped))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_box_title")
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self,
                                                        action: #selector(close))
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    searchView.onAction = { [weak self] in self?.openSettings() }
    if !status.inertialEnabled {
      searching = true
      NoGps.setInertialNavigationEnabled(true)
    }
    refresh()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    let timer = Timer(timeInterval: Constants.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    timer?.invalidate()
    timer = nil
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Closed by the button or swiped down before a box was found: the phone stops looking for it.
    if navigationController?.isBeingDismissed ?? isBeingDismissed, searching, NoGps.status().bleState != .connected {
      NoGps.setInertialNavigationEnabled(false)
      NoGpsStatusBar.update(NoGps.status())
    }
  }

  private func refresh() {
    status = NoGps.status()
    // The box connected while it was searched: the sheet shows it as any other.
    if searching, Self.isBoxHeard(status) {
      searching = false
    }
    if searching {
      searchView.update(status)
      sections = [
        Section(header: L("nogps_box_searching"), rows: [.search],
                footer: L("nogps_box_power_hint") + "\n\n" + L("nogps_box_buy_text")),
        Section(rows: [.buy]),
      ]
    } else if status.inertialEnabled {
      var info: [Row] = [.name, .speed]
      if status.inertialStarted {
        info.append(.speedTable)
      }
      if !status.boxFirmware.isEmpty || status.firmwareUpdate != .none {
        info.append(.firmware)
      }
      var actions: [Row] = [.calibrate]
      if NoGpsSensorsViewController.canInstallFirmware(status) {
        actions.append(.installFirmware)
      }
      actions.append(.details)
      sections = [Section(rows: [.state]), Section(rows: info), Section(rows: actions), Section(rows: [.forget])]
    } else {
      // Forgotten in the sensors screen.
      sections = [Section(rows: [.buy], footer: L("nogps_box_buy_text"))]
    }
    tableView.reloadData(keepingRows: sections.map(\.rows), &shownRows)
  }

  /// The box sends its data: it is connected, whatever it tells.
  static func isBoxHeard(_ status: NoGpsStatus) -> Bool {
    status.inertialStarted && status.sourceState != .disconnected && status.sourceState != .connecting
  }

  // MARK: - UITableViewDataSource

  override func numberOfSections(in _: UITableView) -> Int {
    sections.count
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].header
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section].footer
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.cell()
    content.textProperties.numberOfLines = 0
    cell.accessoryType = .none
    cell.selectionStyle = .none
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .search:
      cell.contentConfiguration = nil
      guard searchView.superview !== cell.contentView else { return cell }
      searchView.removeFromSuperview()
      searchView.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(searchView)
      NSLayoutConstraint.activate([
        searchView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        searchView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        searchView.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
        searchView.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
      ])
      return cell
    case .state:
      content = UIListContentConfiguration.subtitleCell()
      let look = NoGpsStatusBar.boxLook(status)
      content.image = look.image
      content.imageProperties.tintColor = look.color
      content.text = NoGpsSensorsViewController.boxStateText(status)
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.textProperties.color = look.color == .secondaryLabel ? .label : look.color
    case .name:
      let name = status.inertialStarted && !status.deviceName.isEmpty ? status.deviceName : "ESP32"
      content.text = String(format: L("nogps_sensors_box"), name)
    case .speed:
      let speed = status.inertialStarted ? status.speedKmh : -1
      content.text = String(format: L("nogps_sensors_speed"),
                            speed >= 0 ? String(format: L("nogps_speed_kmh"), speed) : L("nogps_unknown"))
    case .speedTable:
      content.text = String(format: L("nogps_box_speed_table"), speedTableText())
    case .firmware:
      content.text = String(format: L("nogps_sensors_firmware"), NoGpsSensorsViewController.firmwareText(status))
    case .calibrate:
      // The box calibrates itself: there is nobody to calibrate while it is out of reach.
      let reachable = status.bleState == .connected
      content.text = L("nogps_sensors_calibrate_box")
      content.textProperties.color = reachable ? .linkBlue : .blackHintText
      cell.selectionStyle = reachable ? .default : .none
    case .installFirmware:
      content.text = String(format: L("nogps_firmware_install"), status.bundledFirmware)
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .details:
      content.text = L("nogps_box_details")
      content.textProperties.color = .linkBlue
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .forget:
      content.text = L("nogps_box_forget")
      content.textProperties.color = .buttonRed
      cell.selectionStyle = .default
    case .buy:
      content.text = L("nogps_box_buy")
      content.textProperties.color = .linkBlue
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.textProperties.alignment = .center
      cell.selectionStyle = .default
    }
    cell.contentConfiguration = content
    return cell
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .buy:
      UIApplication.shared.open(Constants.shopURL)
    case .calibrate:
      guard status.bleState == .connected else { break }
      NoGps.calibrate()
      // It shows how the calibration goes.
      navigationController?.pushViewController(NoGpsSensorsViewController(), animated: true)
    case .installFirmware:
      // The box may have gone on since the row was drawn.
      if NoGpsSensorsViewController.canInstallFirmware(NoGps.status()) {
        NoGps.startFirmwareUpdate()
      }
      refresh()
    case .details:
      navigationController?.pushViewController(NoGpsSensorsViewController(), animated: true)
    case .forget:
      NoGps.setInertialNavigationEnabled(false)
      dismiss(animated: true)
    default:
      break
    }
    NoGpsStatusBar.update(NoGps.status())
  }

  // MARK: - Texts

  /// The ranges of the car speed measured by GPS, of all; roughly by the roads until GPS has measured one.
  private func speedTableText() -> String {
    let all = status.speedTableCarM.count
    if status.speedTableRanges == 0, status.roughSpeedTableRanges > 0 {
      return "≈\(status.roughSpeedTableRanges)/\(all)"
    }
    return "\(status.speedTableRanges)/\(all)"
  }

  // MARK: - Actions

  /// Bluetooth is turned on and allowed in the settings: iOS doesn't let an app do it.
  private func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  }

  @objc
  private func close() {
    dismiss(animated: true)
  }
}

/// The search of the box: Bluetooth waves and the steps to a connected box.
private final class BoxSearchView: UIView {
  private enum Constants {
    static let radarSize = CGFloat(96)
    static let coreSize = CGFloat(44)
    static let ringCount = 3
    static let ringDuration: CFTimeInterval = 2.4
    static let ringKey = "ring"
    static let dotSize = CGFloat(22)
  }

  private enum StepState {
    case waiting
    case current
    case done
    case failed
  }

  var onAction: (() -> Void)?

  private let radar = UIView()
  private var rings: [CAShapeLayer] = []
  private let steps = UIStackView()
  private var stepViews: [(dot: UIImageView, label: UILabel)] = []
  private let actionButton = UIButton(type: .system)

  init() {
    super.init(frame: .zero)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    radar.translatesAutoresizingMaskIntoConstraints = false
    radar.isAccessibilityElement = true
    radar.accessibilityLabel = L("nogps_box_bt_searching")
    for _ in 0 ..< Constants.ringCount {
      let ring = CAShapeLayer()
      ring.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: Constants.radarSize,
                                              height: Constants.radarSize)).cgPath
      ring.frame = CGRect(x: 0, y: 0, width: Constants.radarSize, height: Constants.radarSize)
      ring.fillColor = UIColor.clear.cgColor
      ring.lineWidth = 2
      ring.opacity = 0
      radar.layer.addSublayer(ring)
      rings.append(ring)
    }
    let core = UIImageView(image: UIImage(resource: .icNogpsBluetooth))
    core.tintColor = .white
    core.contentMode = .center
    core.backgroundColor = .systemBlue
    core.layer.cornerRadius = Constants.coreSize / 2
    core.translatesAutoresizingMaskIntoConstraints = false
    radar.addSubview(core)

    steps.axis = .vertical
    steps.spacing = 10
    steps.translatesAutoresizingMaskIntoConstraints = false
    let titles = [L("nogps_box_step_bluetooth"), L("nogps_box_step_search"), L("nogps_box_step_connect"),
                  L("nogps_box_step_data")]
    for title in titles {
      let dot = UIImageView()
      dot.contentMode = .scaleAspectFit
      dot.translatesAutoresizingMaskIntoConstraints = false
      let label = UILabel()
      label.text = title
      label.font = .preferredFont(forTextStyle: .subheadline)
      label.numberOfLines = 0
      let row = UIStackView(arrangedSubviews: [dot, label])
      row.spacing = 10
      row.alignment = .center
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: Constants.dotSize),
        dot.heightAnchor.constraint(equalToConstant: Constants.dotSize),
      ])
      steps.addArrangedSubview(row)
      stepViews.append((dot, label))
    }
    actionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    actionButton.contentHorizontalAlignment = .leading
    actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
    steps.addArrangedSubview(actionButton)

    addSubview(radar)
    addSubview(steps)
    NSLayoutConstraint.activate([
      radar.widthAnchor.constraint(equalToConstant: Constants.radarSize),
      radar.heightAnchor.constraint(equalToConstant: Constants.radarSize),
      radar.leadingAnchor.constraint(equalTo: leadingAnchor),
      radar.centerYAnchor.constraint(equalTo: centerYAnchor),
      radar.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
      core.widthAnchor.constraint(equalToConstant: Constants.coreSize),
      core.heightAnchor.constraint(equalToConstant: Constants.coreSize),
      core.centerXAnchor.constraint(equalTo: radar.centerXAnchor),
      core.centerYAnchor.constraint(equalTo: radar.centerYAnchor),
      steps.leadingAnchor.constraint(equalTo: radar.trailingAnchor, constant: 16),
      steps.trailingAnchor.constraint(equalTo: trailingAnchor),
      steps.topAnchor.constraint(equalTo: topAnchor),
      steps.bottomAnchor.constraint(equalTo: bottomAnchor),
      steps.heightAnchor.constraint(greaterThanOrEqualTo: radar.heightAnchor),
    ])
  }

  func update(_ status: NoGpsStatus) {
    let ble = status.bleState
    let bluetoothFailed = ble == .off || ble == .disabled || ble == .noPermission
    let states: [StepState] = [
      bluetoothFailed ? .failed : .done,
      [.connecting, .pairing, .connected].contains(ble) ? .done
        : [.searching, .pairingClosed].contains(ble) ? .current : .waiting,
      ble == .connected ? .done : [.connecting, .pairing].contains(ble) ? .current : .waiting,
      ble == .connected ? .current : .waiting,
    ]
    for (state, view) in zip(states, stepViews) {
      show(state, dot: view.dot, label: view.label)
    }
    stepViews[0].label.text = L(ble == .noPermission ? "nogps_box_step_bluetooth_denied"
      : bluetoothFailed ? "nogps_box_step_bluetooth_off" : "nogps_box_step_bluetooth")
    actionButton.isHidden = !bluetoothFailed
    actionButton.setTitle(L(ble == .noPermission ? "nogps_box_allow" : "nogps_box_turn_on"), for: .normal)
    animateRings(!bluetoothFailed)
  }

  private func show(_ state: StepState, dot: UIImageView, label: UILabel) {
    let symbol: String
    let color: UIColor
    switch state {
    case .waiting: (symbol, color) = ("circle", .tertiaryLabel)
    case .current: (symbol, color) = ("circle.dotted", .systemBlue)
    case .done: (symbol, color) = ("checkmark.circle.fill", .systemGreen)
    case .failed: (symbol, color) = ("exclamationmark.circle.fill", .systemRed)
    }
    dot.image = UIImage(systemName: symbol)
    dot.tintColor = color
    label.textColor = state == .waiting ? .secondaryLabel : state == .failed ? .systemRed : .label
    label.font = .preferredFont(forTextStyle: state == .current ? .headline : .subheadline)
  }

  /// Waves go out from the phone while it looks for the box. The system removes them in the background, the next
  /// update adds them again.
  private func animateRings(_ on: Bool) {
    for (i, ring) in rings.enumerated() {
      ring.strokeColor = UIColor.systemBlue.resolvedColor(with: traitCollection).cgColor
      guard on else {
        ring.removeAnimation(forKey: Constants.ringKey)
        continue
      }
      guard ring.animation(forKey: Constants.ringKey) == nil else { continue }
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.4
      scale.toValue = 1
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0.7
      fade.toValue = 0
      let group = CAAnimationGroup()
      group.animations = [scale, fade]
      group.duration = Constants.ringDuration
      group.repeatCount = .infinity
      group.timingFunction = CAMediaTimingFunction(name: .easeOut)
      group.beginTime = CACurrentMediaTime() + Constants.ringDuration * Double(i) / Double(Constants.ringCount)
      ring.add(group, forKey: Constants.ringKey)
    }
  }

  @objc
  private func actionTapped() {
    onAction?()
  }
}
