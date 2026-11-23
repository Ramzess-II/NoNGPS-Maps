@testable import Organic_Maps__Debug_
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
}
