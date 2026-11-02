@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsFlagsTests: XCTestCase {
  func testNameIsLocalTime() throws {
    let date = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 11, day: 2, hour: 9, minute: 5, second: 7).date)
    XCTAssertEqual(NoGpsFlags.name(of: date), "20261102-090507")
    XCTAssertEqual(NoGpsFlags.date(of: "20261102-090507"), date)
    XCTAssertEqual(NoGpsFlags.time(of: "20261102-090507"), "09:05:07")
    XCTAssertEqual(NoGpsFlags.logDay(of: "20261102-090507"), "02-11-26")
    XCTAssertEqual(NoGpsFlags.mailDay(of: "20261102-090507"), "02.11.26")
  }

  func testExpiresAfterSevenDays() throws {
    let flag = try XCTUnwrap(NoGpsFlags.date(of: "20261102-090507"))
    let day = TimeInterval(24 * 60 * 60)
    XCTAssertFalse(NoGpsFlags.isExpired("20261102-090507", now: flag.addingTimeInterval(7 * day - 1)))
    XCTAssertTrue(NoGpsFlags.isExpired("20261102-090507", now: flag.addingTimeInterval(7 * day + 1)))
    // Not a flag of this app: left alone.
    XCTAssertFalse(NoGpsFlags.isExpired("notes", now: flag.addingTimeInterval(30 * day)))
  }

  func testLogFilesOfTheDays() {
    let files = ["log-02-11-26-iPhone15_2-a3f9.log", "log-02-11-26-iPhone15_2-a3f9.1.log",
                 "log-02-11-26-iPhone14_7-0b12.log", "log-01-11-26-iPhone15_2-a3f9.log",
                 "log-03-11-26-iPhone15_2-a3f9.log", "log-02-11-26-iPhone15_2-a3f9.log.zip", "log.txt"]
    XCTAssertEqual(NoGpsFlags.logFiles(files, days: ["02-11-26"]),
                   ["log-02-11-26-iPhone15_2-a3f9.log", "log-02-11-26-iPhone15_2-a3f9.1.log",
                    "log-02-11-26-iPhone14_7-0b12.log"])
    XCTAssertEqual(NoGpsFlags.logFiles(files, days: ["01-11-26", "03-11-26"]),
                   ["log-01-11-26-iPhone15_2-a3f9.log", "log-03-11-26-iPhone15_2-a3f9.log"])
  }

  func testMail() {
    let flags = [NoGpsFlag(name: "20261102-140509", number: 3, lat: 50.450123, lon: 30.523456, voiceS: 12),
                 NoGpsFlag(name: "20261101-235959", number: 7),
                 NoGpsFlag(name: "20261102-090000", number: 1, lat: 50.1, lon: 30.2)]
    XCTAssertEqual(NoGpsFlags.mailSubject(version: "2026.11.01-74 iOS", flags: flags),
                   "[2026.11.01-74 iOS] Flags 01.11.26, 02.11.26")
    XCTAssertEqual(NoGpsFlags.mailBody(flags), """
    FLAG 7 23:59:59 no position
    FLAG 1 09:00:00 50.10000,30.20000
    FLAG 3 14:05:09 50.45012,30.52346 voice 12 s
    """)
  }

  func testJsonKeepsAllButTheName() throws {
    let flag = NoGpsFlag(name: "20261102-140509", number: 3, lat: 50.45, lon: 30.52, voiceS: 12, sent: true)
    var decoded = try JSONDecoder().decode(NoGpsFlag.self, from: JSONEncoder().encode(flag))
    XCTAssertEqual(decoded.name, "")
    decoded.name = flag.name
    XCTAssertEqual(decoded, flag)
  }
}
