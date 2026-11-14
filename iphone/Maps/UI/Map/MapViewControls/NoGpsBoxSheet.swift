/// The sensor box: its state, the car speed, the firmware and what the user does with the box. Without a box it is
/// searched while the sheet is open, step by step, and the sheet offers to buy one. On the top the box and GPS are side
/// by side, GPS opens its page. The first row turns GPS off for the car.
final class NoGpsBoxSheet: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxCell"
    static let shopURL = URL(string: "https://non-gps.com")!
    static let boxName = "NonGPS-OBD"
    static let extraSheetHeight = CGFloat(20)
  }

  private enum Row {
    case gpsUse
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
  private let header = StatusTilesView()
  private let gpsUse = UISwitch()
  private let gpsUseFooter = GpsUseFooterView()
  private let speedLagValue: UILabel = {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .secondaryLabel
    return label
  }()

  private var shownRows: [[Row]] = []
  private var shownFooters: [String?] = []

  /// The height of the rows the sheet was fitted to.
  private var fittedHeight = CGFloat(0)
  /// The bottom of the bar in a shown sheet: iOS moves the bar and makes it higher only as the sheet opens. The sheet
  /// is fitted with it from the start, else it would grow as it opens. Taken again from every shown sheet.
  private static var barBottom: CGFloat = if #available(iOS 26.0, *) {
    70
  } else {
    56
  }

  static func show() {
    let root = NoGpsBoxSheet(style: .insetGrouped)
    let navigation = UINavigationController(rootViewController: root)
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      if #available(iOS 16.0, *) {
        sheet.detents = [.custom { [weak root] context in
          root.map { min($0.sheetHeight, context.maximumDetentValue) }
        }, .large()]
        // The rows are laid out before the sheet is: it opens at their height, not at the bar only.
        navigation.view.frame = UIViewController.topViewController().view.window?.bounds ?? UIScreen.main.bounds
        navigation.view.layoutIfNeeded()
      }
      sheet.prefersGrabberVisible = true
    }
    UIViewController.topViewController().present(navigation, animated: true)
  }

  /// Without a box the sheet fits its rows: the search and the offer to buy one. With a box it opens at half the
  /// window, with the buy row under the box rows, and more of them are seen when it is pulled up.
  private var sheetHeight: CGFloat {
    let window = view.window?.bounds.height ?? UIScreen.main.bounds.height
    guard searching || !status.inertialEnabled else { return window / 2 + Constants.extraSheetHeight }
    return Self.barBottom + tableView.contentSize.height
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // The sheet has no title: the box tile tells what it is about.
    navigationItem.backButtonTitle = L("nogps_box_title")
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self,
                                                        action: #selector(close))
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    tableView.tableHeaderView = header
    searchView.onAction = { [weak self] in self?.onLinkAction() }
    header.gps.addTarget(self, action: #selector(openGps), for: .touchUpInside)
    gpsUse.accessibilityLabel = L("nogps_gps_use")
    gpsUse.addTarget(self, action: #selector(gpsUseChanged), for: .valueChanged)
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

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let bar = navigationController?.navigationBar {
      Self.barBottom = bar.frame.maxY
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    timer?.invalidate()
    timer = nil
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutHeader()
    // Rows come and go, the box is found: the sheet follows. Not for the fractions of a point the layout differs by.
    let height = sheetHeight
    if #available(iOS 16.0, *), let sheet = navigationController?.sheetPresentationController,
       abs(height - fittedHeight) >= 1 {
      fittedHeight = height
      sheet.animateChanges { sheet.invalidateDetents() }
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Not when the GPS page is opened over it.
    if navigationController?.isBeingDismissed ?? isBeingDismissed {
      stopSearchIfNotFound()
    }
  }

  /// Closed by the button or swiped down, from either page, before the box was heard, even if connected already: the
  /// phone stops looking for it.
  func stopSearchIfNotFound() {
    if searching, !Self.isBoxHeard(NoGps.status()) {
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
    var boxLook = NoGpsStatusBar.boxLook(status)
    // The waves of the search show it.
    boxLook.pulsing = boxLook.pulsing && !searching
    header.box.show(boxLook, state: searching ? L("nogps_box_searching")
      : status.inertialEnabled ? NoGpsSensorsViewController.boxStateText(status) : L("nogps_box_buy_title"))
    header.gps.show(NoGpsStatusBar.gpsLook(status), state: NoGpsStatusBar.gpsStateText(status))
    layoutHeader()
    // GPS is turned off for the car only while the box can drive it: nothing would move the mark otherwise.
    let canChangeGpsUse = status.gpsDisabled || Self.isBoxHeard(status)
    gpsUse.isEnabled = canChangeGpsUse
    if !gpsUse.isTracking {
      gpsUse.isOn = !status.gpsDisabled
    }
    gpsUseFooter.update(canChangeUse: canChangeGpsUse)
    let gps = Section(rows: [.gpsUse])
    if searching {
      searchView.update(status)
      sections = [
        gps,
        Section(rows: [.search], footer: L("nogps_box_power_hint") + "\n\n" + L("nogps_box_buy_text")),
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
      if Self.linkActionText(status.bleState) != nil {
        info.insert(.bluetooth, at: 0)
      }
      sections = [gps, Section(rows: info, footer: Self.obdHintText(status))]
      // What the app has learned about the car speed.
      if status.inertialStarted {
        sections.append(Section(rows: [.speedTable, .speedLag, .clearSpeed]))
      }
      sections.append(Section(rows: [.shop, .forget]))
    } else {
      // Forgotten in the sensors screen.
      sections = [gps, Section(rows: [.buy], footer: L("nogps_box_buy_text"))]
    }
    // Footers are not updated in place.
    let footers = sections.map(\.footer)
    if footers != shownFooters {
      shownFooters = footers
      shownRows = []
    }
    tableView.reloadData(keepingRows: sections.map(\.rows), &shownRows)
  }

  /// The header of a table keeps the height it had when it was set.
  private func layoutHeader() {
    let width = tableView.bounds.width
    guard width > 0 else { return }
    let height = header.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                withHorizontalFittingPriority: .required,
                                                verticalFittingPriority: .fittingSizeLevel).height
    guard header.frame.width != width || header.frame.height != height else { return }
    header.frame = CGRect(x: 0, y: 0, width: width, height: height)
    tableView.tableHeaderView = header
  }

  /// Before the box tells its sensor.
  static func boxName(_ status: NoGpsStatus) -> String {
    status.inertialStarted && !status.deviceName.isEmpty ? status.deviceName : Constants.boxName
  }

  /// The box sends its data: it is connected, whatever it tells.
  static func isBoxHeard(_ status: NoGpsStatus) -> Bool {
    status.inertialStarted && status.sourceState != .disconnected && status.sourceState != .connecting
  }

  /// What the user does for the phone to reach the box, nil if nothing: the steps and their button tell the rest.
  static func linkHintText(_ ble: NoGpsBleState) -> String? {
    let text: String
    switch ble {
    case .pairingClosed: text = L("nogps_box_bt_pairing_closed")
    case .pairing: text = L("nogps_box_bt_pairing")
    case .pairingFailed: text = L("nogps_box_bt_pairing_failed")
    case .bondLost: text = L("nogps_box_bt_bond_lost")
    default: return nil
    }
    // The states follow "Box: name ·" on the sensors screen, here they start the line.
    return text.prefix(1).uppercased() + text.dropFirst()
  }

  /// The button of the steps and of a box set up, nil if none. Bluetooth is turned on by the user: iOS asks for it
  /// itself and doesn't let an app open its settings.
  static func linkActionText(_ ble: NoGpsBleState) -> String? {
    switch ble {
    case .noPermission: L("nogps_box_allow")
    case .pairingFailed, .bondLost: L("nogps_box_try_again")
    default: nil
    }
  }

  /// What the user does for the box to get the car speed, nil if nothing.
  static func obdHintText(_ status: NoGpsStatus) -> String? {
    guard isBoxHeard(status), status.bleState == .connected else { return nil }
    switch status.sourceState {
    // The box retries the search of the car protocol while the car is silent: one text for both.
    case .noCarData, .obdConnecting: return L("nogps_box_hint_no_car")
    case .noAdapter: return L("nogps_box_hint_no_adapter")
    case .obdError: return L("nogps_box_hint_obd_error")
    case .obdDisabled: return L("nogps_box_hint_obd_disabled")
    default: return nil
    }
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

  override func tableView(_: UITableView, viewForFooterInSection section: Int) -> UIView? {
    sections[section].rows == [.gpsUse] ? gpsUseFooter : nil
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
      embed(searchView, in: cell)
      return cell
    case .gpsUse:
      content.text = L("nogps_gps_use")
    case .bluetooth:
      content.text = Self.linkActionText(status.bleState)
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .name:
      content.text = String(format: L("nogps_sensors_box"), Self.boxName(status))
      if !status.boxValues.isEmpty {
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
      }
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
    case .speedLag: return speedLagValue
    // A switch is not reset while it is turned.
    case .gpsUse: return gpsUse
    default: return nil
    }
  }

  /// A row of its own view, the same one every refresh: its animation goes on.
  private func embed(_ view: UIView, in cell: UITableViewCell) {
    cell.contentConfiguration = nil
    guard view.superview !== cell.contentView else { return }
    view.removeFromSuperview()
    view.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(view)
    let guide = cell.contentView.layoutMarginsGuide
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      view.topAnchor.constraint(equalTo: guide.topAnchor),
      view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
    ])
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .bluetooth:
      onLinkAction()
    case .buy, .shop:
      UIApplication.shared.open(Constants.shopURL)
    case .clearSpeed:
      NoGpsSensorsViewController.confirmClearSpeed(from: self) { [weak self] in self?.refresh() }
    case .speedTable:
      navigationController?.pushViewController(SpeedTableViewController(style: .insetGrouped), animated: true)
    case .name:
      guard !status.boxValues.isEmpty else { break }
      navigationController?.pushViewController(BoxValuesViewController(style: .insetGrouped), animated: true)
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
      NoGps.forgetBox()
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

  /// Bluetooth is allowed in the settings: once refused, iOS doesn't ask again. The box is searched again after a failed
  /// pairing or a lost bond.
  private func onLinkAction() {
    guard NoGps.status().bleState == .noPermission else {
      NoGps.retryBox()
      refresh()
      return
    }
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  }

  @objc
  private func openGps() {
    navigationController?.pushViewController(NoGpsGpsSheet(style: .insetGrouped), animated: true)
  }

  @objc
  private func gpsUseChanged() {
    NoGps.setGpsDisabled(!gpsUse.isOn)
    refresh()
    NoGpsStatusBar.update(NoGps.status())
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
    // Follows the text size, also changed while the screen is open.
    tableView.rowHeight = UIFontMetrics.default.scaledValue(for: Constants.rowHeight)
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

/// All the box has told about itself and the car in this connection, by groups.
private final class BoxValuesViewController: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxValueCell"
    static let empty = "—"
  }

  private struct Group {
    let header: String
    var items: [NoGpsBoxValueItem]
    var footer: String?
  }

  private var status = NoGps.status()
  private var groups: [Group] = []
  private var timer: Timer?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_box_value_title")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
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
    // The box has disconnected: its values are gone.
    if status.boxValues.isEmpty, navigationController?.topViewController === self {
      navigationController?.popViewController(animated: true)
      return
    }
    // The values come in the order of the groups.
    let headers = [L("nogps_box_value_group_car"), L("nogps_box_value_group_gyroscope"), L("nogps_box_value_group_obd"),
                   L("nogps_box_value_group_box")]
    let groupStarts: [NoGpsBoxValue] = [.engine, .imuName, .obdState, .firmware]
    groups = []
    for item in status.boxValues {
      let index = groupStarts.lastIndex { $0.rawValue <= item.kind.rawValue } ?? 0
      if groups.last?.header != headers[index] {
        groups.append(Group(header: headers[index], items: []))
      }
      groups[groups.count - 1].items.append(item)
      if item.kind == .voltageMismatch, item.value == "1" {
        groups[groups.count - 1].footer = L("nogps_voltage_mismatch")
      }
    }
    tableView.reloadData()
  }

  override func numberOfSections(in _: UITableView) -> Int {
    groups.count
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    groups[section].items.count
  }

  override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    groups[section].header
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    groups[section].footer
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    let item = groups[indexPath.section].items[indexPath.row]
    var content = UIListContentConfiguration.valueCell()
    content.text = Self.label(item.kind)
    content.secondaryText = valueText(item)
    content.textProperties.numberOfLines = 0
    content.secondaryTextProperties.numberOfLines = 0
    cell.contentConfiguration = content
    cell.selectionStyle = .none
    return cell
  }

  private func valueText(_ item: NoGpsBoxValueItem) -> String {
    let value = item.value
    if value.isEmpty {
      // The box asks the car for them while it stands.
      let standingOnly = item.kind == .rpm || item.kind == .elmVoltage || item.kind == .ecuVoltage
      return standingOnly && status.speedKmh > 0 ? L("nogps_not_while_driving") : Constants.empty
    }
    switch item.kind {
    case .engine:
      if value == "RUN" {
        return L("nogps_engine_running")
      }
      if value == "OFF" {
        return L("nogps_engine_stopped")
      }
      return value
    case .rpm:
      return Int(value).map { String(format: L("nogps_rpm"), $0) } ?? value
    case .boxVoltage, .elmVoltage, .ecuVoltage:
      return String(format: L("nogps_volts"), value)
    case .voltageMismatch:
      return value == "1" ? L("yes") : L("no")
    case .imuRate:
      return String(format: L("nogps_box_value_hz"), value)
    case .imuTemperature:
      return String(format: L("nogps_box_value_celsius"), value)
    case .biasAge:
      return String(format: L("nogps_box_value_seconds_ago"), value)
    case .bias:
      return String(format: L("nogps_box_value_degrees_per_second"), value)
    case .flashSize, .maxImageSize:
      return String(format: L("nogps_box_value_kilobytes"), value)
    default:
      return value
    }
  }

  private static func label(_ kind: NoGpsBoxValue) -> String {
    switch kind {
    case .engine: L("nogps_box_value_engine")
    case .rpm: L("nogps_box_value_rpm")
    case .boxVoltage: L("nogps_box_value_box_voltage")
    case .elmVoltage: L("nogps_box_value_elm_voltage")
    case .ecuVoltage: L("nogps_box_value_ecu_voltage")
    case .voltageMismatch: L("nogps_box_value_voltage_mismatch")
    case .imuName: L("nogps_box_value_name")
    case .imuState, .obdState: L("nogps_box_value_state")
    case .imuChipId: L("nogps_box_value_chip_id")
    case .imuRate: L("nogps_box_value_rate")
    case .imuTemperature: L("nogps_box_value_temperature")
    case .imuErrors: L("nogps_box_value_read_errors")
    case .biasAge: L("nogps_box_value_bias_age")
    case .bias: L("nogps_box_value_bias")
    case .obdProtocol: L("nogps_box_value_protocol")
    case .obdError: L("nogps_box_value_last_error")
    case .obdBaud: L("nogps_box_value_uart_baud")
    case .firmware: L("nogps_box_value_firmware")
    case .buildDate: L("nogps_box_value_build_date")
    case .chip: L("nogps_box_value_chip")
    case .board: L("nogps_box_value_board")
    case .id: L("nogps_box_value_id")
    case .flashSize: L("nogps_box_value_flash_size")
    case .maxImageSize: L("nogps_box_value_max_image_size")
    case .slot: L("nogps_box_value_slot")
    case .slotState: L("nogps_box_value_slot_state")
    case .abilities: L("nogps_box_value_abilities")
    case .powerOns: L("nogps_box_value_power_ons")
    case .lastEvent: L("nogps_box_value_last_event")
    @unknown default: ""
    }
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
  private let hintLabel = UILabel()
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
    hintLabel.font = .preferredFont(forTextStyle: .subheadline)
    hintLabel.numberOfLines = 0
    steps.addArrangedSubview(hintLabel)
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
    let linkFailed = ble == .pairingFailed || ble == .bondLost
    let states: [StepState] = [
      bluetoothFailed ? .failed : .done,
      [.connecting, .pairing, .connected, .pairingFailed, .bondLost].contains(ble) ? .done
        : [.searching, .pairingClosed].contains(ble) ? .current : .waiting,
      ble == .connected ? .done : linkFailed ? .failed : [.connecting, .pairing].contains(ble) ? .current : .waiting,
      ble == .connected ? .current : .waiting,
    ]
    for (state, view) in zip(states, stepViews) {
      show(state, dot: view.dot, label: view.label)
    }
    stepViews[0].label.text = L(ble == .noPermission ? "nogps_box_step_bluetooth_denied"
      : bluetoothFailed ? "nogps_box_step_bluetooth_off" : "nogps_box_step_bluetooth")
    let hint = NoGpsBoxSheet.linkHintText(ble)
    hintLabel.text = hint
    hintLabel.isHidden = hint == nil
    let action = NoGpsBoxSheet.linkActionText(ble)
    actionButton.setTitle(action, for: .normal)
    actionButton.isHidden = action == nil
    // Nothing is searched after a failed pairing or a lost bond until the user acts.
    animateRings(!bluetoothFailed && !linkFailed)
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

/// The top of the Box sheet: the box and GPS side by side. GPS opens its page.
private final class StatusTilesView: UIView {
  let box = StatusTileView(title: L("nogps_box_title"), opensPage: false)
  let gps = StatusTileView(title: L("nogps_status_gps"), opensPage: true)

  init() {
    super.init(frame: .zero)
    let row = UIStackView(arrangedSubviews: [box, gps])
    row.distribution = .fillEqually
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    // As wide as the groups of rows under it.
    preservesSuperviewLayoutMargins = true
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

/// The name of a source, its icon on the tint of its state, and the state under it. Its height doesn't follow the state: the
/// sheet doesn't jump as the states change, a longer state is cut.
private final class StatusTileView: UIControl {
  private enum Constants {
    static let tileSide = CGFloat(44)
    static let stateLines = 3
    static let cornerRadius = CGFloat(10)
  }

  private let titleLabel = UILabel()
  private let tile = UIImageView()
  private let stateLabel = UILabel()
  private var stateHeight: NSLayoutConstraint!
  private var look: NoGpsStatusBar.Look?

  init(title: String, opensPage: Bool) {
    super.init(frame: .zero)
    backgroundColor = .secondarySystemGroupedBackground
    layer.cornerRadius = Constants.cornerRadius
    layer.cornerCurve = .continuous
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityTraits = opensPage ? .button : .none
    isUserInteractionEnabled = opensPage
    titleLabel.text = title
    titleLabel.font = .preferredFont(forTextStyle: .caption1)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .secondaryLabel
    stateLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
    stateLabel.adjustsFontForContentSizeCategory = true
    stateLabel.numberOfLines = Constants.stateLines
    stateLabel.textAlignment = .center
    // The state starts under the icon, whatever its length.
    let stateBox = UIView()
    stateBox.addSubview(stateLabel)
    let content = UIStackView(arrangedSubviews: [titleLabel, tile, stateBox])
    content.axis = .vertical
    content.alignment = .center
    content.spacing = 8
    content.isUserInteractionEnabled = false
    for view in [content, stateLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    addSubview(content)
    stateHeight = stateBox.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      tile.widthAnchor.constraint(equalToConstant: Constants.tileSide),
      tile.heightAnchor.constraint(equalToConstant: Constants.tileSide),
      stateBox.widthAnchor.constraint(equalTo: content.widthAnchor),
      stateHeight,
      stateLabel.leadingAnchor.constraint(equalTo: stateBox.leadingAnchor),
      stateLabel.trailingAnchor.constraint(equalTo: stateBox.trailingAnchor),
      stateLabel.topAnchor.constraint(equalTo: stateBox.topAnchor),
      stateLabel.bottomAnchor.constraint(lessThanOrEqualTo: stateBox.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
    updateStateHeight()
    guard opensPage else { return }
    let chevron = UIImageView(image: UIImage(systemName: "chevron.forward",
                                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 13,
                                                                                            weight: .semibold)))
    chevron.tintColor = .tertiaryLabel
    chevron.translatesAutoresizingMaskIntoConstraints = false
    addSubview(chevron)
    NSLayoutConstraint.activate([
      chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      chevron.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
    ])
    addTarget(self, action: #selector(pressed), for: [.touchDown, .touchDragEnter])
    addTarget(self, action: #selector(released), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    drawTile()
    updateStateHeight()
  }

  func show(_ look: NoGpsStatusBar.Look, state text: String) {
    self.look = look
    drawTile()
    NavButton.pulse(tile.layer, look.pulsing)
    // The states follow "Box: name ·" on the sensors screen, here they start the line.
    stateLabel.text = text.prefix(1).uppercased(with: .current) + text.dropFirst()
    // A grey state is read as disabled.
    stateLabel.textColor = look.color == .secondaryLabel ? .label : look.color
    accessibilityValue = stateLabel.text
  }

  /// All the lines of a state, at the text size of the user.
  private func updateStateHeight() {
    stateHeight.constant = ceil(stateLabel.font.lineHeight * CGFloat(Constants.stateLines))
  }

  private func drawTile() {
    guard let look else { return }
    tile.image = NoGpsStatusBar.tileImage(look, side: Constants.tileSide, traits: traitCollection)
  }

  @objc
  private func pressed() {
    backgroundColor = .systemFill
  }

  @objc
  private func released() {
    UIView.animate(withDuration: AppConstants.defaultAnimationDuration) {
      self.backgroundColor = .secondarySystemGroupedBackground
    }
  }
}

/// Why GPS can be turned off for the car, or why not. Both texts take their place: the sheet doesn't jump as the box
/// comes and goes.
private final class GpsUseFooterView: UITableViewHeaderFooterView {
  private let hint = UILabel()
  private let needsBox = UILabel()

  init() {
    super.init(reuseIdentifier: nil)
    hint.text = L("nogps_gps_use_hint")
    needsBox.text = L("nogps_gps_use_needs_box")
    for label in [hint, needsBox] {
      label.font = .preferredFont(forTextStyle: .footnote)
      label.adjustsFontForContentSizeCategory = true
      label.textColor = .secondaryLabel
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
        label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        label.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
        label.bottomAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.bottomAnchor),
      ])
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(canChangeUse: Bool) {
    hint.alpha = canChangeUse ? 1 : 0
    needsBox.alpha = canChangeUse ? 0 : 1
    hint.accessibilityElementsHidden = !canChangeUse
    needsBox.accessibilityElementsHidden = canChangeUse
  }
}
