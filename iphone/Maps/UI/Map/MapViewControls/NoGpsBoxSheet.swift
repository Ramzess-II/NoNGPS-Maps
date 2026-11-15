/// The sensor box and GPS of the car side by side: each tile opens its page, the title opens the cars. GPS is blocked
/// for the car here. Without a box it is searched while the sheet is open, step by step, and the sheet offers to buy
/// one.
final class NoGpsBoxSheet: MWMTableViewController, UINavigationControllerDelegate {
  /// Where the sheet opens: the map leads the user to the Box page or to the calibration.
  enum Page: Equatable {
    case main
    /// \param firmware unfolds the Box section to show how the update goes.
    case box(firmware: Bool)
    case calibration
  }

  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxCell"
    static let shopURL = URL(string: "https://non-gps.com")!
    static let fitDetent = "fit"
  }

  private enum Row: Equatable {
    case linkAction
    case gpsBlock
    case search
    case buy
  }

  private struct Section {
    let rows: [Row]
    var footer: String?
  }

  private var sections: [Section] = []
  private var status = NoGps.status()
  private var timer: Timer?
  /// No box was set up when the sheet opened: it is searched until it is heard, and forgotten if the sheet is closed
  /// before it is found.
  private var searching = false
  private let searchView = BoxSearchView()
  private let header = StatusTilesView()
  private let titleButton = UIButton(type: .system)
  private var shownTitle: String?
  private let gpsBlock = UISwitch()
  private let gpsBlockFooter = GpsBlockFooterView()

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

  static func show(_ page: Page = .main) {
    // The pages of the box tell nothing once it is forgotten.
    let page = NoGps.status().inertialEnabled ? page : .main
    if let navigation = shownSheet() {
      // An alert over the sheet, e.g. the firmware offer it was opened from.
      if let presented = navigation.presentedViewController, !presented.isBeingDismissed {
        presented.dismiss(animated: true)
      }
      open(page, in: navigation, animated: true)
      return
    }
    let root = NoGpsBoxSheet(style: .insetGrouped)
    let navigation = UINavigationController(rootViewController: root)
    navigation.delegate = root
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      if #available(iOS 16.0, *) {
        sheet.detents = [.custom(identifier: .init(Constants.fitDetent)) { [weak root] context in
          root.map { min($0.sheetHeight, context.maximumDetentValue) }
        }, .large()]
        // The rows are laid out before the sheet is: it opens at their height, not at the bar only.
        navigation.view.frame = UIViewController.topViewController().view.window?.bounds ?? UIScreen.main.bounds
        navigation.view.layoutIfNeeded()
      }
      sheet.prefersGrabberVisible = true
    }
    open(page, in: navigation, animated: false)
    UIViewController.topViewController().present(navigation, animated: true)
  }

  private static func shownSheet() -> UINavigationController? {
    var shown: UIViewController? = UIViewController.topViewController()
    while let controller = shown {
      if let navigation = controller as? UINavigationController, navigation.viewControllers.first is NoGpsBoxSheet {
        return navigation
      }
      shown = controller.presentingViewController
    }
    return nil
  }

  private static func open(_ page: Page, in navigation: UINavigationController, animated: Bool) {
    guard let root = navigation.viewControllers.first as? NoGpsBoxSheet else { return }
    switch page {
    case .main:
      break
    case .box(let firmware):
      if let boxPage = navigation.topViewController as? NoGpsBoxPage {
        if firmware {
          boxPage.unfold(.box)
        }
      } else {
        navigation.setViewControllers([root, NoGpsBoxPage(unfolded: firmware ? [.box] : [])], animated: animated)
      }
    case .calibration:
      if !(navigation.topViewController is NoGpsCalibrationPage) {
        navigation.setViewControllers([root, NoGpsBoxPage(unfolded: [.imu]), NoGpsCalibrationPage()], animated: animated)
      }
    }
    root.selectDetent(for: navigation.topViewController)
  }

  /// The sheet fits the tiles and the few rows under them, the pages take the whole height.
  private var sheetHeight: CGFloat {
    Self.barBottom + tableView.contentSize.height
  }

  private func selectDetent(for controller: UIViewController?) {
    guard let sheet = navigationController?.sheetPresentationController else { return }
    var detent = UISheetPresentationController.Detent.Identifier.large
    if controller === self {
      if #available(iOS 16.0, *) {
        detent = .init(Constants.fitDetent)
      } else {
        detent = .medium
      }
    }
    // Nothing selected is the first detent, the fitted one.
    let selected = sheet.selectedDetentIdentifier
    guard selected != detent, selected != nil || detent == .large else { return }
    sheet.animateChanges { sheet.selectedDetentIdentifier = detent }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.backButtonTitle = L("nogps_box_title")
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self,
                                                        action: #selector(close))
    titleButton.addTarget(self, action: #selector(openCars), for: .touchUpInside)
    navigationItem.titleView = titleButton
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    tableView.tableHeaderView = header
    searchView.onAction = { [weak self] in
      Self.onLinkAction()
      self?.refresh()
    }
    header.box.addTarget(self, action: #selector(openBox), for: .touchUpInside)
    header.gps.addTarget(self, action: #selector(openGps), for: .touchUpInside)
    gpsBlock.accessibilityLabel = L("nogps_gps_block")
    gpsBlock.addTarget(self, action: #selector(gpsBlockChanged), for: .valueChanged)
    if !status.inertialEnabled {
      searching = true
      NoGps.setInertialNavigationEnabled(true)
    }
    refresh()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refresh()
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
    // Not when a page is opened over it.
    if navigationController?.isBeingDismissed ?? isBeingDismissed {
      stopSearchIfNotFound()
    }
  }

  // MARK: - UINavigationControllerDelegate

  func navigationController(_: UINavigationController, willShow viewController: UIViewController, animated _: Bool) {
    selectDetent(for: viewController)
  }

  /// Closed by the button or swiped down, from either page, before the box was heard, even if connected already: the
  /// phone stops looking for it.
  func stopSearchIfNotFound() {
    guard searching else { return }
    if !Self.isBoxHeard(NoGps.status()) {
      NoGps.setInertialNavigationEnabled(false)
    }
    NoGpsStatusBar.update(NoGps.status())
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
      : status.inertialEnabled ? NoGpsBoxPage.boxStateText(status) : L("nogps_box_buy_title"))
    header.box.opensPage = status.inertialEnabled && !searching
    header.gps.show(NoGpsStatusBar.gpsLook(status), state: NoGpsStatusBar.gpsStateText(status))
    layoutHeader()
    updateTitle()
    // GPS is blocked for the car only while the box can drive it: nothing would move the mark otherwise.
    let canChangeGpsBlock = status.gpsDisabled || Self.isBoxHeard(status)
    gpsBlock.isEnabled = canChangeGpsBlock
    if !gpsBlock.isTracking {
      gpsBlock.isOn = status.gpsDisabled
    }
    gpsBlockFooter.update(canChange: canChangeGpsBlock)
    let gps = Section(rows: [.gpsBlock])
    if searching {
      searchView.update(status)
      sections = [
        gps,
        Section(rows: [.search], footer: L("nogps_box_power_hint") + "\n\n" + L("nogps_box_buy_text")),
        Section(rows: [.buy]),
      ]
    } else if status.inertialEnabled {
      // The steps of the search have their own button.
      sections = Self.linkActionText(status.bleState) == nil ? [] : [Section(rows: [.linkAction])]
      sections += [gps, Section(rows: [.buy])]
    } else {
      // The last car is forgotten.
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

  /// The car driven now opens the cars. Without a box set up there are none.
  private func updateTitle() {
    let opensCars = status.inertialEnabled && !searching
    let car = opensCars ? NoGps.cars().first { $0.carId == status.carId } : nil
    let title = !opensCars ? L("nogps_box_title") : car.map { Self.carName($0) } ?? L("nogps_cars")
    guard title != shownTitle || titleButton.isUserInteractionEnabled != opensCars else { return }
    shownTitle = title
    var config = UIButton.Configuration.plain()
    config.title = title
    config.baseForegroundColor = .label
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .preferredFont(forTextStyle: .headline)
      return attributes
    }
    if opensCars {
      config.image = UIImage(systemName: "chevron.forward",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
      config.imagePlacement = .trailing
      config.imagePadding = 4
    }
    titleButton.configuration = config
    titleButton.isUserInteractionEnabled = opensCars
    titleButton.accessibilityTraits = opensCars ? .button : .header
    titleButton.sizeToFit()
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

  /// The box sends its data: it is connected, whatever it tells.
  static func isBoxHeard(_ status: NoGpsStatus) -> Bool {
    status.inertialStarted && status.sourceState != .disconnected && status.sourceState != .connecting
  }

  /// What the user does for the phone to reach the box, nil if nothing: the steps and their button tell the rest.
  static func linkHintText(_ ble: NoGpsBleState) -> String? {
    let text: String
    switch ble {
    case .pairingClosed: text = L("nogps_box_bt_pairing_closed")
    case .pairingByPhone: text = L("nogps_box_bt_pairing_by_phone")
    case .pairingFull: text = L("nogps_box_bt_pairing_full")
    case .pairing: text = L("nogps_box_bt_pairing")
    case .pairingFailed: text = L("nogps_box_bt_pairing_failed")
    case .bondLost: text = L("nogps_box_bt_bond_lost")
    default: return nil
    }
    return NoGpsBoxPage.sentenceCase(text)
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

  /// "Car C47D" until the user names it.
  static func carName(_ car: NoGpsCar) -> String {
    car.name.isEmpty ? String(format: L("nogps_car_default_name"), car.carId) : car.name
  }

  /// Bluetooth is allowed in the settings: once refused, iOS doesn't ask again. The box is searched again after a failed
  /// pairing or a lost bond.
  static func onLinkAction() {
    guard NoGps.status().bleState == .noPermission else {
      NoGps.retryBox()
      return
    }
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
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

  override func tableView(_: UITableView, viewForFooterInSection section: Int) -> UIView? {
    sections[section].rows == [.gpsBlock] ? gpsBlockFooter : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.cell()
    content.textProperties.numberOfLines = 0
    cell.selectionStyle = .none
    let row = sections[indexPath.section].rows[indexPath.row]
    // The same switch every refresh: it is not reset while it is turned.
    cell.accessoryView = row == .gpsBlock ? gpsBlock : nil
    switch row {
    case .search:
      BoxSearchView.embed(searchView, in: cell)
      return cell
    case .gpsBlock:
      content.text = L("nogps_gps_block")
    case .linkAction:
      content.text = Self.linkActionText(status.bleState)
      content.textProperties.color = .linkBlue
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
    case .linkAction:
      Self.onLinkAction()
      refresh()
    case .buy:
      UIApplication.shared.open(Constants.shopURL)
    default:
      break
    }
    NoGpsStatusBar.update(NoGps.status())
  }

  // MARK: - Actions

  @objc
  private func openGps() {
    navigationController?.pushViewController(NoGpsGpsSheet(style: .insetGrouped), animated: true)
  }

  @objc
  private func openBox() {
    navigationController?.pushViewController(NoGpsBoxPage(), animated: true)
  }

  @objc
  private func openCars() {
    navigationController?.pushViewController(CarsViewController(style: .insetGrouped), animated: true)
  }

  @objc
  private func gpsBlockChanged() {
    NoGps.setGpsDisabled(gpsBlock.isOn)
    refresh()
    NoGpsStatusBar.update(NoGps.status())
  }

  @objc
  private func close() {
    dismiss(animated: true)
  }
}

/// The cars of the user, one for each box: the user drives, names or forgets one, and adds a new one.
private final class CarsViewController: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsCarCell"
  }

  private enum Row: Equatable {
    /// A car by the id of its box.
    case car(String)
    case add
  }

  private var status = NoGps.status()
  private var cars: [NoGpsCar] = []
  private var rows: [[Row]] = []
  private var shownRows: [[Row]] = []
  private var timer: Timer?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_cars")
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
    cars = NoGps.cars()
    rows = [cars.map { .car($0.carId) }, cars.count < NoGps.maxCars() ? [.add] : []]
    tableView.reloadData(keepingRows: rows, &shownRows)
  }

  override func numberOfSections(in _: UITableView) -> Int {
    rows.count
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows[section].count
  }

  override func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    section == 0 ? NoGpsBoxPage.textHeader(L("nogps_cars_text")) : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    cell.selectionStyle = .default
    switch rows[indexPath.section][indexPath.row] {
    case .car(let carId):
      if let car = cars.first(where: { $0.carId == carId }) {
        content.text = NoGpsBoxSheet.carName(car)
        content.secondaryText = carStateText(car)
      }
      content.secondaryTextProperties.color = .secondaryLabel
    case .add:
      content = UIListContentConfiguration.cell()
      content.text = L("nogps_car_add")
      content.textProperties.color = .linkBlue
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch rows[indexPath.section][indexPath.row] {
    case .car(let carId):
      if let car = cars.first(where: { $0.carId == carId }) {
        showCarMenu(car, from: tableView.cellForRow(at: indexPath))
      }
    case .add:
      navigationController?.pushViewController(AddCarViewController(style: .insetGrouped), animated: true)
    }
  }

  private func carStateText(_ car: NoGpsCar) -> String? {
    if car.carId == status.carId {
      let connected = NoGpsBoxSheet.isBoxHeard(status) && status.bleState == .connected
      return connected ? L("nogps_car_connected") : L("nogps_car_current")
    }
    guard let lastSeen = car.lastSeen else { return nil }
    return String(format: L("nogps_car_last_seen"), RelativeDateTimeFormatter().localizedString(for: lastSeen,
                                                                                                relativeTo: Date()))
  }

  /// What the user does with a car: drives it, names it or forgets it.
  private func showCarMenu(_ car: NoGpsCar, from cell: UITableViewCell?) {
    let menu = UIAlertController(title: NoGpsBoxSheet.carName(car), message: nil, preferredStyle: .actionSheet)
    if car.carId != NoGps.status().carId {
      menu.addAction(UIAlertAction(title: L("nogps_car_drive"), style: .default) { [weak self] _ in
        NoGps.selectCar(car.carId)
        NoGpsStatusBar.update(NoGps.status())
        self?.refresh()
      })
    }
    if car.carId == NoGps.status().carId, NoGps.status().boxHasPhones {
      menu.addAction(UIAlertAction(title: L("nogps_car_phones"), style: .default) { [weak self] _ in
        NoGps.listBoxPhones()
        self?.navigationController?.pushViewController(BoxPhonesViewController(style: .insetGrouped), animated: true)
      })
    }
    menu.addAction(UIAlertAction(title: L("nogps_car_rename"), style: .default) { [weak self] _ in
      self?.renameCar(car)
    })
    menu.addAction(UIAlertAction(title: L("nogps_car_forget"), style: .destructive) { [weak self] _ in
      self?.confirmForgetCar(car)
    })
    menu.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    if let popover = menu.popoverPresentationController, let cell {
      popover.sourceView = cell
      popover.sourceRect = cell.bounds
    }
    present(menu, animated: true)
  }

  private func renameCar(_ car: NoGpsCar) {
    let alert = UIAlertController(title: L("nogps_car_name"), message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = car.name
      field.placeholder = String(format: L("nogps_car_default_name"), car.carId)
      field.autocapitalizationType = .sentences
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("save"), style: .default) { [weak self, weak alert] _ in
      NoGps.renameCar(car.carId, name: alert?.textFields?.first?.text ?? "")
      self?.refresh()
    })
    present(alert, animated: true)
  }

  private func confirmForgetCar(_ car: NoGpsCar) {
    let alert = UIAlertController(title: NoGpsBoxSheet.carName(car), message: L("nogps_car_forget_text"),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("nogps_car_forget"), style: .destructive) { [weak self] _ in
      NoGps.forgetCar(car.carId)
      NoGpsStatusBar.update(NoGps.status())
      // The last car: the box is not looked for, the sheet offers to buy one.
      if !NoGps.status().inertialEnabled {
        self?.navigationController?.dismiss(animated: true)
      } else {
        self?.refresh()
      }
    })
    present(alert, animated: true)
  }
}

/// The box of a new car is searched step by step, as the first one: the box connected now is dropped, the other cars
/// stay. The search ends when the list of the cars grows: the box of a car is heard before, and a box sleeping after
/// its link was dropped is taken as heard too.
private final class AddCarViewController: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsAddCarCell"
  }

  private let searchView = BoxSearchView()
  private let carsBefore = NoGps.cars().count
  private var timer: Timer?

  private var isCarAdded: Bool {
    NoGps.cars().count > carsBefore
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_car_add")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    searchView.onAction = { [weak self] in
      NoGpsBoxSheet.onLinkAction()
      self?.refresh()
    }
    NoGps.searchNewBox(true)
    NoGpsStatusBar.update(NoGps.status())
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

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Back or the sheet closed before the new box was heard: the boxes of the other cars are looked for again.
    if isMovingFromParent || navigationController?.isBeingDismissed == true, !isCarAdded {
      NoGps.searchNewBox(false)
      NoGpsStatusBar.update(NoGps.status())
    }
  }

  private func refresh() {
    guard !isCarAdded else {
      if navigationController?.topViewController === self {
        navigationController?.popViewController(animated: true)
      }
      return
    }
    searchView.update(NoGps.status())
  }

  override func numberOfSections(in _: UITableView) -> Int {
    1
  }

  override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
    1
  }

  override func tableView(_: UITableView, viewForHeaderInSection _: Int) -> UIView? {
    NoGpsBoxPage.textHeader(L("nogps_car_add_text"))
  }

  override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
    L("nogps_box_power_hint")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    cell.selectionStyle = .none
    BoxSearchView.embed(searchView, in: cell)
    return cell
  }
}

