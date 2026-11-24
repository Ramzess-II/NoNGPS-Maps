import ObjectiveC
import Sentry
import UIKit

/// Crash reports to Sentry. A report holds the stack, the device model, the app version and a few tags: no
/// coordinates, no logs, no IP address. An empty DSN, a Debug build or the switch off keep Sentry stopped.
@objc(MWMCrashReporter)
final class CrashReporter: NSObject {
  /// The DSN of the iOS project, SENTRY_DSN_IOS of private.h.
  static let dsn = SENTRY_DSN_IOS

  static var isDebugBuild: Bool {
#if DEBUG
    true
#else
    false
#endif
  }

  static func shouldStart(dsn: String, debug: Bool, enabled: Bool) -> Bool {
    enabled && !debug && !dsn.isEmpty
  }

  /// Called from the application delegate before the framework is created, so a crash while the core starts is caught.
  @objc static func start() {
    start(dsn: dsn, debug: isDebugBuild, enabled: Settings.crashReportsEnabled())
  }

  /// @return true if Sentry is running after the call.
  @discardableResult
  static func start(dsn: String, debug: Bool, enabled: Bool) -> Bool {
    if shouldStart(dsn: dsn, debug: debug, enabled: enabled), !isRunning {
      startSDK(dsn: dsn, debug: debug)
    }
    return isRunning
  }

  static var isRunning: Bool { SentrySDK.isEnabled }

  /// The switch of the settings: takes effect at once. The setting itself is kept by MWMSettings.
  @objc static func setEnabled(_ enabled: Bool) {
    if !enabled {
      SentrySDK.close()
    } else {
      start(dsn: dsn, debug: isDebugBuild, enabled: true)
    }
  }

  static func configure(_ options: Options, dsn: String, environment: String, release: String) {
    options.dsn = dsn
    options.environment = environment
    options.releaseName = release
    options.sendDefaultPii = false
    options.tracesSampleRate = 0
    options.enableAutoPerformanceTracing = false
    options.enableUIViewControllerTracing = false
    options.enableNetworkTracking = false
    options.enableNetworkBreadcrumbs = false
    options.enableCaptureFailedRequests = false
    options.attachScreenshot = false
    options.attachViewHierarchy = false
    options.enableAppHangTracking = false
    options.enableMetricKit = false
    options.enableAutoBreadcrumbTracking = false
    options.enableAutoSessionTracking = false
    options.beforeSend = { event in
      let texts = [event.message?.formatted] + (event.exceptions ?? []).map(\.value)
        + (event.extra ?? [:]).values.map { String(describing: $0) }
      return shouldDrop(texts: texts.compactMap { $0 }) ? nil : event
    }
  }

  /// A report with a path of the logs folder is not sent: the trip logs hold coordinates.
  static func shouldDrop(texts: [String]) -> Bool {
    texts.contains { $0.contains("/logs/") }
  }

  /// The place and the text of a failed CHECK/ASSERT of the core go to the scope: no network call from a dying
  /// process, the report is written to the disk and sent on the next launch.
  static func reportAssert(source: String, message: String) {
    guard SentrySDK.isEnabled else { return }
    let message = redactNumbers(message)
    SentrySDK.configureScope { scope in
      scope.setExtra(value: message, key: "assert.message")
      scope.setExtra(value: source, key: "assert.source")
    }
  }

  /// A decimal with 4 or more digits after the point may be a coordinate: the message of a CHECK can print one.
  static func redactNumbers(_ text: String) -> String {
    text.replacingOccurrences(of: #"-?\d+\.\d{4,}"#, with: "<num>", options: .regularExpression)
  }

  static func setTag(_ key: String, _ value: String) {
    guard SentrySDK.isEnabled else { return }
    SentrySDK.configureScope { $0.setTag(value: value, key: key) }
  }

  /// The screen and what the box does, for the next report. No position, no log line.
  static func screenAppeared(_ viewController: UIViewController) {
    guard SentrySDK.isEnabled else { return }
    setTag("screen", String(describing: type(of: viewController)))
    // The map screen exists only after the framework is created: the status would create it earlier.
    guard viewController is MapViewController else { return }
    let status = NoGps.status()
    setTag("box", sourceStateName(status.sourceState))
    setTag("box.firmware", status.boxFirmware)
    setTag("nogps.source", positionSourceName(status.source))
  }

  /// The names of the Android enums, so a tag search finds the events of both platforms.
  static func sourceStateName(_ state: NoGpsSourceState) -> String {
    switch state {
    case .disconnected: return "DISCONNECTED"
    case .connecting: return "CONNECTING"
    case .noAdapter: return "NO_ADAPTER"
    case .obdDisabled: return "OBD_DISABLED"
    case .obdConnecting: return "OBD_CONNECTING"
    case .obdError: return "OBD_ERROR"
    case .noCarData: return "NO_CAR_DATA"
    case .boxSleeping: return "BOX_SLEEPING"
    case .boxBatteryLock: return "BOX_BATTERY_LOCK"
    case .obdSleeping: return "OBD_SLEEPING"
    case .connected: return "CONNECTED"
    case .updating: return "UPDATING"
    @unknown default: return String(state.rawValue)
    }
  }

  static func positionSourceName(_ source: NoGpsPositionSource) -> String {
    switch source {
    case .none: return "NONE"
    case .gps: return "GPS"
    case .network: return "NETWORK"
    case .manual: return "MANUAL"
    case .inertial: return "INERTIAL"
    @unknown default: return String(source.rawValue)
    }
  }

  private static func startSDK(dsn: String, debug: Bool) {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    let build = info?["CFBundleVersion"] as? String ?? ""
    SentrySDK.start { options in
      configure(options, dsn: dsn, environment: debug ? "debug" : "release", release: "\(version)+\(build)")
    }
    SentrySDK.configureScope { $0.setTag(value: UIDevice.current.model, key: "device.model") }
    Logger.setAssertHandler { source, message in reportAssert(source: source, message: message) }
    UIViewController.trackScreens()
  }
}

private extension UIViewController {
  private static var screensTracked = false

  static func trackScreens() {
    guard !screensTracked,
          let original = class_getInstanceMethod(UIViewController.self, #selector(viewDidAppear(_:))),
          let tracked = class_getInstanceMethod(UIViewController.self, #selector(crashReporterViewDidAppear(_:)))
    else { return }
    screensTracked = true
    method_exchangeImplementations(original, tracked)
  }

  @objc func crashReporterViewDidAppear(_ animated: Bool) {
    // Calls the original: the implementations are exchanged.
    crashReporterViewDidAppear(animated)
    CrashReporter.screenAppeared(self)
  }
}
