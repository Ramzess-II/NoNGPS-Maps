@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsCalibrationBarTests: XCTestCase {
  /// The bar tells to hold still, then that the box calibrates, then that the car moved.
  func test_GivenCalibrationState_WhenArmed_ThenTheBarTellsWhatToDo() {
    let status = FakeBarStatus()
    status.fakeCalibration = .none
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .waiting)
    XCTAssertEqual(NoGpsCalibrationBarView.State.waiting.text, L("nogps_calibrate_still_hold"))
    status.fakeCalibration = .calibrating
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .calibrating)
    XCTAssertEqual(NoGpsCalibrationBarView.State.calibrating.text, L("nogps_calibrate_still_calibrating"))
    status.fakeCalibration = .failedMoving
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .moved)
    XCTAssertEqual(NoGpsCalibrationBarView.State.moved.text, L("nogps_calibrate_still_moved"))
  }

  /// The newest value is at the right edge, an old one is lower than the limit line in the middle of the height.
  func test_GivenShake_WhenTraceIsDrawn_ThenTheNewestIsOnTheRight() {
    let size = CGSize(width: 149, height: 20)
    let points = ShakeTraceView.points([0, 100, 400], in: size)
    XCTAssertEqual(points.count, 3)
    XCTAssertEqual(points.last?.x, 149)
    // The limit is in the middle, a shake over the double limit is clamped to the top.
    XCTAssertEqual(points[0].y, 20)
    XCTAssertEqual(points[1].y, 10)
    XCTAssertEqual(points[2].y, 0)
    XCTAssertTrue(ShakeTraceView.points([], in: size).isEmpty)
    // Longer than 3 s: the oldest values are dropped.
    XCTAssertEqual(ShakeTraceView.points([Double](repeating: 50, count: 200), in: size).count, 150)
  }
}

private final class FakeBarStatus: NoGpsStatus {
  var fakeCalibration = NoGpsCalibrationState.none
  override var calibration: NoGpsCalibrationState { fakeCalibration }
}