/// The phones paired with the box of the car: a tap removes one, the last row adds a new one with a one-time code.
private final class BoxPhonesViewController: MWMTableViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cellId = "NoGpsBoxPhoneCell"
  }

  private var status = NoGps.status()
  private var timer: Timer?
  /// Shows the code for a new phone while the box takes it.
  private weak var addPhoneAlert: UIAlertController?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_car_phones")
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

  private var phones: [NoGpsPhone] { status.boxPhones ?? [] }

  private func refresh() {
    status = NoGps.status()
    // The box has disconnected: its phones are not known.
    if !status.boxHasPhones, addPhoneAlert == nil, navigationController?.topViewController === self {
      navigationController?.popViewController(animated: true)
      return
    }
    addPhoneAlert?.message = addPhoneText()
    tableView.reloadData()
  }

  override func numberOfSections(in _: UITableView) -> Int {
    2
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? phones.count : 1
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    section == 0 && status.boxReadOnly ? L("nogps_box_read_only") : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    cell.selectionStyle = status.boxReadOnly ? .none : .default
    if indexPath.section == 0 {
      let phone = phones[indexPath.row]
      content.text = Self.phoneName(phone)
      content.secondaryText = phoneStateText(phone)
      content.secondaryTextProperties.color = .secondaryLabel
    } else {
      content = UIListContentConfiguration.cell()
      content.text = L("nogps_phone_add")
      content.textProperties.color = status.boxReadOnly ? .secondaryLabel : .linkBlue
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !status.boxReadOnly else { return }
    if indexPath.section == 0 {
      confirmRemove(phones[indexPath.row])
    } else {
      addPhone()
    }
  }

  private static func phoneName(_ phone: NoGpsPhone) -> String {
    phone.name.isEmpty ? L("nogps_phone_unnamed") : phone.name
  }

  private func phoneStateText(_ phone: NoGpsPhone) -> String? {
    if phone.thisPhone {
      return L("nogps_phone_this")
    }
    guard let lastSeen = phone.lastSeen else { return nil }
    return String(format: L("nogps_car_last_seen"), RelativeDateTimeFormatter().localizedString(for: lastSeen,
                                                                                                relativeTo: Date()))
  }

  private func confirmRemove(_ phone: NoGpsPhone) {
    let alert = UIAlertController(title: Self.phoneName(phone),
                                  message: phone.thisPhone ? L("nogps_phone_remove_this_text") : L("nogps_phone_remove_text"),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("nogps_phone_remove"), style: .destructive) { [weak self] _ in
      NoGps.forgetBoxPhone(phone.address)
      self?.refresh()
    })
    present(alert, animated: true)
  }

  /// The box takes a new phone with a code shown here: the user enters it on the new phone.
  private func addPhone() {
    NoGps.startAddPhone()
    status = NoGps.status()
    let alert = UIAlertController(title: L("nogps_phone_add"), message: addPhoneText(), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("close"), style: .cancel) { _ in NoGps.endAddPhone() })
    addPhoneAlert = alert
    present(alert, animated: true)
  }

  private func addPhoneText() -> String {
    switch status.addPhone {
    case .open:
      let left = String(format: "%d:%02d", status.addPhoneSecondsLeft / 60, status.addPhoneSecondsLeft % 60)
      return status.addPhoneCode + "\n\n" + String(format: L("nogps_phone_add_code"), left)
    case .added: return L("nogps_phone_added")
    case .expired: return L("nogps_phone_add_expired")
    case .full: return L("nogps_phone_add_full")
    case .failed: return L("nogps_phone_add_failed")
    default: return L("nogps_phone_add_opening")
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
        : [.searching, .pairingClosed, .pairingByPhone, .pairingFull].contains(ble) ? .current : .waiting,
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

  /// A row of the search, the same view every refresh: its animation goes on.
  static func embed(_ view: BoxSearchView, in cell: UITableViewCell) {
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
}

/// The top of the Box sheet: the box and GPS side by side, each opens its page.
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
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.forward",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 13,
                                                                                                  weight: .semibold)))
  private var stateHeight: NSLayoutConstraint!
  private var look: NoGpsStatusBar.Look?

  var opensPage: Bool {
    didSet {
      guard opensPage != oldValue else { return }
      updateOpensPage()
    }
  }

  init(title: String, opensPage: Bool) {
    self.opensPage = opensPage
    super.init(frame: .zero)
    backgroundColor = .secondarySystemGroupedBackground
    layer.cornerRadius = Constants.cornerRadius
    layer.cornerCurve = .continuous
    isAccessibilityElement = true
    accessibilityLabel = title
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
    chevron.tintColor = .tertiaryLabel
    chevron.translatesAutoresizingMaskIntoConstraints = false
    addSubview(chevron)
    NSLayoutConstraint.activate([
      chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      chevron.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
    ])
    addTarget(self, action: #selector(pressed), for: [.touchDown, .touchDragEnter])
    addTarget(self, action: #selector(released), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    updateOpensPage()
  }

  private func updateOpensPage() {
    accessibilityTraits = opensPage ? .button : .none
    isUserInteractionEnabled = opensPage
    chevron.isHidden = !opensPage
    // The press is dropped if the tile stops opening the page under a finger.
    backgroundColor = .secondarySystemGroupedBackground
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
    stateLabel.text = NoGpsBoxPage.sentenceCase(text)
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

/// Why GPS can be blocked for the car, or why not. Both texts take their place: the sheet doesn't jump as the box comes
/// and goes.
private final class GpsBlockFooterView: UITableViewHeaderFooterView {
  private let hint = UILabel()
  private let needsBox = UILabel()

  init() {
    super.init(reuseIdentifier: nil)
    hint.text = L("nogps_gps_block_hint")
    needsBox.text = L("nogps_gps_block_needs_box")
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

  func update(canChange: Bool) {
    hint.alpha = canChange ? 1 : 0
    needsBox.alpha = canChange ? 0 : 1
    hint.accessibilityElementsHidden = !canChange
    needsBox.accessibilityElementsHidden = canChange
  }
}
