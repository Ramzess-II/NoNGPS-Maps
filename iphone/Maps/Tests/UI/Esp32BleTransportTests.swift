@testable import Organic_Maps__Debug_
import XCTest

final class Esp32BleTransportTests: XCTestCase {
  private func end(heard: Bool = false, known: Bool = true, closedTry: Bool = false, worked: Bool = false,
                   linkedFor: TimeInterval? = 4, silent: Int = 0, since: TimeInterval = 10, lost: Bool = false,
                   delay: TimeInterval = 2) -> Esp32BleTransport.ConnectionEnd {
    Esp32BleTransport.afterConnection(heard: heard, known: known, closedTry: closedTry, worked: worked,
                                      linkedFor: linkedFor, silentConnections: silent, sinceLastSilent: since,
                                      bondLost: lost, retryDelay: delay)
  }

  func testSixthSilentConnectionGivesTheHintAndSearchesOnceAMinute() {
    let fifth = end(silent: 4)
    XCTAssertEqual(fifth.silentConnections, 5)
    XCTAssertFalse(fifth.bondLost)
    XCTAssertEqual(fifth.retryDelay, 4)
    let sixth = end(silent: 5)
    XCTAssertEqual(sixth.silentConnections, 6)
    XCTAssertTrue(sixth.bondLost)
    XCTAssertFalse(sixth.pairingFailed)
    XCTAssertEqual(sixth.retryDelay, 60)
    // Still silent: the hint stays, the search goes on.
    let seventh = end(silent: 6, lost: true, delay: 60)
    XCTAssertTrue(seventh.bondLost)
    XCTAssertEqual(seventh.retryDelay, 60)
  }

  func testHeardConnectionIsNotSilent() {
    let result = end(heard: true, worked: true, silent: 3, lost: true, delay: 60)
    XCTAssertFalse(result.isSilent)
    XCTAssertEqual(result.retryDelay, 2)
    // The caller drops the hint when the box is heard.
  }

  func testShortConnectionIsNotCounted() {
    let result = end(linkedFor: 2.9, silent: 2)
    XCTAssertFalse(result.isSilent)
    XCTAssertEqual(result.silentConnections, 2)
    XCTAssertFalse(end(linkedFor: nil).isSilent)
  }

  func testSilentConnectionsFarApartStartAgain() {
    let result = end(silent: 5, since: 181)
    XCTAssertEqual(result.silentConnections, 1)
    XCTAssertFalse(result.bondLost)
  }

  func testNewBoxWithoutDataIsAFailedPairing() {
    XCTAssertTrue(end(known: false).pairingFailed)
    XCTAssertFalse(end(known: false, linkedFor: 1).pairingFailed)
  }

  func testClosedTryIsNeitherFailedNorSilent() {
    let result = end(known: false, closedTry: true)
    XCTAssertFalse(result.pairingFailed)
    XCTAssertFalse(result.isSilent)
  }

  private func found(known: Bool = false, open: Bool = true, phones: Bool = false, adds: Bool = false,
                     cars: Bool = true, knownBoxes: Bool = false, since: TimeInterval = 5,
                     tried: Bool = false) -> Esp32BleTransport.FoundBox {
    Esp32BleTransport.foundBox(known: known, pairingOpen: open, hasPhones: phones, addsCar: adds, hasCars: cars,
                               hasKnownBoxes: knownBoxes, sinceSearchStart: since, tried: tried)
  }

  func testKnownBoxIsConnected() {
    XCTAssertEqual(found(known: true, open: false), .connect)
  }

  func testNewBoxWithOpenWindowIsTakenAfterThreeSeconds() {
    XCTAssertEqual(found(knownBoxes: true, since: 2.9), .wait)
    XCTAssertEqual(found(knownBoxes: true, since: 3), .connect)
    XCTAssertEqual(found(knownBoxes: false, since: 0), .connect)
    XCTAssertEqual(found(adds: true, knownBoxes: true, since: 0), .connect)
  }

  func testClosedWindowWithPhonesIsTriedOnceWhenAddingACarOrWithoutCars() {
    XCTAssertEqual(found(open: false, phones: true, adds: true), .connectClosed)
    XCTAssertEqual(found(open: false, phones: true, cars: false), .connectClosed)
    XCTAssertEqual(found(open: false, phones: true, adds: true, tried: true), .skip)
  }

  func testClosedWindowIsOnlyHintedOtherwise() {
    XCTAssertEqual(found(open: false, phones: true), .skip)
    XCTAssertEqual(found(open: false, phones: false, adds: true), .skip)
    XCTAssertEqual(found(open: false, phones: false, cars: false), .skip)
  }
}
