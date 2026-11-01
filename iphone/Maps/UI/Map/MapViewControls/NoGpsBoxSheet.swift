/// The sensor box: its state, the car speed, the firmware and what the user does with the box. Without a box it is
/// searched while the sheet is open, step by step, and the sheet offers to buy one.
final class NoGpsBoxSheet: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxCell"
    static let shopURL = URL(string: "https://non-gps.com")!
    static let boxName = "NonGPS-OBD"
    static let extraSheetHeight = CGFloat(20)
  }

  private enum Row {
    case state
    case bluetooth
    case search
    case name
    case speed
    case rpm
    case speedTable
    case speedLag
    case clearSpeed
    case firmware
    case calibrate
    case installFirmware
    case forget
    case buy
    /// Another box, next to forgetting this one.
    case shop
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
  /// While the box is searched, connects, waits for the car data or takes a firmware, as the button pulses.
  private let stateProgress = UIActivityIndicatorView(style: .medium)
  private let speedLagValue: UILabel = {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .secondaryLabel
    return label
  }()

  private var shownRows: [[Row]] = []

  static func show() {
    // The buy row under the box rows fits.
    NoGpsControls.showSheet(NoGpsBoxSheet(style: .insetGrouped), extraHeight: Constants.extraSheetHeight)
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
      // The box tells the car data and its calibration: there is nothing to show while it is out of reach.
      let connected = Self.isBoxHeard(status) && status.bleState == .connected
      var info: [Row] = [.name]
      if connected {
        info.append(.speed)
      }
      if connected, status.rpm >= 0 {
        info.append(.rpm)
      }
      if !status.boxFirmware.isEmpty || status.firmwareUpdate != .none {
        info.append(.firmware)
      }
      if NoGpsSensorsViewController.canInstallFirmware(status) {
        info.append(.installFirmware)
      }
      if connected {
        info.append(.calibrate)
      }
      let state: [Row] = status.bleState == .noPermission ? [.state, .bluetooth] : [.state]
      sections = [Section(rows: state), Section(rows: info)]
      // What the app has learned about the car speed.
      if status.inertialStarted {
        sections.append(Section(rows: [.speedTable, .speedLag, .clearSpeed]))
      }
      sections.append(Section(rows: [.shop, .forget]))
    } else {
      // Forgotten in the sensors screen.
      sections = [Section(rows: [.buy], footer: L("nogps_box_buy_text"))]
    }
    tableView.reloadData(keepingRows: sections.map(\.rows), &shownRows)
  }

  /// Before the box tells its sensor.
  static func boxName(_ status: NoGpsStatus) -> String {
    status.inertialStarted && !status.deviceName.isEmpty ? status.deviceName : Constants.boxName
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
    cell.accessoryView = accessoryView(row)
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
      // The states follow "Box: name ·" on the sensors screen, here they start the line.
      let text = NoGpsSensorsViewController.boxStateText(status)
      content.text = text.prefix(1).uppercased(with: .current) + text.dropFirst()
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.textProperties.color = look.color == .secondaryLabel ? .label : look.color
    case .bluetooth:
      content.text = L("nogps_box_allow")
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .name:
      content.text = String(format: L("nogps_sensors_box"), Self.boxName(status))
    case .speed:
      content.text = String(format: L("nogps_sensors_speed"), status.speedKmh >= 0
        ? String(format: L("nogps_speed_kmh"), status.speedKmh) : L("nogps_unknown"))
    case .rpm:
      content.text = String(format: L("nogps_box_rpm"), String(format: L("nogps_rpm"), status.rpm))
    case .speedTable:
      content = UIListContentConfiguration.valueCell()
      content.text = L("nogps_speed_table_title")
      content.secondaryText = speedTableText()
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .speedLag:
      content = UIListContentConfiguration.subtitleCell()
      content.text = L("nogps_speed_lag")
      content.secondaryText = L(status.speedLagMeasured ? "nogps_speed_lag_measured" : "nogps_speed_lag_usual")
      content.secondaryTextProperties.color = .secondaryLabel
      // On the right in the middle of both lines, as the values of the other rows.
      speedLagValue.text = String(format: L("nogps_speed_lag_value"), String(format: "%.1f", status.speedLagSec))
      speedLagValue.sizeToFit()
    case .clearSpeed:
      content.text = L("nogps_box_clear_speed")
      // Not as red as forgetting the box: the table is learned again on the next trips.
      content.textProperties.color = .systemOrange
      cell.selectionStyle = .default
    case .firmware:
      content.text = String(format: L("nogps_sensors_firmware"), NoGpsSensorsViewController.firmwareText(status))
    case .calibrate:
      content = UIListContentConfiguration.valueCell()
      content.textProperties.numberOfLines = 0
      let (text, action) = calibrationTexts()
      content.text = text
      content.secondaryText = action
      content.secondaryTextProperties.color = .linkBlue
      if action != nil {
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
      }
    case .installFirmware:
      content.text = String(format: L("nogps_firmware_install"), status.bundledFirmware)
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .shop:
      content.text = L("nogps_box_buy")
      content.textProperties.color = .linkBlue
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

  /// The same views each refresh: new ones fly in from the corner of the reconfigured cell.
  private func accessoryView(_ row: Row) -> UIView? {
    switch row {
    case .speedLag:
      return speedLagValue
    case .state where NoGpsStatusBar.boxLook(status).pulsing:
      stateProgress.startAnimating()
      return stateProgress
    default:
      return nil
    }
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .bluetooth:
      openSettings()
    case .buy, .shop:
      UIApplication.shared.open(Constants.shopURL)
    case .clearSpeed:
      NoGpsSensorsViewController.confirmClearSpeed(from: self) { [weak self] in self?.refresh() }
    case .speedTable:
      navigationController?.pushViewController(SpeedTableViewController(style: .insetGrouped), animated: true)
    case .calibrate:
      // The row shows how the calibration goes.
      guard calibrationTexts().action != nil else { break }
      NoGps.calibrate()
      refresh()
    case .installFirmware:
      // The box may have gone on since the row was drawn.
      if NoGpsSensorsViewController.canInstallFirmware(NoGps.status()) {
        NoGps.startFirmwareUpdate()
      }
      refresh()
    case .forget:
      NoGps.setInertialNavigationEnabled(false)
      dismiss(animated: true)
    default:
      break
    }
    NoGpsStatusBar.update(NoGps.status())
  }

  // MARK: - Texts

  /// How many ranges of the car speed GPS has measured. The rough table by the roads doesn't count: it is only a guess.
  private func speedTableText() -> String {
    let all = status.speedTableCarM.count
    if status.speedTableRanges == 0 {
      return L("nogps_speed_table_not_calibrated")
    }
    if status.speedTableRanges >= all {
      return L("nogps_speed_table_calibrated")
    }
    return String(format: L("nogps_speed_table_calibrating"), status.speedTableRanges, all)
  }

  /// The state of the calibration and what the user can do: nothing while it goes.
  private func calibrationTexts() -> (text: String, action: String?) {
    switch status.calibration {
    case .none:
      return (L("nogps_box_sensors_not_calibrated"), L("nogps_sensors_calibrate_box"))
    case .done where !status.boxCalibrationAdvised:
      return (L("nogps_box_sensors_calibrated"), L("nogps_box_recalibrate"))
    case .calibrating:
      return (String(format: L("nogps_sensors_box_sensors"), NoGpsSensorsViewController.boxCalibrationText(status)), nil)
    default:
      return (String(format: L("nogps_sensors_box_sensors"), NoGpsSensorsViewController.boxCalibrationText(status)),
              L("nogps_sensors_calibrate_box"))
    }
  }

  // MARK: - Actions

  /// Bluetooth is allowed in the settings: once refused, iOS doesn't ask again.
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

