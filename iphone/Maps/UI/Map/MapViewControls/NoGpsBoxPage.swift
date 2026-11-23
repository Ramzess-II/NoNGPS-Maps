/// The sensor box, the car and how they are calibrated: whether the box can drive without GPS, then one item for each
/// part, which opens a page of its own, this class too. Opened from the box tile of the Box sheet, from the road-lost
/// pill and from the firmware offer.
final class NoGpsBoxPage: MWMTableViewController {
  enum Part: CaseIterable {
    case box
    case obd
    case car
    case speed
    case imu
  }

  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxPageCell"
    static let boxModel = "NonGPS-OBD"
    // The speed table ranges, as in SpeedTable of the core.
    static let speedTableRangeKmh = 10
    static let speedTableMinKmh = 5
    // A range is measured after this distance.
    static let speedTableMinDistanceM = 300
    // Dense: all the ranges of the speed table fit on the screen.
    static let tableRowMargin = CGFloat(4)
  }

  private enum Row: Equatable {
    case readiness
    case item(Part)
    case readOnly
    case fixHint
    case firmware
    case firmwareAction
    case value(NoGpsBoxValue)
    case speed
    case carName
    case speedText
    case speedLag
    case clearSpeed
    case speedTableRange(Int)
    case calibration
  }

  private struct Section {
    let rows: [Row]
    var footer: String?
  }

  private var sections: [Section] = []
  private var status = NoGps.status()
  private var timer: Timer?
  /// The page of one part, nil for the items of all of them.
  let part: Part?
  /// The values of the last connection: the box tells them only while it is connected.
  private var lastValues: [NoGpsBoxValueItem]
  private var shownRows: [[Row]] = []
  private var shownFooters: [String?] = []
  private let speedLagValue: UILabel = {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .secondaryLabel
    return label
  }()

  init(part: Part? = nil, lastValues: [NoGpsBoxValueItem] = []) {
    self.part = part
    self.lastValues = lastValues
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonDisplayMode = .minimal
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
    // The last car is forgotten: there is no box to show.
    guard status.inertialEnabled else {
      if navigationController?.topViewController === self {
        navigationController?.popToRootViewController(animated: true)
      }
      return
    }
    if !status.boxValues.isEmpty {
      lastValues = status.boxValues
    }
    // The car may be renamed or switched meanwhile.
    title = part.map { itemTitle($0) } ?? L("nogps_box_title")
    if let part {
      sections = [partSection(part)]
    } else {
      sections = status.inertialStarted ? [Section(rows: [.readiness])] : []
      // The speed is learned while the box leads the car.
      let parts: [Part] = status.inertialStarted ? [.box, .obd, .car, .speed, .imu] : [.box, .obd, .car, .imu]
      sections.append(Section(rows: parts.map { .item($0) }))
    }
    // Footers are not updated in place.
    let footers = sections.map(\.footer)
    if footers != shownFooters {
      shownFooters = footers
      shownRows = []
    }
    tableView.reloadData(keepingRows: sections.map(\.rows), &shownRows)
  }

  /// What the part shows on its page.
  private func partSection(_ part: Part) -> Section {
    switch part {
    case .box:
      let connected = NoGpsBoxSheet.isBoxHeard(status) && status.bleState == .connected
      var rows: [Row] = []
      if connected, status.boxReadOnly {
        rows.append(.readOnly)
      }
      rows.append(.fixHint)
      if !status.boxFirmware.isEmpty || Self.isFirmwareUpdating(status) {
        rows.append(.firmware)
      }
      if Self.canInstallFirmware(status) || Self.canCancelFirmware(status) {
        rows.append(.firmwareAction)
      }
      // The firmware row above tells the version.
      return Section(rows: rows + valueRows(.buildDate, .lastEvent))
    case .obd:
      return Section(rows: valueRows(.obdState, .obdBaud))
    case .car:
      let mismatch = status.boxValues.contains { $0.kind == .voltageMismatch && $0.value == "1" }
      // The car leads to its box now, not the box to the car: the name is told here, nothing more.
      var rows: [Row] = [.speed]
      if currentCar != nil {
        rows.append(.carName)
      }
      return Section(rows: rows + valueRows(.engine, .voltageMismatch),
                     footer: mismatch ? L("nogps_voltage_mismatch") : nil)
    case .speed:
      return Section(rows: [.speedText, .speedLag, .clearSpeed]
        + status.speedTableCarM.indices.map { .speedTableRange($0) })
    case .imu:
      return Section(rows: [.calibration] + valueRows(.imuName, .bias))
    }
  }

  /// The values of a group, in the order of NoGpsBoxValue.
  private func valueRows(_ first: NoGpsBoxValue, _ last: NoGpsBoxValue) -> [Row] {
    // Nothing from the box yet: every row of the range is shown with a dash, so the page is not an empty one.
    guard !lastValues.isEmpty else {
      return (first.rawValue ... last.rawValue).compactMap(NoGpsBoxValue.init(rawValue:)).map { .value($0) }
    }
    return lastValues.filter { (first.rawValue ... last.rawValue).contains($0.kind.rawValue) }.map { .value($0.kind) }
  }

  // MARK: - UITableViewDataSource

  override func numberOfSections(in _: UITableView) -> Int {
    sections.count
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section].footer
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.cell()
    content.textProperties.numberOfLines = 0
    cell.accessoryType = .none
    cell.accessoryView = nil
    cell.selectionStyle = .none
    switch sections[indexPath.section].rows[indexPath.row] {
    case .readiness:
      let missing = missingParts()
      content.text = missing.isEmpty ? L("nogps_sensors_ready")
        : String(format: L("nogps_sensors_not_ready"), missing.joined(separator: ", "))
      content.textProperties.color = missing.isEmpty ? .systemGreen : .systemRed
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
    case .item(let part):
      content = UIListContentConfiguration.subtitleCell()
      content.text = itemTitle(part)
      content.secondaryText = itemSubtitle(part)
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.secondaryTextProperties.color = .secondaryLabel
      content.secondaryTextProperties.numberOfLines = 0
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .readOnly:
      // The phone that follows the other one shows its place.
      content.text = [L("nogps_box_read_only"), NoGpsStatusBar.peerPositionText(status)].compactMap { $0 }
        .joined(separator: "\n")
      content.textProperties.color = .secondaryLabel
    case .fixHint:
      content.text = L("nogps_sensors_hint_box")
      content.textProperties.color = .secondaryLabel
    case .firmware:
      // As the values under it: the version, or how its update goes.
      content = UIListContentConfiguration.valueCell()
      content.text = L("nogps_box_value_firmware")
      content.secondaryText = Self.firmwareText(status)
    case .firmwareAction:
      content.text = Self.canCancelFirmware(status) ? L("cancel")
        : String(format: L("nogps_firmware_install"), status.bundledFirmware)
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .value(let kind):
      content = UIListContentConfiguration.valueCell()
      content.text = Self.label(kind)
      content.secondaryText = valueText(kind)
      content.textProperties.numberOfLines = 0
      content.secondaryTextProperties.numberOfLines = 0
    case .speed:
      content.text = String(format: L("nogps_sensors_speed"), status.inertialStarted && status.speedKmh >= 0
        ? String(format: L("nogps_speed_kmh"), status.speedKmh) : L("nogps_unknown"))
    case .speedText:
      content.attributedText = speedHintText()
    case .carName:
      content = UIListContentConfiguration.valueCell()
      content.text = L("nogps_car_name")
      content.secondaryText = currentCar.map { NoGpsBoxSheet.carName($0) }
      cell.selectionStyle = .none
    case .speedLag:
      content = UIListContentConfiguration.subtitleCell()
      content.text = L("nogps_speed_lag")
      content.secondaryText = L(status.speedLagMeasured ? "nogps_speed_lag_measured" : "nogps_speed_lag_usual")
      content.secondaryTextProperties.color = .secondaryLabel
      // On the right in the middle of both lines, as the values of the other rows.
      speedLagValue.text = String(format: L("nogps_speed_lag_value"), String(format: "%.1f", status.speedLagSec))
      speedLagValue.sizeToFit()
      cell.accessoryView = speedLagValue
    case .clearSpeed:
      content.text = L("nogps_box_clear_speed")
      // Not as red as forgetting the car: the table is learned again on the next trips.
      content.textProperties.color = .systemOrange
      cell.selectionStyle = .default
    case .speedTableRange(let i):
      content.text = Self.speedTableRowText(status, i)
      content.directionalLayoutMargins.top = Constants.tableRowMargin
      content.directionalLayoutMargins.bottom = Constants.tableRowMargin
      content.textProperties.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                                               weight: .regular)
    case .calibration:
      content = UIListContentConfiguration.valueCell()
      content.text = L("nogps_box_calibration")
      content.secondaryText = Self.boxCalibrationText(status)
      content.textProperties.numberOfLines = 0
      content.secondaryTextProperties.numberOfLines = 0
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    }
    cell.contentConfiguration = content
    return cell
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .item(let part):
      navigationController?.pushViewController(NoGpsBoxPage(part: part, lastValues: lastValues), animated: true)
    case .firmwareAction:
      // The row does what it shows, if the update still allows it: the box may have gone on since it was drawn.
      let cancel = Self.canCancelFirmware(status)
      status = NoGps.status()
      if cancel, Self.canCancelFirmware(status) {
        NoGps.cancelFirmwareUpdate()
      } else if !cancel, Self.canInstallFirmware(status) {
        NoGps.startFirmwareUpdate()
      }
      refresh()
    case .clearSpeed:
      Self.confirmClearSpeed(from: self) { [weak self] in self?.refresh() }
    case .calibration:
      navigationController?.pushViewController(NoGpsCalibrationPage(), animated: true)
    default:
      break
    }
  }

  // MARK: - Texts

  /// "NonGPS-OBD, R1" once the box has told its hardware revision.
  private var boxModel: String {
    guard let revision = status.boxValues.first(where: { $0.kind == .revision })?.value, !revision.isEmpty else {
      return Constants.boxModel
    }
    return "\(Constants.boxModel), \(revision)"
  }

  private func itemTitle(_ part: Part) -> String {
    switch part {
    case .box: return String(format: L("nogps_box_section"), boxModel)
    case .obd: return L("nogps_box_value_group_obd")
    case .car:
      return currentCar.map { String(format: L("nogps_box_car"), NoGpsBoxSheet.carName($0)) } ?? L("nogps_box_value_group_car")
    case .speed: return L("nogps_speed_calibration")
    case .imu: return L("nogps_box_imu")
    }
  }

  private func itemSubtitle(_ part: Part) -> String {
    switch part {
    case .box:
      // The update tells how it goes instead of the state.
      let state = Self.isFirmwareUpdating(status) ? Self.firmwareText(status) : Self.boxStateText(status)
      let version = status.boxFirmware.isEmpty ? nil : String(format: L("nogps_box_version"), status.boxFirmware)
      return [version, NoGpsBoxPage.sentenceCase(state)].compactMap { $0 }.joined(separator: ", ")
    case .obd:
      return NoGpsBoxSheet.obdHintText(status) ?? NoGpsBoxPage.sentenceCase(Self.boxStateText(status))
    case .car:
      guard NoGpsBoxSheet.isBoxHeard(status), status.engineRunning >= 0 else { return L("nogps_unknown") }
      return NoGpsBoxPage.sentenceCase(L(status.engineRunning > 0 ? "nogps_engine_running" : "nogps_engine_stopped"))
    case .speed:
      return Self.speedTableText(status)
    case .imu:
      let parts = [NoGpsBoxValue.imuState, .imuTemperature].compactMap { kind -> String? in
        // Out of reach the values of the last connection are only "—".
        guard status.boxValues.contains(where: { $0.kind == kind }) else { return nil }
        return valueText(kind)
      }
      return parts.isEmpty ? L("nogps_unknown") : parts.joined(separator: " · ")
    }
  }

  /// The tyres make the car speed wrong: what is learned and what the user does for it.
  private func speedHintText() -> NSAttributedString {
    let font = UIFont.preferredFont(forTextStyle: .subheadline)
    let text = NSMutableAttributedString(string: L("nogps_speed_table_hint") + "\n",
                                         attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
    let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
    text.append(NSAttributedString(string: L("nogps_speed_table_action"),
                                   attributes: [.font: bold, .foregroundColor: UIColor.label]))
    return text
  }

  private var currentCar: NoGpsCar? {
    NoGps.cars().first { $0.carId == status.carId }
  }

  private func missingParts() -> [String] {
    var missing: [String] = []
    if status.speedKmh < 0 {
      missing.append(L("nogps_missing_speed"))
    }
    if status.calibration != .done {
      missing.append(L("nogps_missing_box_calibration"))
    }
    if !status.hasInertialPosition {
      missing.append(L("nogps_missing_position"))
    }
    return missing
  }

  /// "—" while the box is out of reach: the values are of the last connection.
  private func valueText(_ kind: NoGpsBoxValue) -> String {
    guard !status.boxValues.isEmpty, let value = status.boxValues.first(where: { $0.kind == kind })?.value
    else { return L("nogps_unknown") }
    if value.isEmpty {
      // The box asks the car for them while it stands.
      let standingOnly = kind == .rpm || kind == .elmVoltage || kind == .ecuVoltage
      return standingOnly && status.speedKmh > 0 ? L("nogps_not_while_driving") : L("nogps_unknown")
    }
    switch kind {
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
    case .revision: L("nogps_box_value_revision")
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

  // MARK: - Shared texts

  /// How many ranges of the car speed GPS has measured. The rough table by the roads doesn't count: it is only a guess.
  static func speedTableText(_ status: NoGpsStatus) -> String {
    let all = status.speedTableCarM.count
    if status.speedTableRanges == 0 {
      return L("nogps_speed_table_not_calibrated")
    }
    if status.speedTableRanges >= all {
      return L("nogps_speed_table_calibrated")
    }
    return String(format: L("nogps_speed_table_calibrating"), status.speedTableRanges, all)
  }

  static func speedTableRowText(_ status: NoGpsStatus, _ i: Int) -> String {
    let carM = status.speedTableCarM[i].doubleValue
    let scale = status.speedTableScale[i].doubleValue
    let value: String
    if scale > 0 {
      // The rough table from the roads is used while GPS has measured no range.
      value = (status.speedTableRanges == 0 ? "≈" : "") + String(format: "×%.2f", scale)
    } else if carM >= 1 {
      let left = max(1, Int((Double(Constants.speedTableMinDistanceM) - carM).rounded(.up)))
      value = String(format: L("nogps_speed_table_left"), left)
    } else {
      value = "—"
    }
    let from = max(Constants.speedTableMinKmh, i * Constants.speedTableRangeKmh)
    let to = (i + 1) * Constants.speedTableRangeKmh
    return String(format: L("nogps_speed_table_row"), from, to, value)
  }

  /// Also read out by the box segment of the bottom bar.
  static func boxStateText(_ status: NoGpsStatus) -> String {
    switch status.sourceState {
    case .disconnected: return L("nogps_elm_disconnected")
    case .connecting: return boxSearchText(status)
    case .noAdapter: return L("nogps_elm_no_adapter")
    case .obdDisabled: return L("nogps_box_obd_disabled")
    case .obdConnecting: return L("nogps_box_obd_connecting")
    case .obdError: return L("nogps_elm_error")
    case .noCarData: return L("nogps_elm_no_car")
    case .boxSleeping: return L("nogps_box_sleeping") + " · " + boxSearchText(status)
    // A locked-out box comes back only after it is unplugged, and a phone that can't reach it says so too.
    case .boxBatteryLock:
      return L("nogps_box_battery_lock") + (isBoxSearched(status) ? "" : " · " + boxSearchText(status))
    case .obdSleeping: return L("nogps_box_obd_sleeping")
    case .connected: return L("nogps_elm_connected")
    case .updating: return L("nogps_box_updating")
    @unknown default: return L("nogps_unknown")
    }
  }

  /// The phone looks for the box, or waits for it: Bluetooth is on and the box doesn't have to be paired again.
  private static func isBoxSearched(_ status: NoGpsStatus) -> Bool {
    switch status.bleState {
    case .off, .noPermission, .disabled, .pairingFailed, .bondLost: return false
    default: return true
    }
  }

  /// The box is not heard yet: what the phone does to reach it.
  private static func boxSearchText(_ status: NoGpsStatus) -> String {
    switch status.bleState {
    case .noPermission: return L("nogps_box_bt_no_permission")
    // Off: the phone has no Bluetooth LE.
    case .off, .disabled: return L("nogps_box_bt_disabled")
    case .searching: return L("nogps_box_bt_searching")
    case .pairingClosed: return L("nogps_box_bt_pairing_closed")
    case .pairingByPhone: return L("nogps_box_bt_pairing_by_phone")
    case .pairingFull: return L("nogps_box_bt_pairing_full")
    case .carLimit: return L("nogps_box_bt_car_limit")
    case .connecting: return L("nogps_box_bt_connecting")
    case .pairing: return L("nogps_box_bt_pairing")
    case .connected: return L("nogps_box_bt_waiting")
    case .pairingFailed: return L("nogps_box_bt_pairing_failed")
    case .bondLost: return L("nogps_box_bt_bond_lost")
    @unknown default: return L("nogps_unknown")
    }
  }

  static func boxCalibrationText(_ status: NoGpsStatus) -> String {
    let text: String
    switch status.inertialStarted ? status.calibration : .none {
    case .none: text = L("nogps_box_not_calibrated")
    case .calibrating: text = String(format: L("nogps_box_calibrating"), status.calibrationProgress)
    // The box keeps its calibration, but it may stand in another way since it was plugged in.
    case .done: text = L(status.boxCalibrationAdvised ? "nogps_box_calibration_advised" : "nogps_box_calibrated")
    case .failedMoving: text = L("nogps_box_calibration_failed")
    case .mountMoved: text = L("nogps_gyro_mount_moved")
    case .linkLost: text = L("nogps_box_calibration_link_lost")
    @unknown default: text = L("nogps_unknown")
    }
    return NoGpsBoxPage.sentenceCase(text)
  }

  /// The box should be calibrated and this phone can do it now: the map shows a bar until it is done.
  static func needsCalibration(_ status: NoGpsStatus) -> Bool {
    guard NoGpsBoxSheet.isBoxHeard(status), status.bleState == .connected, !status.boxReadOnly else { return false }
    switch status.calibration {
    case .none, .failedMoving, .mountMoved, .linkLost: return true
    case .done: return status.boxCalibrationAdvised
    default: return false
    }
  }

  /// The firmware of the box, or how its update goes.
  static func firmwareText(_ status: NoGpsStatus) -> String {
    switch status.firmwareUpdate {
    case .starting: return L("nogps_firmware_starting")
    case .sending: return String(format: L("nogps_firmware_sending"), status.firmwareUpdateProgress)
    case .verifying: return L("nogps_firmware_verifying")
    case .restarting: return L("nogps_firmware_restarting")
    case .none, .done, .failed: return status.boxFirmware
    @unknown default: return status.boxFirmware
    }
  }

  private static func isFirmwareUpdating(_ status: NoGpsStatus) -> Bool {
    [.starting, .sending, .verifying, .restarting].contains(status.firmwareUpdate)
  }

  /// A build may add a suffix to the version ("0.3.3-dirty"): the numbers tell the firmware.
  private static func firmwareNumbers(_ version: String) -> Substring {
    version.prefix { $0.isNumber || $0 == "." }
  }

  /// The box works with the firmware the app is tested with: there is nothing to install. A debug build sends it again
  /// to try the update itself.
  static func canInstallFirmware(_ status: NoGpsStatus) -> Bool {
    guard !isFirmwareUpdating(status), !status.bundledFirmware.isEmpty else { return false }
#if DEBUG
    return true
#else
    return firmwareNumbers(status.bundledFirmware) != firmwareNumbers(status.boxFirmware)
#endif
  }

  /// A box that has taken the whole firmware checks it and restarts by itself: it ignores OTA_ABORT after that, so
  /// the update can't be stopped any more.
  private static func canCancelFirmware(_ status: NoGpsStatus) -> Bool {
    isFirmwareUpdating(status) && ![.verifying, .restarting].contains(status.firmwareUpdate)
  }

  /// The states follow a label elsewhere ("Box: name ·"), here they start the line.
  static func sentenceCase(_ text: String) -> String {
    text.prefix(1).uppercased(with: .current) + text.dropFirst()
  }

  /// A text above a group of rows, read before them: not in capitals as a usual header.
  static func textHeader(_ text: NSAttributedString) -> UIView {
    let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
    var content = UIListContentConfiguration.groupedHeader()
    content.attributedText = text
    content.textProperties.transform = .none
    header.contentConfiguration = content
    return header
  }

  static func textHeader(_ text: String) -> UIView {
    textHeader(NSAttributedString(string: text, attributes: [
      .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.secondaryLabel,
    ]))
  }

  static func confirmClearSpeed(from controller: UIViewController, onCleared: @escaping () -> Void) {
    let alert = UIAlertController(title: L("nogps_clear_speed_title"),
                                  message: L("nogps_clear_speed_message"),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("nogps_clear_speed"), style: .destructive) { _ in
      NoGps.clearSpeedCalibration()
      onCleared()
    })
    controller.present(alert, animated: true)
  }
}

/// How and when the box is calibrated, its state and the button to start. Opened from the IMU section of the Box page
/// and from the bar on the map.
final class NoGpsCalibrationPage: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsCalibrationCell"
  }

  private enum Row: Equatable {
    case state
    case progress
    case start
  }

  private var status = NoGps.status()
  private var timer: Timer?
  private var rows: [[Row]] = []
  private var shownRows: [[Row]] = []
  private var footers: [String?] = []
  private var shownFooters: [String?] = []
  private let progress = UIProgressView(progressViewStyle: .default)

  init() {
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_box_calibration")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
  }

  /// The sheet fits this page: the progress and the result come and go.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    (navigationController?.viewControllers.first as? NoGpsBoxSheet)?.refit()
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
    let calibrating = status.calibration == .calibrating
    rows = [calibrating ? [.state, .progress] : [.state], calibrating ? [] : [.start]]
    footers = [resultText(), calibrating ? nil : startDisabledText()]
    progress.setProgress(Float(status.calibrationProgress) / 100, animated: true)
    // Footers are not updated in place.
    if footers != shownFooters {
      shownFooters = footers
      shownRows = []
    }
    tableView.reloadData(keepingRows: rows, &shownRows)
  }

  /// The box can calibrate only while it is connected and not to another phone.
  private var canStart: Bool {
    NoGpsBoxSheet.isBoxHeard(status) && status.bleState == .connected && !status.boxReadOnly
  }

  private func startDisabledText() -> String? {
    if !NoGpsBoxSheet.isBoxHeard(status) || status.bleState != .connected {
      return L("nogps_calibration_needs_box")
    }
    return status.boxReadOnly ? L("nogps_box_read_only") : nil
  }

  /// What went wrong and what the user does next.
  private func resultText() -> String? {
    switch status.calibration {
    case .failedMoving: L("nogps_calibration_failed_moving")
    case .mountMoved: L("nogps_calibration_failed_mount")
    case .linkLost: L("nogps_calibration_failed_link")
    default: nil
    }
  }

  // MARK: - UITableViewDataSource

  override func numberOfSections(in _: UITableView) -> Int {
    rows.count
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows[section].count
  }

  override func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    section == 0 ? NoGpsBoxPage.textHeader(L("nogps_box_calibration_hint") + "\n\n"
      + L("nogps_calibration_steps")) : nil
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    footers[section]
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.cell()
    content.textProperties.numberOfLines = 0
    cell.selectionStyle = .none
    switch rows[indexPath.section][indexPath.row] {
    case .state:
      content.text = NoGpsBoxPage.boxCalibrationText(status)
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      switch status.calibration {
      case .done where !status.boxCalibrationAdvised: content.textProperties.color = .systemGreen
      case .failedMoving, .mountMoved, .linkLost: content.textProperties.color = .systemRed
      default: break
      }
    case .progress:
      embed(progress, in: cell)
      return cell
    case .start:
      let again = status.calibration == .done && !status.boxCalibrationAdvised
      content.text = L(again ? "nogps_box_recalibrate" : "nogps_sensors_calibrate_box")
      content.textProperties.color = canStart ? .linkBlue : .secondaryLabel
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.textProperties.alignment = .center
      cell.selectionStyle = canStart ? .default : .none
    }
    cell.contentConfiguration = content
    return cell
  }

  /// The same view every refresh: its animation goes on.
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
      view.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
      cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
    ])
  }

  // MARK: - UITableViewDelegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard rows[indexPath.section][indexPath.row] == .start else { return }
    // The box may have gone out of reach since the row was drawn.
    status = NoGps.status()
    guard canStart else { return }
    NoGps.calibrate()
    refresh()
  }
}
