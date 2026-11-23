/// What the Profile screen shows for each car: the best time of each timed run. Pure, so it is testable.
enum NoGpsProfile {
  /// A timed run of a car, as the core keeps it.
  struct Run: Equatable {
    let kind: NoGpsSprintKind
    let sec: Double
    let trapKmh: Int
  }

  struct Row: Equatable {
    let title: String
    let value: String
  }

  struct Group: Equatable {
    let carId: String
    let title: String
    let rows: [Row]
  }

  /// One group for each car in the order they were added: 0-100 km/h and 1/4 mile, each with the best time of the car
  /// or "—" when the car has no run of that kind. No cars, no groups.
  static func groups(cars: [NoGpsCarMenu.Car], runsOfCar: (String) -> [Run], locale: Locale = .current) -> [Group] {
    cars.map { car in
      let runs = runsOfCar(car.carId)
      let rows = [NoGpsSprintKind.to100, .quarterMile].map { kind in
        Row(title: NoGpsSprintText.kindTitle(kind), value: bestText(of: kind, in: runs, locale: locale))
      }
      return Group(carId: car.carId, title: car.name, rows: rows)
    }
  }

  /// With no cars the groups are replaced by two sections with a footer each: the note and the closing line.
  static func sectionCount(of groups: [Group]) -> Int {
    groups.isEmpty ? 2 : groups.count
  }

  private static func bestText(of kind: NoGpsSprintKind, in runs: [Run], locale: Locale) -> String {
    // The runs come newest first: of equal times the older one is the record.
    guard let best = runs.reversed().filter({ $0.kind == kind }).min(by: { $0.sec < $1.sec }) else {
      return L("nogps_unknown")
    }
    return NoGpsSprintText.result(kind: kind, sec: best.sec, trapKmh: best.trapKmh, locale: locale)
  }
}

/// The records of every car of the user, opened from the Profile row of the main menu. The full list of runs of the
/// car driven now stays on its page of the Box sheet.
final class NoGpsProfileController: MWMTableViewController {
  private enum Constants {
    static let cellId = "NoGpsProfileCell"
  }

  private var groups: [NoGpsProfile.Group] = []

  init() {
    super.init(style: .insetGrouped)
    title = L("nogps_menu_profile")
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    groups = NoGpsProfile.groups(cars: NoGpsCarMenu.cars(NoGps.cars()), runsOfCar: { carId in
      NoGps.sprints(ofCar: carId).map { NoGpsProfile.Run(kind: $0.kind, sec: $0.sec, trapKmh: $0.trapKmh) }
    })
    tableView.reloadData()
  }

  override func numberOfSections(in _: UITableView) -> Int {
    NoGpsProfile.sectionCount(of: groups)
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    groups.isEmpty ? 0 : groups[section].rows.count
  }

  override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    groups.isEmpty ? nil : groups[section].title
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    if groups.isEmpty {
      return section == 0 ? L("nogps_sprint_none") : L("nogps_profile_soon")
    }
    return section == groups.count - 1 ? L("nogps_profile_soon") : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    let row = groups[indexPath.section].rows[indexPath.row]
    var content = UIListContentConfiguration.valueCell()
    content.text = row.title
    content.secondaryText = row.value
    content.secondaryTextProperties.color = .secondaryLabel
    cell.contentConfiguration = content
    cell.selectionStyle = .none
    return cell
  }
}
