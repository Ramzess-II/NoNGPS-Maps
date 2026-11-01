@testable import Organic_Maps__Debug_
import XCTest

final class NavigationSearchWheelTests: XCTestCase {
  private typealias Wheel = NavigationSearchWheel

  func testButtonOpensAndClosesTheWheel() {
    var state = Wheel.State()
    XCTAssertFalse(state.tapButton())
    XCTAssertTrue(state.isOpen)
    XCTAssertFalse(state.tapButton())
    XCTAssertEqual(state, Wheel.State())
  }

  func testCategoryClosesTheWheelAndButtonClearsIt() {
    var state = Wheel.State()
    _ = state.tapButton()
    state.pick(.parking)
    XCTAssertFalse(state.isOpen)
    XCTAssertEqual(state.category, .parking)
    XCTAssertTrue(state.tapButton())
    XCTAssertEqual(state, Wheel.State())
  }

  func testTimeoutClosesTheWheel() {
    var state = Wheel.State()
    _ = state.tapButton()
    state.close()
    XCTAssertEqual(state, Wheel.State())
  }

  func testButtonsGoDownTheHalfCircleApart() {
    let size = Wheel.Constants.buttonSize
    let offsets = Wheel.Category.allCases.map { Wheel.offset(of: $0) }
    for (index, offset) in offsets.enumerated() {
      // Toward the map, the whole button inside the half circle.
      XCTAssertGreaterThanOrEqual(offset.x, size / 2)
      XCTAssertLessThanOrEqual(hypot(offset.x, offset.y) + size / 2, Wheel.Constants.radius)
      if index > 0 {
        XCTAssertGreaterThan(offset.y, offsets[index - 1].y)
        let previous = offsets[index - 1]
        XCTAssertGreaterThan(hypot(offset.x - previous.x, offset.y - previous.y), size)
      }
    }
    // The first and the last are above and below the panel button, as far from the panel.
    let (first, last) = (offsets[0], offsets[offsets.count - 1])
    XCTAssertEqual(first.x, last.x, accuracy: 0.001)
    XCTAssertEqual(first.y, -last.y, accuracy: 0.001)
  }
}
