@testable import Organic_Maps__Debug_
import XCTest

final class NavigationSourceButtonTests: XCTestCase {
  /// The navigation button shows the box when the car follows it, or when the mark is set by hand with a box set up.
  /// Else it shows GPS.
  func test_GivenSource_WhenNavButtonIsShown_ThenItShowsTheBoxOnlyForTheBox() {
    let cases: [(source: NoGpsPositionSource, inertialEnabled: Bool, isBox: Bool)] = [
      (.gps, true, false),
      (.network, true, false),
      (.inertial, true, true),
      (.manual, true, true),
      (.manual, false, false),
      (.none, true, false),
      (.none, false, false),
    ]
    for c in cases {
      XCTAssertEqual(NoGpsStatusBar.navShowsBox(source: c.source, inertialEnabled: c.inertialEnabled), c.isBox,
                     "source \(c.source.rawValue), box set up \(c.inertialEnabled)")
    }
  }

  func test_GivenGpsMovesTheMark_WhenBarLookIsTaken_ThenItIsTheLookOfGps() {
    let cases: [(state: NoGpsGpsState, disabled: Bool, color: UIColor, badge: String?, pulsing: Bool)] = [
      (.good, false, NoGpsStatusBar.goodColor, nil, false),
      (.checking, false, .systemBlue, nil, true),
      (.coarse, false, .systemOrange, nil, false),
      (.spoofed, false, .systemOrange, "exclamationmark", false),
      (.none, false, .systemRed, nil, false),
      (.good, true, NoGpsStatusBar.goodColor, "pause.fill", false),
    ]
    for c in cases {
      // The box connected doesn't add a badge.
      let status = FakeStatus(source: .gps, gpsState: c.state, inertialEnabled: true, sourceState: .connected)
      status.fakeGpsDisabled = c.disabled
      let look = NoGpsStatusBar.barLook(status)
      XCTAssertEqual(look.color, c.color, "GPS \(c.state.rawValue)")
      XCTAssertEqual(look.badge?.symbol, c.badge, "GPS \(c.state.rawValue)")
      XCTAssertEqual(look.pulsing, c.pulsing, "GPS \(c.state.rawValue)")
    }
  }

  func test_GivenBoxMovesTheMark_WhenBarLookIsTaken_ThenItIsPurple() {
    let inertial = NoGpsStatusBar.barLook(FakeStatus(source: .inertial, gpsState: .good, inertialEnabled: true,
                                                     sourceState: .connected))
    XCTAssertEqual(inertial.color, NoGpsStatusBar.inertialColor)
    XCTAssertNil(inertial.badge)
  }

  func test_GivenMarkByHandWithBox_WhenGpsIsLost_ThenTheBoxShowsARedDot() {
    let look = NoGpsStatusBar.barLook(FakeStatus(source: .manual, gpsState: .none, inertialEnabled: true,
                                                 sourceState: .connected))
    XCTAssertEqual(look.color, NoGpsStatusBar.inertialColor)
    XCTAssertNotNil(look.badge)
    XCTAssertNil(look.badge?.symbol)
    XCTAssertEqual(look.badge?.color, .systemRed)
  }

  func test_GivenGpsGood_WhenBoxIsSearched_ThenThereIsNoBadge() {
    let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .disconnected)
    status.fakeBleState = .searching
    let look = NoGpsStatusBar.barLook(status)
    XCTAssertEqual(look.color, NoGpsStatusBar.goodColor)
    XCTAssertNil(look.badge)
  }

  func test_GivenNoBox_WhenBarLookIsTaken_ThenItInvitesToSetOneUp() {
    let look = NoGpsStatusBar.barLook(FakeStatus(source: .gps, gpsState: .good, inertialEnabled: false,
                                                 sourceState: .disconnected))
    XCTAssertEqual(look.color, NoGpsStatusBar.goodColor)
    XCTAssertEqual(look.badge?.symbol, "plus")
    // Its own badge comes first.
    let spoofed = NoGpsStatusBar.barLook(FakeStatus(source: .manual, gpsState: .spoofed, inertialEnabled: false,
                                                    sourceState: .disconnected))
    XCTAssertEqual(spoofed.badge?.symbol, "exclamationmark")
  }

  func test_GivenGpsGood_WhenBoxHasNoCarData_ThenItShowsAnOrangeDot() {
    let look = NoGpsStatusBar.barLook(FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true,
                                                 sourceState: .noCarData))
    XCTAssertEqual(look.color, NoGpsStatusBar.goodColor)
    XCTAssertNil(look.badge?.symbol)
    XCTAssertEqual(look.badge?.color, .systemOrange)
  }
}

/// A status with the values a test sets.
private final class FakeStatus: NoGpsStatus {
  let fakeSource: NoGpsPositionSource
  let fakeGpsState: NoGpsGpsState
  let fakeInertialEnabled: Bool
  let fakeSourceState: NoGpsSourceState
  var fakeGpsDisabled = false
  var fakeBleState = NoGpsBleState.connected

  init(source: NoGpsPositionSource, gpsState: NoGpsGpsState, inertialEnabled: Bool, sourceState: NoGpsSourceState) {
    fakeSource = source
    fakeGpsState = gpsState
    fakeInertialEnabled = inertialEnabled
    fakeSourceState = sourceState
    super.init()
  }

  override var source: NoGpsPositionSource { fakeSource }
  override var gpsState: NoGpsGpsState { fakeGpsState }
  override var gpsDisabled: Bool { fakeGpsDisabled }
  override var inertialEnabled: Bool { fakeInertialEnabled }
  override var inertialStarted: Bool { fakeInertialEnabled }
  override var sourceState: NoGpsSourceState { fakeSourceState }
  override var bleState: NoGpsBleState { fakeBleState }
}
