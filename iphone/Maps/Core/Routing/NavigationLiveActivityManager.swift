import ActivityKit

/// What the Live Activity of the navigation shows, from the strings of the dashboard.
struct NavigationLiveActivityInfo: Equatable {
  var turnImageName: String?
  var distanceToTurn: String
  var street: String
  var distanceLeft: String
  var timeLeft: String
  var arrival: Date
}

extension NavigationLiveActivityAttributes.ContentState {
  init(look: NoGpsStatusBar.Look, info: NavigationLiveActivityInfo, stopTitle: String) {
    source = Source(symbol: look.symbol, color: look.colorKey, hasBadge: look.badge != nil,
                    badgeSymbol: look.badge?.symbol, badgeColor: look.badge.map { NavigationLiveActivityColor($0.color) } ?? .gray)
    turnSymbol = Self.turnSymbol(imageName: info.turnImageName)
    distanceToTurn = info.distanceToTurn
    street = info.street
    distanceLeft = info.distanceLeft
    timeLeft = info.timeLeft
    arrival = info.arrival
    self.stopTitle = stopTitle
  }

  /// The SF Symbol for the image of a turn of the dashboard.
  static func turnSymbol(imageName: String?) -> String {
    switch imageName {
    case "simple_right": return "arrow.turn.up.right"
    case "simple_left": return "arrow.turn.up.left"
    case "slight_right", "ic_exit_highway_to_right": return "arrow.up.right"
    case "slight_left", "ic_exit_highway_to_left": return "arrow.up.left"
    case "sharp_right": return "arrow.turn.down.right"
    case "sharp_left": return "arrow.turn.down.left"
    case "uturn_left": return "arrow.uturn.left"
    case "uturn_right": return "arrow.uturn.right"
    case "round": return "arrow.triangle.turn.up.right.circle"
    case "finish_point": return "flag.checkered"
    default: return "arrow.up"
    }
  }
}

/// The part of the Live Activity manager that the dashboard and the status bar call.
@objc(MWMNavigationLiveActivity)
final class NavigationLiveActivity: NSObject {
  /// The navigation has started: the activity starts with the first info.
  @objc
  static func start() {
    if #available(iOS 16.2, *) {
      NavigationLiveActivityManager.shared.start()
    }
  }

  @objc
  static func updateNavigation(_ entity: MWMNavigationDashboardEntity) {
    if #available(iOS 16.2, *) {
      NavigationLiveActivityManager.shared.update(info: NavigationLiveActivityInfo(entity))
    }
  }

  /// The source of the position has changed.
  static func update(_ status: NoGpsStatus) {
    if #available(iOS 16.2, *) {
      NavigationLiveActivityManager.shared.update(status: status)
    }
  }

  @objc
  static func end() {
    if #available(iOS 16.2, *) {
      NavigationLiveActivityManager.shared.stop()
    }
  }
}

extension NavigationLiveActivityInfo {
  init(_ entity: MWMNavigationDashboardEntity, now: Date = Date()) {
    turnImageName = entity.turnImageName
    distanceToTurn = [entity.distanceToTurn, entity.turnUnits].filter { !$0.isEmpty }.joined(separator: " ")
    street = entity.streetName
    distanceLeft = [entity.targetDistance, entity.targetUnits].filter { !$0.isEmpty }.joined(separator: " ")
    timeLeft = entity.timeToTarget > 0 ? DurationFormatter.routingDurationString(from: TimeInterval(entity.timeToTarget)) : ""
    arrival = Self.arrival(now: now, secondsLeft: TimeInterval(entity.timeToTarget))
  }

  /// To the minute, so that the activity is not updated for a second that passed.
  static func arrival(now: Date, secondsLeft: TimeInterval) -> Date {
    let arrival = now.addingTimeInterval(secondsLeft).timeIntervalSince1970
    return Date(timeIntervalSince1970: (arrival / 60).rounded(.down) * 60)
  }
}

/// The Live Activity of the navigation: the Dynamic Island, the lock screen. It starts with the navigation and ends
/// with it, and it is updated only when what it shows has changed.
@available(iOS 16.2, *)
final class NavigationLiveActivityManager {
  static let shared = NavigationLiveActivityManager()

  private enum Constants {
    /// A state is sent again after this time, so that the activity doesn't go stale while the car stands.
    static let refreshInterval: TimeInterval = 60
    /// The system marks the activity stale when the app doesn't update it for this long: the app is killed.
    static let staleAfter: TimeInterval = 180
  }

  private var activity: Activity<NavigationLiveActivityAttributes>?
  private var isNavigating = false
  private var info: NavigationLiveActivityInfo?
  private var lastState: NavigationLiveActivityAttributes.ContentState?
  private var lastPush = Date.distantPast

  private init() {}

  func start() {
    isNavigating = true
    if #available(iOS 17.0, *) {
      StopNavigationIntent.handler = { MWMRouter.stopRouting() }
    }
  }

  func update(info: NavigationLiveActivityInfo) {
    self.info = info
    push()
  }

  func update(status _: NoGpsStatus) {
    push()
  }

  func stop() {
    isNavigating = false
    info = nil
    lastState = nil
    let activities = Activity<NavigationLiveActivityAttributes>.activities
    activity = nil
    activities.forEach(LiveActivityManager.stop)
  }

  /// The state to show: the look of the source now with the info of the dashboard.
  static func makeState(status: NoGpsStatus, info: NavigationLiveActivityInfo) -> NavigationLiveActivityAttributes.ContentState {
    .init(look: NoGpsStatusBar.barLook(status), info: info, stopTitle: L("navigation_stop_button"))
  }

  /// Only a changed state is sent, and an unchanged one now and then.
  static func shouldPush(_ state: NavigationLiveActivityAttributes.ContentState,
                         last: NavigationLiveActivityAttributes.ContentState?,
                         sinceLastPush: TimeInterval) -> Bool {
    state != last || sinceLastPush >= Constants.refreshInterval
  }

  private func push(now: Date = Date()) {
    guard isNavigating, let info else { return }
    let state = Self.makeState(status: NoGps.status(), info: info)
    guard Self.shouldPush(state, last: lastState, sinceLastPush: now.timeIntervalSince(lastPush)) else { return }
    lastState = state
    lastPush = now
    let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Constants.staleAfter))
    if let activity = activity ?? Activity<NavigationLiveActivityAttributes>.activities.first {
      self.activity = activity
      LiveActivityManager.update(activity, content: content)
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    do {
      activity = try LiveActivityManager.startActivity(NavigationLiveActivityAttributes(), content: content)
    } catch {
      LOG(.warning, "Can't start the navigation Live Activity: \(error)")
    }
  }
}
