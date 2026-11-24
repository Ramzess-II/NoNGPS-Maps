@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsProfileTests: XCTestCase {
  private let locale = Locale(identifier: "en_US")

  private func car(_ id: String, name: String? = nil) -> NoGpsCarMenu.Car {
    NoGpsCarMenu.Car(carId: id, name: name ?? "Car \(id)", lastSeen: nil)
  }

  private func groups(_ cars: [NoGpsCarMenu.Car], _ runs: [String: [NoGpsProfile.Run]]) -> [NoGpsProfile.Group] {
    NoGpsProfile.groups(cars: cars, runsOfCar: { runs[$0] ?? [] }, locale: locale)
  }

  func testNoCarsNoGroups() {
    XCTAssertTrue(groups([], [:]).isEmpty)
  }

  func testCarsInTheOrderTheyWereAdded() {
    let result = groups([car("B222"), car("A111", name: "Mine")], [:])
    XCTAssertEqual(result.map(\.carId), ["B222", "A111"])
    XCTAssertEqual(result.map(\.title), ["Car B222", "Mine"])
  }

  func testCarWithoutRunsHasUnknownInBothRows() {
    let rows = groups([car("C47D")], [:])[0].rows
    XCTAssertEqual(rows.map(\.title), [L("nogps_sprint_to100"), L("nogps_sprint_quarter_mile")])
    XCTAssertEqual(rows.map(\.value), [L("nogps_unknown"), L("nogps_unknown")])
  }

  func testSectionCountIsOnePerCarAndTwoWithoutCars() {
    // The two sections carry the footers of the empty state; with cars the table must not ask for a group it has not.
    XCTAssertEqual(NoGpsProfile.sectionCount(of: groups([], [:])), 2)
    XCTAssertEqual(NoGpsProfile.sectionCount(of: groups([car("C47D")], [:])), 1)
    XCTAssertEqual(NoGpsProfile.sectionCount(of: groups([car("A111"), car("B222")], [:])), 2)
  }

  func testBestOfSeveralRunsOfAKind() {
    // Newest first, as the core gives them.
    let runs: [NoGpsProfile.Run] = [
      .init(kind: .to100, sec: 9.5, trapKmh: 0),
      .init(kind: .quarterMile, sec: 15.21, trapKmh: 142),
      .init(kind: .to100, sec: 8.4, trapKmh: 0),
      .init(kind: .to100, sec: 10, trapKmh: 0),
    ]
    let rows = groups([car("C47D")], ["C47D": runs])[0].rows
    XCTAssertEqual(rows[0].value, NoGpsSprintText.result(kind: .to100, sec: 8.4, trapKmh: 0, locale: locale))
    XCTAssertEqual(rows[1].value,
                   NoGpsSprintText.result(kind: .quarterMile, sec: 15.21, trapKmh: 142, locale: locale))
  }

  func testTheRunsOfACarDoNotGoToAnother() {
    let runs: [String: [NoGpsProfile.Run]] = ["A111": [.init(kind: .to100, sec: 9, trapKmh: 0)]]
    let result = groups([car("A111"), car("B222")], runs)
    XCTAssertNotEqual(result[0].rows[0].value, L("nogps_unknown"))
    XCTAssertEqual(result[0].rows[1].value, L("nogps_unknown"))
    XCTAssertEqual(result[1].rows.map(\.value), [L("nogps_unknown"), L("nogps_unknown")])
  }
}
