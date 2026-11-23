@testable import Organic_Maps__Debug_
import Sentry
import XCTest

final class CrashReporterTests: XCTestCase {
  private let dsn = "https://key@o1.ingest.de.sentry.io/1"
  private let key = "CrashReportsEnabledKey"

  override func tearDown() {
    CrashReporter.setEnabled(false)
    UserDefaults.standard.removeObject(forKey: key)
    super.tearDown()
  }

  func testSwitchIsOnByDefault() {
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertTrue(Settings.crashReportsEnabled())
  }

  func testSwitchIsKept() {
    Settings.setCrashReportsEnabled(false)
    XCTAssertFalse(Settings.crashReportsEnabled())
    Settings.setCrashReportsEnabled(true)
    XCTAssertTrue(Settings.crashReportsEnabled())
  }

  func testEmptyDsnDoesNotStart() {
    XCTAssertFalse(CrashReporter.start(dsn: "", debug: false, enabled: true))
  }

  func testSwitchOffDoesNotStart() {
    XCTAssertFalse(CrashReporter.start(dsn: dsn, debug: false, enabled: false))
  }

  func testDebugBuildDoesNotStart() {
    XCTAssertFalse(CrashReporter.start(dsn: dsn, debug: true, enabled: true))
  }

  func testSwitchOffClosesStartedSdk() {
    XCTAssertTrue(CrashReporter.start(dsn: dsn, debug: false, enabled: true))
    CrashReporter.setEnabled(false)
    XCTAssertFalse(CrashReporter.isRunning)
  }

  func testEventWithLogsPathIsDropped() {
    XCTAssertTrue(CrashReporter.shouldDrop(texts: ["Can't open /var/mobile/Documents/logs/101010.log"]))
    XCTAssertFalse(CrashReporter.shouldDrop(texts: ["CHECK(a < b)"]))
  }

  func testRedactsCoordinatesFromAssertMessage() {
    XCTAssertEqual(CrashReporter.redactNumbers("CHECK(d < 5) 50.450123 -30.5234 12 3.5"), "CHECK(d < 5) <num> <num> 12 3.5")
  }

  func testAssertGoesToScopeRedacted() {
    XCTAssertTrue(CrashReporter.start(dsn: dsn, debug: false, enabled: true))
    CrashReporter.reportAssert(source: "engine.cpp:10", message: "CHECK(a < b) 50.450123")
    var extra: [String: Any]?
    SentrySDK.configureScope { extra = $0.serialize()["extra"] as? [String: Any] }
    XCTAssertEqual(extra?["assert.message"] as? String, "CHECK(a < b) <num>")
    XCTAssertEqual(extra?["assert.source"] as? String, "engine.cpp:10")
  }

  func testConfiguredBeforeSendDropsLogsPath() {
    let options = Options()
    CrashReporter.configure(options, dsn: dsn, environment: "release", release: "1+1")
    let bad = Event()
    bad.message = SentryMessage(formatted: "Can't open /var/mobile/logs/1.log")
    XCTAssertNil(options.beforeSend?(bad))
    let good = Event()
    good.message = SentryMessage(formatted: "CHECK(a < b)")
    XCTAssertNotNil(options.beforeSend?(good))
    XCTAssertFalse(options.sendDefaultPii)
  }
}
