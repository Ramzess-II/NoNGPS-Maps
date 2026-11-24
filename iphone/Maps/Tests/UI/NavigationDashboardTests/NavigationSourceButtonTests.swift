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
extension NavigationSourceButtonTests {
  /// A box that locked itself out does not come back with the engine: a warning, not a search.
  func test_GivenBatteryLock_WhenBoxLookIsTaken_ThenItIsAWarning() {
    let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .boxBatteryLock)
    let look = NoGpsStatusBar.boxLook(status)
    XCTAssertEqual(look.color, .systemOrange)
    XCTAssertEqual(look.badge?.symbol, "exclamationmark")
    XCTAssertFalse(look.pulsing)
  }

  /// Bluetooth off matters more than the lockout: the box would not be heard after it is plugged back in.
  func test_GivenBatteryLock_WhenBluetoothIsOff_ThenItIsToldToo() {
    let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .boxBatteryLock)
    status.fakeBleState = .disabled
    let look = NoGpsStatusBar.boxLook(status)
    XCTAssertEqual(look.symbol, NavigationLiveActivitySymbol.asset("ic_nogps_bluetooth_off"))
    XCTAssertNil(look.badge)
    XCTAssertFalse(look.pulsing)
    XCTAssertEqual(NoGpsBoxPage.boxStateText(status), L("nogps_box_battery_lock") + " · " + L("nogps_box_bt_disabled"))
  }

  /// A phone that can't reach the box knows nothing of the car: no sleep sentence, only the link state.
  func test_GivenBoxSleeping_WhenPhoneCannotReachBox_ThenNoSleepText() {
    let off: [(NoGpsBleState, String)] = [
      (.off, "nogps_box_bt_disabled"), (.disabled, "nogps_box_bt_disabled"),
      (.noPermission, "nogps_box_bt_no_permission"), (.pairingFailed, "nogps_box_bt_pairing_failed"),
      (.bondLost, "nogps_box_bt_bond_lost"),
    ]
    for (ble, key) in off {
      let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .boxSleeping)
      status.fakeBleState = ble
      XCTAssertEqual(NoGpsBoxPage.boxStateText(status), L(key), "Bluetooth \(ble.rawValue)")
    }
  }

  /// While the phone searches, the sleep sentence explains the search.
  func test_GivenBoxSleeping_WhenPhoneSearches_ThenSleepTextStays() {
    let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .boxSleeping)
    status.fakeBleState = .searching
    XCTAssertEqual(NoGpsBoxPage.boxStateText(status), L("nogps_box_sleeping") + " · " + L("nogps_box_bt_searching"))
  }

  /// A failed pairing or a box that forgot the phone stops the search until the user acts: no waves.
  func test_GivenLinkFailed_WhenBoxLookIsTaken_ThenItAsksTheUser() {
    for ble in [NoGpsBleState.pairingFailed, .bondLost] {
      let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .connecting)
      status.fakeBleState = ble
      let look = NoGpsStatusBar.boxLook(status)
      XCTAssertEqual(look.color, .systemOrange, "Bluetooth \(ble.rawValue)")
      XCTAssertEqual(look.badge?.symbol, "exclamationmark", "Bluetooth \(ble.rawValue)")
      XCTAssertFalse(look.pulsing, "Bluetooth \(ble.rawValue)")
    }
  }

  /// The Box sheet tells what to do when the phone can't reach the box by itself, the steps tell the rest.
  func test_GivenBleState_WhenBoxIsSearched_ThenTheHintAndButtonTellWhatToDo() {
    let cases: [(ble: NoGpsBleState, hint: String?, action: String?)] = [
      (.searching, nil, nil),
      (.connecting, nil, nil),
      (.disabled, nil, nil),
      (.noPermission, nil, L("nogps_box_allow")),
      (.pairingClosed, L("nogps_box_bt_pairing_closed"), nil),
      (.pairingByPhone, L("nogps_box_bt_pairing_by_phone"), nil),
      (.pairingFull, L("nogps_box_bt_pairing_full"), nil),
      (.carLimit, L("nogps_box_bt_car_limit"), nil),
      (.pairing, L("nogps_box_bt_pairing"), nil),
      (.pairingFailed, L("nogps_box_bt_pairing_failed"), L("nogps_box_try_again")),
      (.bondLost, L("nogps_box_bt_bond_lost"), L("nogps_box_try_again")),
    ]
    for c in cases {
      XCTAssertEqual(NoGpsBoxSheet.linkHintText(c.ble)?.lowercased(), c.hint?.lowercased(), "Bluetooth \(c.ble.rawValue)")
      XCTAssertEqual(NoGpsBoxSheet.linkActionText(c.ble), c.action, "Bluetooth \(c.ble.rawValue)")
    }
  }

  /// The system dialog wants the recovery code of the box in the pairing window, when the box has told it.
  func test_GivenRecoveryCode_WhenBoxIsNotPaired_ThenTheHintHasTheCode() {
    for ble: NoGpsBleState in [.pairingByPhone, .pairingFull, .pairing] {
      XCTAssertTrue(NoGpsBoxSheet.linkHintText(ble, recoveryCode: "654321")?.hasSuffix("654321") ?? false,
                    "Bluetooth \(ble.rawValue)")
    }
    for ble: NoGpsBleState in [.pairingClosed, .bondLost, .pairingFailed] {
      XCTAssertEqual(NoGpsBoxSheet.linkHintText(ble, recoveryCode: "654321"), NoGpsBoxSheet.linkHintText(ble))
    }
  }

  /// The box is heard but the car gives no speed: the hint names what to check. It doesn't flip while the box searches
  /// the car protocol again.
  func test_GivenObdState_WhenBoxIsHeard_ThenTheHintTellsWhatToCheck() {
    let cases: [(state: NoGpsSourceState, ble: NoGpsBleState, hint: String?)] = [
      (.noCarData, .connected, L("nogps_box_hint_no_car")),
      (.obdConnecting, .connected, L("nogps_box_hint_no_car")),
      (.noAdapter, .connected, L("nogps_box_hint_no_adapter")),
      (.obdError, .connected, L("nogps_box_hint_obd_error")),
      (.obdDisabled, .connected, L("nogps_box_hint_obd_disabled")),
      (.connected, .connected, nil),
      (.obdSleeping, .connected, nil),
      (.connecting, .connected, nil),
      (.noCarData, .searching, nil),
    ]
    for c in cases {
      let status = FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: c.state)
      status.fakeBleState = c.ble
      XCTAssertEqual(NoGpsBoxSheet.obdHintText(status), c.hint, "OBD \(c.state.rawValue), Bluetooth \(c.ble.rawValue)")
    }
  }

  /// The bar on the map asks to calibrate the box while this phone can: the box is connected and not read-only.
  func test_GivenCalibration_WhenBoxIsConnected_ThenTheMapAsksToCalibrate() {
    let cases: [(calibration: NoGpsCalibrationState, advised: Bool, asks: Bool)] = [
      (.none, false, true),
      (.calibrating, true, false),
      (.done, false, false),
      (.done, true, true),
      (.failedMoving, false, true),
      (.mountMoved, false, true),
      (.linkLost, false, true),
    ]
    for c in cases {
      let status = FakeStatus(source: .inertial, gpsState: .none, inertialEnabled: true, sourceState: .connected)
      status.fakeCalibration = c.calibration
      status.fakeCalibrationAdvised = c.advised
      XCTAssertEqual(NoGpsBoxPage.needsCalibration(status), c.asks, "Calibration \(c.calibration.rawValue)")
    }
    let readOnly = FakeStatus(source: .inertial, gpsState: .none, inertialEnabled: true, sourceState: .connected)
    readOnly.fakeReadOnly = true
    XCTAssertFalse(NoGpsBoxPage.needsCalibration(readOnly))
    let away = FakeStatus(source: .inertial, gpsState: .none, inertialEnabled: true, sourceState: .connected)
    away.fakeBleState = .searching
    XCTAssertFalse(NoGpsBoxPage.needsCalibration(away))
    let notHeard = FakeStatus(source: .inertial, gpsState: .none, inertialEnabled: true, sourceState: .connecting)
    XCTAssertFalse(NoGpsBoxPage.needsCalibration(notHeard))
  }
}

