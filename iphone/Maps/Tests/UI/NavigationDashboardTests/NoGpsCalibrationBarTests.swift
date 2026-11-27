@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsCalibrationBarTests: XCTestCase {
  /// The bar tells to hold still, then that the box calibrates, then that the car moved.
  func test_GivenCalibrationState_WhenArmed_ThenTheBarTellsWhatToDo() {
    let status = FakeBarStatus()
    status.fakeCalibration = .none
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .waiting)
    XCTAssertEqual(NoGpsCalibrationBarView.State.waiting.text, L("nogps_calibrate_bar_hold"))
    status.fakeCalibration = .calibrating
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .calibrating)
    XCTAssertEqual(NoGpsCalibrationBarView.State.calibrating.text, L("nogps_calibrate_bar_measuring"))
    status.fakeCalibration = .failedMoving
    status.fakeTries = 1
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .waiting)
    status.fakeTries = 2
    XCTAssertEqual(NoGpsCalibrationBarView.state(status), .moved)
    XCTAssertEqual(NoGpsCalibrationBarView.State.moved.text, L("nogps_calibrate_bar_moved"))
  }

  /// The newest value is at the right edge: 0 is at the bottom, the limit 45% from the top.
  func test_GivenShake_WhenTraceIsDrawn_ThenTheNewestIsOnTheRight() {
    let size = CGSize(width: 149, height: 100)
    let points = ShakeTraceView.points([0, 100, 400], in: size)
    XCTAssertEqual(points.count, 3)
    XCTAssertEqual(points.last?.x, 149)
    XCTAssertEqual(points[0].y, 100)
    XCTAssertEqual(points[1].y, 45, accuracy: 0.001)
    XCTAssertTrue(ShakeTraceView.points([], in: size).isEmpty)
    // Longer than 3 s: the oldest values are dropped.
    XCTAssertEqual(ShakeTraceView.points([Double](repeating: 50, count: 200), in: size).count, 150)
  }

  /// Linear under the limit, log10 above it up to 1000, a value over it is on the top edge.
  func test_GivenSplitScale_WhenValueIsOver_ThenItIsOnTheLogScale() {
    XCTAssertEqual(ShakeTraceView.y(0, height: 100), 100, accuracy: 0.001)
    XCTAssertEqual(ShakeTraceView.y(50, height: 100), 72.5, accuracy: 0.001)
    XCTAssertEqual(ShakeTraceView.y(100, height: 100), 45, accuracy: 0.001)
    XCTAssertEqual(ShakeTraceView.y(300, height: 100), 45 * (1 - log10(3.0)), accuracy: 0.001)
    XCTAssertEqual(ShakeTraceView.y(1000, height: 100), 0, accuracy: 0.001)
    XCTAssertEqual(ShakeTraceView.y(9999, height: 100), 0, accuracy: 0.001)
  }

  /// The time held is the newest values under the limit in a row, up to 2 s.
  func test_GivenTrace_WhenValueReachesLimit_ThenHeldTimeResets() {
    XCTAssertEqual(NoGpsCalibrationBarView.heldMs([]), 0)
    XCTAssertEqual(NoGpsCalibrationBarView.heldMs([10, 20, 100]), 0)
    XCTAssertEqual(NoGpsCalibrationBarView.heldMs([500, 10, 99]), 40)
    var still = [Double](repeating: 0, count: 150)
    XCTAssertEqual(NoGpsCalibrationBarView.heldMs(still), NoGpsCalibrationBarView.Constants.holdMs)
    still[149] = 100
    XCTAssertEqual(NoGpsCalibrationBarView.heldMs(still), 0)
  }

  /// The chip tells the progress, the try, the time held, that the box is waited for, or the peak.
  func test_GivenStatus_WhenBarIsShown_ThenChipTellsWhatMatters() {
    let status = FakeBarStatus()
    let still = [Double](repeating: 10, count: 150)
    status.fakeCalibration = .calibrating
    status.fakeProgress = 60
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: still), "60 %")
    status.fakeCalibration = .failedMoving
    status.fakeTries = 2
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: still),
                   String(format: L("nogps_calibrate_bar_try"), 2, 5))
    status.fakeTries = 1
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: [Double](repeating: 10, count: 70)),
                   String(format: L("nogps_calibrate_bar_held"), String(format: "%.1f", locale: .current, 1.4)))
    status.fakeCalibration = .none
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: [Double](repeating: 10, count: 70)),
                   String(format: L("nogps_calibrate_bar_held"), String(format: "%.1f", locale: .current, 1.4)))
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: still), L("nogps_calibrate_bar_waiting_box"))
    status.fakeBoxStill = true
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: still),
                   String(format: L("nogps_calibrate_bar_held"), String(format: "%.1f", locale: .current, 2.0)))
    let shaking = [Double](repeating: 20, count: 100) + [1800]
    XCTAssertEqual(NoGpsCalibrationBarView.chipText(status, values: shaking),
                   String(format: L("nogps_calibrate_bar_peak"), 18))
    XCTAssertNil(NoGpsCalibrationBarView.chipText(status, values: [Double](repeating: 150, count: 100)))
  }
}

private final class FakeBarStatus: NoGpsStatus {
  var fakeCalibration = NoGpsCalibrationState.none
  var fakeProgress = 0
  var fakeTries = 0
  var fakeBoxStill = false
  override var calibration: NoGpsCalibrationState { fakeCalibration }
  override var calibrationProgress: Int { fakeProgress }
  override var calibrationTries: Int { fakeTries }
  override var boxStill: Bool { fakeBoxStill }
}
