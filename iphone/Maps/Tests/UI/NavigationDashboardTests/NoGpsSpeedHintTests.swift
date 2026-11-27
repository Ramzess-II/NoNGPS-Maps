@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsSpeedHintTests: XCTestCase {
  /// The bar shows while the core asks for it, but never over the request to calibrate the box.
  func test_GivenCoreAsks_WhenBoxNeedsCalibration_ThenTheBarIsHidden() {
    let status = FakeHintStatus()
    status.fakeShown = true
    XCTAssertTrue(NoGpsSpeedHintView.isShown(status))
    status.fakeCalibration = .none
    XCTAssertFalse(NoGpsSpeedHintView.isShown(status))
    status.fakeCalibration = .done
    status.fakeShown = false
    XCTAssertFalse(NoGpsSpeedHintView.isShown(status))
  }

  /// With accurate GPS the bar tells how far is left to measure the range, without it to turn GPS on.
  func test_GivenRange_WhenGpsMeasuresOrNot_ThenTheBarTellsIt() {
    let status = FakeHintStatus()
    status.fakeRange = 5
    status.fakeCarM[5] = 120
    status.fakeGps = true
    let measuring = NoGpsSpeedHintView.texts(status)
    XCTAssertEqual(measuring.title, String(format: L("nogps_speed_hint_calibrating"), 50, 60))
    XCTAssertEqual(measuring.left, String(format: L("nogps_speed_table_left"), 180))
    XCTAssertEqual(measuring.subtitle, L("nogps_speed_hint_keep_gps"))
    XCTAssertFalse(measuring.noGps)

    status.fakeGps = false
    let noGps = NoGpsSpeedHintView.texts(status)
    XCTAssertEqual(noGps.title, String(format: L("nogps_speed_hint_not_calibrated"), 50, 60))
    XCTAssertNil(noGps.left)
    XCTAssertEqual(noGps.subtitle, L("nogps_speed_hint_turn_gps_on"))
    XCTAssertTrue(noGps.noGps)

    // The slowest range starts at 5 km/h.
    status.fakeRange = 0
    XCTAssertEqual(NoGpsSpeedHintView.texts(status).title, String(format: L("nogps_speed_hint_not_calibrated"), 5, 10))
  }

  /// A range measured tells how many are, a milestone what it means.
  func test_GivenRangeMeasured_WhenMilestone_ThenTheCelebrationTellsIt() {
    let status = FakeHintStatus()
    status.fakeRange = 5
    for i in 0 ... 4 {
      status.fakeScale[i] = 1.01
    }
    let range = NoGpsSpeedHintView.celebrationTexts(status)
    XCTAssertEqual(range.title, String(format: L("nogps_speed_hint_done"), 50, 60))
    XCTAssertEqual(range.subtitle, String(format: L("nogps_speed_hint_done_count"), 5, 14))
    status.fakeMilestone = .city
    XCTAssertEqual(NoGpsSpeedHintView.celebrationTexts(status).title, L("nogps_speed_hint_city"))
    status.fakeMilestone = .outOfTown
    XCTAssertEqual(NoGpsSpeedHintView.celebrationTexts(status).title, L("nogps_speed_hint_out_of_town"))
    status.fakeMilestone = .full
    XCTAssertEqual(NoGpsSpeedHintView.celebrationTexts(status).subtitle,
                   String(format: L("nogps_speed_hint_full_hint"), 14))
  }
}

private final class FakeHintStatus: NoGpsStatus {
  var fakeShown = false
  var fakeRange = 0
  var fakeGps = false
  var fakeMilestone = NoGpsSpeedMilestone.range
  var fakeCarM = [Double](repeating: 0, count: 14)
  var fakeScale = [Double](repeating: 0, count: 14)
  var fakeCalibration = NoGpsCalibrationState.done

  override var speedHintShown: Bool { fakeShown }
  override var speedHintRange: Int { fakeRange }
  override var speedHintGps: Bool { fakeGps }
  override var speedMilestone: NoGpsSpeedMilestone { fakeMilestone }
  override var gpsSpeedTableCarM: [NSNumber] { fakeCarM.map { NSNumber(value: $0) } }
  override var gpsSpeedTableScale: [NSNumber] { fakeScale.map { NSNumber(value: $0) } }
  override var source: NoGpsPositionSource { .inertial }
  override var inertialEnabled: Bool { true }
  override var inertialStarted: Bool { true }
  override var sourceState: NoGpsSourceState { .connected }
  override var bleState: NoGpsBleState { .connected }
  override var calibration: NoGpsCalibrationState { fakeCalibration }
  override var boxNeedsCalibration: Bool { fakeCalibration == .none }
}