/// The Live Activity of the navigation shows the look of the bottom sheet.
@available(iOS 16.2, *)
final class NavigationLiveActivityTests: XCTestCase {
  private let info = NavigationLiveActivityInfo(turnImageName: "simple_right", distanceToTurn: "500 m",
                                                street: "Main Street", distanceLeft: "12.4 km", timeLeft: "18 min",
                                                arrival: Date(timeIntervalSince1970: 1_800_000_000))

  func test_GivenStatus_WhenStateIsBuilt_ThenItHasTheSymbolsAndColorOfTheBarLook() {
    let cases: [FakeStatus] = [
      FakeStatus(source: .gps, gpsState: .good, inertialEnabled: true, sourceState: .connected),
      FakeStatus(source: .gps, gpsState: .coarse, inertialEnabled: false, sourceState: .connected),
      FakeStatus(source: .inertial, gpsState: .none, inertialEnabled: true, sourceState: .connected),
      FakeStatus(source: .inertial, gpsState: .spoofed, inertialEnabled: true, sourceState: .noCarData),
    ]
    for status in cases {
      let look = NoGpsStatusBar.barLook(status)
      let state = NavigationLiveActivityManager.makeState(status: status, info: info)
      XCTAssertEqual(state.source.symbol, look.symbol)
      XCTAssertEqual(state.source.color.uiColor, look.color)
      XCTAssertEqual(state.source.hasBadge, look.badge != nil)
      XCTAssertEqual(state.source.badgeSymbol, look.badge?.symbol)
      XCTAssertEqual(state.distanceToTurn, "500 m")
      XCTAssertEqual(state.street, "Main Street")
      XCTAssertEqual(state.turnSymbol, "arrow.turn.up.right")
    }
    let box = NavigationLiveActivityManager.makeState(status: cases[2], info: info)
    XCTAssertEqual(box.source.color, .inertial)
    XCTAssertEqual(box.source.symbol, .system("cpu"))
  }

