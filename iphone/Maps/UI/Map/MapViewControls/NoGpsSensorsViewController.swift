/// The state of the inertial navigation by the ESP32 sensor box: the box, the speed and its calibration. Without
/// the box it offers to buy or to connect one.
final class NoGpsSensorsViewController: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsSensorsCell"
    static let shopURL = URL(string: "https://non-gps.com")!
  }

  private enum Row {
    case buy
    case connect
    case box
    case firmware
    case firmwareAction
    case calibrate
    case boxSensors
    case speed
    case car
    case voltageMismatch
    case readiness
    case scale
    case clearSpeed
    case forget
  }

  private struct Section {
    var header: String?
    let rows: [Row]
    let footer: String?
  }

  private var sections: [Section] = []
  private var status = NoGps.status()
  private var timer: Timer?
  /// Called once the screen is closed.
  var onClose: (() -> Void)?

  init() {
    super.init(style: .grouped)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_sensors_title")
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 44
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
    // Closed by the button or swiped down.
    if navigationController?.isBeingDismissed ?? isBeingDismissed {
      onClose?()
      onClose = nil
    }
  }

  private func refresh() {
    status = NoGps.status()
    guard status.inertialEnabled else {
      sections = [
        Section(header: L("nogps_box_buy_title"), rows: [.buy], footer: L("nogps_box_buy_text")),
        Section(rows: [.connect], footer: nil),
      ]
      tableView.reloadData()
      return
    }
    var stateRows: [Row] = [.box]
    // The install row comes where a text was, not a button: a tap made as the box connects doesn't start an update.
    if isFirmwareUpdating() || !status.boxFirmware.isEmpty {
      stateRows.append(.firmware)
      if canInstallFirmware() || canCancelFirmware() {
        stateRows.append(.firmwareAction)
      }
    }
    stateRows.append(.speed)
    if status.inertialStarted, status.hasCarInfo {
      stateRows.append(.car)
      if status.voltageMismatch {
        stateRows.append(.voltageMismatch)
      }
    }
    if status.inertialStarted {
      stateRows.append(.readiness)
    }
    sections = [
      Section(rows: stateRows, footer: L("nogps_sensors_hint_box")),
      // The user calibrates the box when it is put into the car.
      Section(header: L("nogps_box_calibration"), rows: [.boxSensors, .calibrate],
              footer: L("nogps_box_calibration_hint")),
      Section(rows: [.scale, .clearSpeed], footer: nil),
      Section(rows: [.forget], footer: nil),
    ]
    tableView.reloadData()
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
    var content = cell.defaultContentConfiguration()
    content.textProperties.numberOfLines = 0
    cell.accessoryView = nil
    cell.selectionStyle = .none
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .buy:
      content.text = L("nogps_box_buy")
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .connect:
      content.text = L("nogps_box_connect")
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .forget:
      content.text = L("nogps_box_forget")
      content.textProperties.color = .buttonRed
      cell.selectionStyle = .default
    case .box:
      let name = status.inertialStarted && !status.deviceName.isEmpty ? status.deviceName : "ESP32"
      let box = status.inertialStarted ? name + " · " + Self.boxStateText(status) : name
      content.text = String(format: L("nogps_sensors_box"), box)
    case .firmware:
      content.text = String(format: L("nogps_sensors_firmware"), firmwareText())
    case .firmwareAction:
      content.text = canCancelFirmware() ? L("cancel") : String(format: L("nogps_firmware_install"), status.bundledFirmware)
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    case .calibrate:
      content.text = L("nogps_sensors_calibrate_box")
      content.textProperties.color = boxReachable() ? .linkBlue : .blackHintText
      cell.selectionStyle = boxReachable() ? .default : .none
    case .boxSensors:
      content.text = String(format: L("nogps_sensors_box_sensors"), boxCalibrationText())
    case .speed:
      let speed = status.inertialStarted ? status.speedKmh : -1
      content.text = String(format: L("nogps_sensors_speed"),
                            speed >= 0 ? String(format: L("nogps_speed_kmh"), speed) : L("nogps_unknown"))
    case .car:
      content.text = carText()
    case .voltageMismatch:
      content.text = L("nogps_voltage_mismatch")
      content.textProperties.color = .buttonRed
    case .readiness:
      let missing = missingParts()
      content.text = missing.isEmpty ? L("nogps_sensors_ready")
        : String(format: L("nogps_sensors_not_ready"), missing.joined(separator: ", "))
      content.textProperties.color = missing.isEmpty ? .linkBlue : .buttonRed
    case .scale:
      let scale = status.inertialStarted ? String(format: "×%.2f", status.speedScale) : L("nogps_unknown")
      var text = String(format: L("nogps_sensors_scale"), scale, status.inertialStarted ? status.speedTableRanges : 0)
      if status.inertialStarted {
        // Until GPS measures the speed, e.g. on the first trip, it is corrected roughly by the roads.
        if status.speedTableRanges == 0 {
          text += "\n" + (status.roughSpeedTableRanges > 0
            ? String(format: L("nogps_sensors_rough_speed"), status.roughSpeedTableRanges)
            : L("nogps_sensors_rough_speed_learning"))
        }
        let lag = L(status.speedLagMeasured ? "nogps_sensors_lag_measured" : "nogps_sensors_lag_usual")
        text += "\n" + String(format: lag, String(format: "%.1f", status.speedLagSec))
      }
      content.text = text
    case .clearSpeed:
      content.text = L("nogps_clear_speed")
      content.textProperties.color = .linkBlue
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
    case .connect:
      NoGps.setInertialNavigationEnabled(true)
      refresh()
    case .forget:
      NoGps.setInertialNavigationEnabled(false)
      // Nothing else would drive the car, the box was the only source.
      NoGps.setGpsDisabled(false)
      refresh()
    case .firmwareAction:
      // The row does what it shows, if the update still allows it: the box may have gone on since it was drawn.
      let cancel = canCancelFirmware()
      status = NoGps.status()
      if cancel, canCancelFirmware() {
        NoGps.cancelFirmwareUpdate()
      } else if !cancel, canInstallFirmware() {
        NoGps.startFirmwareUpdate()
      }
      refresh()
    case .calibrate:
      // The box calibrates itself: there is nobody to calibrate while it is out of reach.
      guard boxReachable() else { break }
      NoGps.calibrate()
      refresh()
    case .clearSpeed:
      confirmClearSpeed()
    default:
      break
    }
  }

  // MARK: - Texts

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
    case .boxSleeping: return L("nogps_box_sleeping")
    case .obdSleeping: return L("nogps_box_obd_sleeping")
    case .connected: return L("nogps_elm_connected")
    case .updating: return L("nogps_box_updating")
    @unknown default: return L("nogps_unknown")
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
    case .connecting: return L("nogps_box_bt_connecting")
    case .pairing: return L("nogps_box_bt_pairing")
    case .connected: return L("nogps_box_bt_waiting")
    @unknown default: return L("nogps_unknown")
    }
  }

  private func boxCalibrationText() -> String {
    switch status.inertialStarted ? status.calibration : .none {
    case .none: return L("nogps_box_not_calibrated")
    case .calibrating: return String(format: L("nogps_box_calibrating"), status.calibrationProgress)
    // The box keeps its calibration, but it may stand in another way since it was plugged in.
    case .done: return L(status.boxCalibrationAdvised ? "nogps_box_calibration_advised" : "nogps_box_calibrated")
    case .failedMoving: return L("nogps_box_calibration_failed")
    case .mountMoved: return L("nogps_gyro_mount_moved")
    @unknown default: return L("nogps_unknown")
    }
  }

  /// The firmware of the box, or how its update goes.
  private func firmwareText() -> String {
    switch status.firmwareUpdate {
    case .starting: return L("nogps_firmware_starting")
    case .sending: return String(format: L("nogps_firmware_sending"), status.firmwareUpdateProgress)
    case .verifying: return L("nogps_firmware_verifying")
    case .restarting: return L("nogps_firmware_restarting")
    case .none, .done, .failed: return status.boxFirmware
    @unknown default: return status.boxFirmware
    }
  }

  private func boxReachable() -> Bool {
    status.bleState == .connected
  }

  private func isFirmwareUpdating() -> Bool {
    [.starting, .sending, .verifying, .restarting].contains(status.firmwareUpdate)
  }

  /// The box works with the firmware the app is tested with: there is nothing to install. A debug build sends it again
  /// to try the update itself.
  private func canInstallFirmware() -> Bool {
    guard !isFirmwareUpdating(), !status.bundledFirmware.isEmpty else { return false }
#if DEBUG
    return true
#else
    return status.bundledFirmware != status.boxFirmware
#endif
  }

  /// A box that has taken the firmware restarts by itself.
  private func canCancelFirmware() -> Bool {
    isFirmwareUpdating() && status.firmwareUpdate != .restarting
  }

  /// What the box tells about the car: the engine and the voltage measured by the box and by ELM327.
  private func carText() -> String {
    // The box measures its own voltage all the time and asks the car for the rest only while it stands, not to delay
    // the speed.
    let unknown = L(status.speedKmh > 0 ? "nogps_not_while_driving" : "nogps_unknown")
    let engine = status.engineRunning < 0 ? L("nogps_unknown")
      : L(status.engineRunning > 0 ? "nogps_engine_running" : "nogps_engine_stopped")
    let rpm = status.rpm >= 0 ? String(format: L("nogps_rpm"), status.rpm) : unknown
    let box = status.boxMillivolts >= 0 ? volts(status.boxMillivolts) : L("nogps_unknown")
    let elm = status.elmMillivolts >= 0 ? volts(status.elmMillivolts) : unknown
    let ecu = status.ecuMillivolts >= 0 ? volts(status.ecuMillivolts) : unknown
    return String(format: L("nogps_sensors_car"), engine, rpm, box, elm, ecu)
  }

  private func volts(_ millivolts: Int) -> String {
    String(format: L("nogps_volts"), String(format: "%.1f", Double(millivolts) / 1000))
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

  // MARK: - Actions

  private func confirmClearSpeed() {
    let alert = UIAlertController(title: L("nogps_clear_speed_title"),
                                  message: L("nogps_clear_speed_message"),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("nogps_clear_speed"), style: .destructive) { [weak self] _ in
      NoGps.clearSpeedCalibration()
      self?.refresh()
    })
    present(alert, animated: true)
  }

  @objc
  private func close() {
    dismiss(animated: true)
  }
}