/// The ranges of the car speed and how each is corrected: by GPS, roughly by the roads, or not yet.
private final class SpeedTableViewController: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsSpeedTableCell"
    static let headerId = "NoGpsSpeedTableHeader"
    // Dense: all the ranges fit on the screen.
    static let rowHeight = CGFloat(32)
    static let rowMargin = CGFloat(4)
  }

  private var status = NoGps.status()
  private var timer: Timer?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_speed_table_title")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: Constants.headerId)
    tableView.rowHeight = UIFontMetrics.default.scaledValue(for: Constants.rowHeight)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refresh()
    let timer = Timer(timeInterval: Constants.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    timer?.invalidate()
    timer = nil
  }

  private func refresh() {
    status = NoGps.status()
    tableView.reloadData()
  }

  override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
    status.inertialStarted ? status.speedTableCarM.count : 0
  }

  /// Above the ranges and larger than a usual header: it is read before the table. What the user does stands out.
  override func tableView(_ tableView: UITableView, viewForHeaderInSection _: Int) -> UIView? {
    let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: Constants.headerId)
    var content = UIListContentConfiguration.groupedHeader()
    let font = UIFont.preferredFont(forTextStyle: .subheadline)
    let text = NSMutableAttributedString(string: L("nogps_speed_table_hint") + "\n",
                                         attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
    let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
    text.append(NSAttributedString(string: L("nogps_speed_table_action"),
                                   attributes: [.font: bold, .foregroundColor: UIColor.label]))
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = 6
    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    content.attributedText = text
    content.textProperties.transform = .none
    header?.contentConfiguration = content
    return header
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.cell()
    content.text = NoGpsSensorsViewController.speedTableRowText(status, indexPath.row)
    content.directionalLayoutMargins.top = Constants.rowMargin
    content.directionalLayoutMargins.bottom = Constants.rowMargin
    content.textProperties.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                                             weight: .regular)
    cell.contentConfiguration = content
    cell.selectionStyle = .none
    return cell
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
    actionButton.setTitle(L("nogps_box_allow"), for: .normal)
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
    // Bluetooth is turned on by the user: iOS asks for it itself and doesn't let an app open its settings.
    actionButton.isHidden = ble != .noPermission
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
