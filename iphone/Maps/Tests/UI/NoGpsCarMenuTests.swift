@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsCarMenuTests: XCTestCase {
  private static let seen = Date(timeIntervalSince1970: 1_767_225_600)

  private func car(_ id: String, name: String? = nil, lastSeen: Date? = nil) -> NoGpsCarMenu.Car {
    NoGpsCarMenu.Car(carId: id, name: name ?? "Car \(id)", lastSeen: lastSeen)
  }

  private func entries(_ cars: [NoGpsCarMenu.Car], currentId: String = "C47D", connected: Bool = false,
                       nearby: Set<String> = [], maxCars: Int = 3) -> [NoGpsCarMenu.Entry] {
    NoGpsCarMenu.entries(cars: cars, currentId: currentId, connected: connected, nearby: { nearby.contains($0) },
                         maxCars: maxCars)
  }

  func testOneCarAndAdd() {
    XCTAssertEqual(entries([car("C47D")]),
                   [.car(carId: "C47D", name: "Car C47D", state: .current), .add])
  }

  func testCurrentCarKeepsItsPlaceAndIsMarked() {
    let menu = entries([car("A111", lastSeen: Self.seen), car("C47D"), car("B222")], connected: true, maxCars: 4)
    XCTAssertEqual(menu, [.car(carId: "A111", name: "Car A111", state: .lastSeen(Self.seen)),
                          .car(carId: "C47D", name: "Car C47D", state: .connected),
                          .car(carId: "B222", name: "Car B222", state: nil),
                          .add])
    XCTAssertEqual(menu.map {
      if case .car(_, _, let state) = $0 {
        return NoGpsCarMenu.isCurrent(state)
      }
      return false
    }, [false, true, false, false])
  }

  func testStates() {
    let menu = entries([car("C47D"), car("B222"), car("A111", lastSeen: Self.seen), car("D444")],
                       nearby: ["B222"], maxCars: 4)
    XCTAssertEqual(menu, [.car(carId: "C47D", name: "Car C47D", state: .current),
                          .car(carId: "B222", name: "Car B222", state: .nearby),
                          .car(carId: "A111", name: "Car A111", state: .lastSeen(Self.seen)),
                          .car(carId: "D444", name: "Car D444", state: nil)])
    XCTAssertEqual(NoGpsCarMenu.stateText(.connected), L("nogps_car_connected"))
    XCTAssertEqual(NoGpsCarMenu.stateText(.current), L("nogps_car_current"))
    XCTAssertEqual(NoGpsCarMenu.stateText(.nearby), L("nogps_car_nearby"))
    let now = Self.seen.addingTimeInterval(2 * 60 * 60)
    let ago = RelativeDateTimeFormatter().localizedString(for: Self.seen, relativeTo: now)
    XCTAssertEqual(NoGpsCarMenu.stateText(.lastSeen(Self.seen), now: now),
                   String(format: L("nogps_car_last_seen"), ago))
    XCTAssertNil(NoGpsCarMenu.stateText(nil))
  }

  func testNoAddAtTheLimit() {
    XCTAssertEqual(entries([car("C47D"), car("B222")], maxCars: 2),
                   [.car(carId: "C47D", name: "Car C47D", state: .current),
                    .car(carId: "B222", name: "Car B222", state: nil)])
  }
}
