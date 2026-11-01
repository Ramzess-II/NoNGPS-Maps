/// What GPS is worth now and why, whether the car follows it, and the details of its last position.
final class NoGpsGpsSheet: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 1
    static let cellId = "NoGpsGpsCell"
    /// An older position tells nothing about GPS now.
    static let maxFixAge: TimeInterval = 10
  }

  private enum Row {
    case state
    case use
    case lastFix
    case accuracy
    case speedCourse
    case network
    case fixSource
    case settings
  }

  private struct Section {
    let rows: [Row]
    var footer: String?
  }

  private var sections: [Section] = []
  private var status = NoGps.status()
  private var timer: Timer?
  private let useSwitch = UISwitch()
  private var shownRows: [[Row]] = []

  static func show() {
    NoGpsControls.showSheet(NoGpsGpsSheet(style: .insetGrouped))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_status_gps")
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self,
                                                        action: #selector(close))
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    useSwitch.addTarget(self, action: #selector(useChanged), for: .valueChanged)
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

  private func refresh() {
    status = NoGps.status()
    var details: [Row] = [.lastFix, .accuracy, .speedCourse]
    if status.workingNetworkAccuracyM >= 0 {
      details.append(.network)
    }
    sections = [
      Section(rows: [.state]),
      Section(rows: [.use], footer: L("nogps_gps_use_hint")),
      Section(rows: details),
      Section(rows: [.fixSource]),
      Section(rows: [.settings]),
    ]
    tableView.reloadData(keepingRows: sections.map(\.rows), &shownRows)
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
    var content = UIListContentConfiguration.valueCell()
    cell.accessoryView = nil
    cell.selectionStyle = .none
    let location = NoGps.lastPlatformLocation().flatMap { -$0.timestamp.timeIntervalSinceNow <= Constants.maxFixAge
      ? $0 : nil
    }
    switch sections[indexPath.section].rows[indexPath.row] {
    case .state:
      content = UIListContentConfiguration.subtitleCell()
      let look = NoGpsStatusBar.gpsLook(status)
      content.image = look.image
      content.imageProperties.tintColor = look.color
      content.text = NoGpsStatusBar.gpsStateText(status)
      content.textProperties.font = .preferredFont(forTextStyle: .headline)
      content.textProperties.color = look.color == .secondaryLabel ? .label : look.color
      content.secondaryText = NoGpsStatusBar.gpsWhyText(status)
      content.secondaryTextProperties.color = .secondaryLabel
    case .use:
      content = UIListContentConfiguration.cell()
      content.text = L("nogps_gps_use")
      // GPS is turned off for the car only while the box can drive it: nothing would move the mark otherwise.
      useSwitch.isEnabled = status.gpsDisabled || NoGpsBoxSheet.isBoxHeard(status)
      if !useSwitch.isTracking {
        useSwitch.isOn = !status.gpsDisabled
      }
      cell.accessoryView = useSwitch
    case .lastFix:
      content.text = L("nogps_gps_last_fix")
      content.secondaryText = status.lastGoodGpsAge < 0 ? "—" : Self.agoText(status.lastGoodGpsAge)
    case .accuracy:
      content.text = L("nogps_gps_accuracy")
      content.secondaryText = location.map(Self.accuracyText) ?? "—"
    case .speedCourse:
      content.text = L("nogps_gps_speed_course")
      content.secondaryText = location.map(Self.speedCourseText) ?? "—"
    case .network:
      content.text = L("nogps_gps_network")
      content.secondaryText = "±" + NoGpsControls.formatAccuracy(status.workingNetworkAccuracyM)
    case .fixSource:
      content.text = L("nogps_gps_fix_source")
      content.secondaryText = location.map(Self.fixSourceText) ?? "—"
    case .settings:
      content = UIListContentConfiguration.cell()
      content.text = L("location_settings")
      content.textProperties.color = .linkBlue
      cell.selectionStyle = .default
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if sections[indexPath.section].rows[indexPath.row] == .settings,
       let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  }

  // MARK: - Texts

  private static func agoText(_ age: TimeInterval) -> String {
    let seconds = Int(age.rounded())
    if seconds < 60 {
      return String(format: L("nogps_gps_ago_s"), seconds)
    }
    if seconds < 3600 {
      return String(format: L("nogps_gps_ago_min"), seconds / 60)
    }
    return String(format: L("nogps_gps_ago_h"), seconds / 3600)
  }

  private static func accuracyText(_ location: CLLocation) -> String {
    var text = "±" + NoGpsControls.formatAccuracy(location.horizontalAccuracy)
    if location.verticalAccuracy >= 0 {
      text += " · " + String(format: L("nogps_gps_height"), NoGpsControls.formatAccuracy(location.verticalAccuracy))
    }
    return text
  }

  private static func speedCourseText(_ location: CLLocation) -> String {
    let speed = location.speed >= 0 ? String(format: L("nogps_speed_kmh"), Int((location.speed * 3.6).rounded())) : "—"
    let course = location.course >= 0 ? "\(Int(location.course.rounded()))°" : "—"
    return speed + " · " + course
  }

  /// The phone, an accessory such as a CarPlay car, or a program has given the position.
  private static func fixSourceText(_ location: CLLocation) -> String {
    guard let source = location.sourceInformation else { return L("nogps_gps_fix_phone") }
    var parts = [L(source.isProducedByAccessory ? "nogps_gps_fix_accessory" : "nogps_gps_fix_phone")]
    if source.isSimulatedBySoftware {
      parts.append(L("nogps_gps_fix_simulated"))
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Actions

  @objc
  private func useChanged() {
    NoGps.setGpsDisabled(!useSwitch.isOn)
    refresh()
    NoGpsStatusBar.update(status)
  }

  @objc
  private func close() {
    dismiss(animated: true)
  }
}