  func test_GivenColor_WhenKeyIsMade_ThenItRoundTrips() {
    for key: NavigationLiveActivityColor in [.good, .inertial, .blue, .orange, .red, .gray, .secondary] {
      XCTAssertEqual(NavigationLiveActivityColor(key.uiColor), key)
    }
  }

  func test_GivenStateUnchanged_WhenPushing_ThenItIsPushedOnlyAfterTheRefreshInterval() {
    let state = NavigationLiveActivityManager.makeState(status: FakeStatus(source: .gps, gpsState: .good,
                                                                           inertialEnabled: true,
                                                                           sourceState: .connected), info: info)
    XCTAssertTrue(NavigationLiveActivityManager.shouldPush(state, last: nil, sinceLastPush: 0))
    XCTAssertFalse(NavigationLiveActivityManager.shouldPush(state, last: state, sinceLastPush: 1))
    XCTAssertFalse(NavigationLiveActivityManager.shouldPush(state, last: state, sinceLastPush: 59))
    XCTAssertTrue(NavigationLiveActivityManager.shouldPush(state, last: state, sinceLastPush: 60))
    var other = info
    other.distanceToTurn = "400 m"
    let changed = NavigationLiveActivityManager.makeState(status: FakeStatus(source: .gps, gpsState: .good,
                                                                             inertialEnabled: true,
                                                                             sourceState: .connected), info: other)
    XCTAssertTrue(NavigationLiveActivityManager.shouldPush(changed, last: state, sinceLastPush: 1))
  }

  func test_GivenSeconds_WhenArrivalIsMade_ThenItIsToTheMinute() {
    let now = Date(timeIntervalSince1970: 1_800_000_000 + 25)
    let a = NavigationLiveActivityInfo.arrival(now: now, secondsLeft: 10)
    let b = NavigationLiveActivityInfo.arrival(now: now.addingTimeInterval(3), secondsLeft: 10)
    XCTAssertEqual(a, b)
    XCTAssertEqual(a.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
  }

  func test_GivenTurnImages_WhenSymbolIsMade_ThenEveryTurnHasOne() {
    XCTAssertEqual(NavigationLiveActivityAttributes.ContentState.turnSymbol(imageName: "uturn_left"), "arrow.uturn.left")
    XCTAssertEqual(NavigationLiveActivityAttributes.ContentState.turnSymbol(imageName: "finish_point"), "flag.checkered")
    XCTAssertEqual(NavigationLiveActivityAttributes.ContentState.turnSymbol(imageName: nil), "arrow.up")
    for name in ["simple_right", "simple_left", "slight_right", "slight_left", "sharp_right", "sharp_left",
                 "uturn_left", "uturn_right", "round", "finish_point", "straight", "ic_exit_highway_to_right",
                 "ic_exit_highway_to_left"] {
      XCTAssertNotNil(UIImage(systemName: NavigationLiveActivityAttributes.ContentState.turnSymbol(imageName: name)),
                      name)
    }
  }
}

final class FakeStatus: NoGpsStatus {
  let fakeSource: NoGpsPositionSource
  let fakeGpsState: NoGpsGpsState
  let fakeInertialEnabled: Bool
  let fakeSourceState: NoGpsSourceState
  var fakeGpsDisabled = false
  var fakeBleState = NoGpsBleState.connected
  var fakeCalibration = NoGpsCalibrationState.done
  var fakeCalibrationAdvised = false
  var fakeReadOnly = false

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
  override var calibration: NoGpsCalibrationState { fakeCalibration }
  override var boxCalibrationAdvised: Bool { fakeCalibrationAdvised }
  override var boxReadOnly: Bool { fakeReadOnly }
}
