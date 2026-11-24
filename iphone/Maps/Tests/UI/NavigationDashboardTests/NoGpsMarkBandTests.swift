@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsMarkBandTests: XCTestCase {
  private typealias Constants = NoGpsControls.Constants

  /// The speed button and its bars end under the mark.
  func test_GivenBand_WhenSpeedBarOpen_ThenItsTopIsBelowTheMark() {
    let barTop = Constants.speedMargin + NoGpsSpeedView.side
    XCTAssertLessThan(barTop, Constants.markClearance)
  }

  /// The alert of a timed run starts above the top of the mark.
  func test_GivenBand_WhenSprintAlert_ThenItsBottomIsAboveTheMark() {
    let areaMaxY = CGFloat(800)
    let markTop = areaMaxY - Constants.markClearance - Constants.markHeight
    XCTAssertLessThan(NoGpsControls.sprintBottomConstant(areaMaxY: areaMaxY), markTop)
  }

  /// The viewport ends above the screen bottom by a sheet: only the part below the free area is added.
  func test_GivenViewportAboveScreenBottom_WhenOffset_ThenItIsMeasuredFromViewportBottom() {
    XCTAssertEqual(NoGpsControls.markOffset(areaMaxY: 800, viewportMaxY: 800), Constants.markClearance)
    XCTAssertEqual(NoGpsControls.markOffset(areaMaxY: 800, viewportMaxY: 830), Constants.markClearance + 30)
    XCTAssertEqual(NoGpsControls.markOffset(areaMaxY: 800, viewportMaxY: 0), 0)
  }
}
