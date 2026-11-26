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

/// How the driver drives, by the speeding: the rows of the Driving section and the trips it comes from. Pure, so it is
/// testable.
enum NoGpsDriving {
  /// The rated driving the score is shown from, as SpeedingMeter::kScoreMinKm.
  static let minKm = 20

  struct Rating: Equatable {
    let enough: Bool
    let score: Int
    let ratedKm: Double
    /// The episodes over the limit by 20-40, 40-60 and more than 60 km/h.
    let bandCounts: [Int]
  }

  struct Trip: Equatable {
    let date: Date
    let ratedKm: Double
    let score: Int
    let bandCounts: [Int]
  }

  /// The score, the rated driving and the episodes of each band. Before there is enough driving: no rows, only the note.
  static func rows(_ rating: Rating) -> [NoGpsProfile.Row] {
    guard rating.enough else { return [] }
    let bands = [L("nogps_driving_band1"), L("nogps_driving_band2"), L("nogps_driving_band3")]
    return [
      NoGpsProfile.Row(title: L("nogps_driving_score"), value: String(rating.score)),
      NoGpsProfile.Row(title: L("nogps_driving_distance"), value: km(rating.ratedKm)),
    ] + zip(bands, rating.bandCounts).map { NoGpsProfile.Row(title: $0, value: String($1)) }
  }

  static func note() -> String {
    String(format: L("nogps_driving_not_enough"), minKm)
  }

  static func km(_ value: Double) -> String {
    String(format: L("nogps_driving_km"), Int(value.rounded()))
  }

  /// The rated driving and the episodes of the trip, under its date.
  static func tripDetail(_ trip: Trip) -> String {
    let bands = trip.bandCounts
    return String(format: L("nogps_driving_trip_detail"), Int(trip.ratedKm.rounded()), bands[0], bands[1], bands[2])
  }

  static func rating(_ rating: NoGpsDrivingRating) -> Rating {
    Rating(enough: rating.enough, score: rating.score, ratedKm: rating.ratedKm, bandCounts: rating.bandCounts.map(\.intValue))
  }

  static func trip(_ trip: NoGpsSpeedingTrip) -> Trip {
    Trip(date: trip.date, ratedKm: trip.ratedKm, score: trip.score, bandCounts: trip.bandCounts.map(\.intValue))
  }
}

/// The records of every car of the user, opened from the Profile row of the main menu. The full list of runs of the
/// car driven now stays on its page of the Box sheet.
final class NoGpsProfileController: MWMTableViewController {
  private enum Constants {
    static let cellId = "NoGpsProfileCell"
  }

  private var rating = NoGpsDriving.Rating(enough: false, score: 100, ratedKm: 0, bandCounts: [0, 0, 0])
  private var tripCount = 0
  private var drivingRows: [NoGpsProfile.Row] = []
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
    let driving = NoGps.drivingRating()
    rating = NoGpsDriving.rating(driving)
    tripCount = driving.trips.count
    drivingRows = NoGpsDriving.rows(rating)
    groups = NoGpsProfile.groups(cars: NoGpsCarMenu.cars(NoGps.cars()), runsOfCar: { carId in
      NoGps.sprints(ofCar: carId).map { NoGpsProfile.Run(kind: $0.kind, sec: $0.sec, trapKmh: $0.trapKmh) }
    })
    tableView.reloadData()
  }

  /// The Driving section is the first, the cars follow.
  private func groupIndex(of section: Int) -> Int {
    section - 1
  }

  override func numberOfSections(in _: UITableView) -> Int {
    1 + NoGpsProfile.sectionCount(of: groups)
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    if section == 0 {
      return drivingRows.count + 1
    }
    return groups.isEmpty ? 0 : groups[groupIndex(of: section)].rows.count
  }

  override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    if section == 0 {
      return L("nogps_driving_title")
    }
    return groups.isEmpty ? nil : groups[groupIndex(of: section)].title
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    if section == 0 {
      return rating.enough ? nil : NoGpsDriving.note()
    }
    if groups.isEmpty {
      return section == 1 ? L("nogps_sprint_none") : L("nogps_profile_soon")
    }
    return groupIndex(of: section) == groups.count - 1 ? L("nogps_profile_soon") : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    var content = UIListContentConfiguration.valueCell()
    cell.accessoryType = .none
    cell.selectionStyle = .none
    if indexPath.section == 0 {
      if indexPath.row < drivingRows.count {
        content.text = drivingRows[indexPath.row].title
        content.secondaryText = drivingRows[indexPath.row].value
      } else {
        content.text = L("nogps_driving_trips")
        content.secondaryText = String(tripCount)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
      }
    } else {
      let row = groups[groupIndex(of: indexPath.section)].rows[indexPath.row]
      content.text = row.title
      content.secondaryText = row.value
    }
    content.secondaryTextProperties.color = .secondaryLabel
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard indexPath.section == 0, indexPath.row == drivingRows.count else { return }
    navigationController?.pushViewController(NoGpsDrivingTripsController(), animated: true)
  }
}

/// The trips of the phone with their driving scores, newest first, opened from the Driving section of the Profile.
final class NoGpsDrivingTripsController: MWMTableViewController {
  private enum Constants {
    static let cellId = "NoGpsDrivingTripCell"
  }

  private var trips: [NoGpsDriving.Trip] = []
  private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  init() {
    super.init(style: .insetGrouped)
    title = L("nogps_driving_trips")
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
    trips = NoGps.drivingRating().trips.map(NoGpsDriving.trip)
    tableView.reloadData()
  }

  override func numberOfSections(in _: UITableView) -> Int {
    1
  }

  override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
    trips.count
  }

  override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
    trips.isEmpty ? L("nogps_driving_trips_none") : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    let trip = trips[indexPath.row]
    var content = UIListContentConfiguration.subtitleCell()
    content.text = dateFormatter.string(from: trip.date)
    content.secondaryText = NoGpsDriving.tripDetail(trip)
    content.secondaryTextProperties.color = .secondaryLabel
    cell.contentConfiguration = content
    let score = UILabel()
    score.text = String(trip.score)
    score.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
    score.textColor = .secondaryLabel
    score.sizeToFit()
    cell.accessoryView = score
    cell.selectionStyle = .none
    return cell
  }
}
