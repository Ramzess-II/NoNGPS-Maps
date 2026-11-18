@testable import Organic_Maps__Debug_
import XCTest

final class NoGpsSprintTests: XCTestCase {
  private let en = Locale(identifier: "en_US")
  private let de = Locale(identifier: "de_DE")

  /// Not a record: one line, the trap speed only for the quarter mile.
  func test_GivenNoRecord_WhenCard_ThenOneLine() {
    let to100 = NoGpsSprintText.card(kind: .to100, sec: 8.43, trapKmh: 0, bestSec: 8.0, record: false, locale: en)
    XCTAssertEqual(to100, NoGpsSprintText.Card(kind: nil, main: "0–100 km/h · 8.4 s", was: nil, isRecord: false))
    let quarter = NoGpsSprintText.card(kind: .quarterMile, sec: 15.21, trapKmh: 142, bestSec: 14, record: false,
                                       locale: en)
    XCTAssertEqual(quarter.main, "¼ mile · 15.2 s · 142 km/h")
    XCTAssertNil(quarter.kind)
    XCTAssertNil(quarter.was)
  }

  /// The seconds follow the format of the locale.
  func test_GivenLocale_WhenSeconds_ThenItsDecimalSeparator() {
    XCTAssertEqual(NoGpsSprintText.seconds(8.43, decimals: 1, locale: de), "8,4 s")
    XCTAssertEqual(NoGpsSprintText.seconds(8.4, decimals: 2, locale: en), "8.40 s")
  }

  /// A record has the kind small, the time big and the old time when there was one.
  func test_GivenRecord_WhenCard_ThenKindTimeAndWas() {
    let to100 = NoGpsSprintText.card(kind: .to100, sec: 8.43, trapKmh: 0, bestSec: 9.1, record: true, locale: en)
    XCTAssertEqual(to100, NoGpsSprintText.Card(kind: "0–100 km/h", main: "New record! 8.4 s", was: "Was 9.1 s",
                                               isRecord: true))
    let quarter = NoGpsSprintText.card(kind: .quarterMile, sec: 15.21, trapKmh: 142, bestSec: 15.8, record: true,
                                       locale: en)
    XCTAssertEqual(quarter.kind, "¼ mile · 142 km/h")
    XCTAssertEqual(quarter.main, "New record! 15.2 s")
    XCTAssertEqual(quarter.was, "Was 15.8 s")
  }

  /// The first result of a kind has nothing to compare with.
  func test_GivenFirstResult_WhenRecordCard_ThenNoWas() {
    let card = NoGpsSprintText.card(kind: .to100, sec: 8.43, trapKmh: 0, bestSec: 0, record: true, locale: en)
    XCTAssertEqual(card.main, "New record! 8.4 s")
    XCTAssertNil(card.was)
  }

  /// A record that reads the same with one decimal shows both with two.
  func test_GivenSameTenth_WhenRecordCard_ThenTwoDecimals() {
    let card = NoGpsSprintText.card(kind: .to100, sec: 8.41, trapKmh: 0, bestSec: 8.44, record: true, locale: en)
    XCTAssertEqual(card.main, "New record! 8.41 s")
    XCTAssertEqual(card.was, "Was 8.44 s")
    // Rounded to different tenths: one decimal is enough.
    let other = NoGpsSprintText.card(kind: .to100, sec: 8.44, trapKmh: 0, bestSec: 8.46, record: true, locale: en)
    XCTAssertEqual(other.main, "New record! 8.4 s")
    XCTAssertEqual(other.was, "Was 8.5 s")
  }

  /// The best time of a kind with two decimals, the trap with the quarter mile, the dash with none.
  func test_GivenSprints_WhenBest_ThenFastestOfKind() {
    let sprints = [FakeSprint(.to100, 8.9), FakeSprint(.quarterMile, 15.21, trap: 142), FakeSprint(.to100, 8.43),
                   FakeSprint(.quarterMile, 15.8, trap: 130), FakeSprint(.to100, 9.5)]
    XCTAssertEqual(NoGpsSprintText.best(of: .to100, in: sprints)?.sec, 8.43)
    XCTAssertEqual(NoGpsSprintText.bestText(of: .to100, in: sprints, locale: en), "8.43 s")
    XCTAssertEqual(NoGpsSprintText.bestText(of: .quarterMile, in: sprints, locale: en), "15.21 s · 142 km/h")
    XCTAssertEqual(NoGpsSprintText.results(of: .quarterMile, in: sprints).map(\.sec), [15.21, 15.8])
  }

  func test_GivenNoSprints_WhenBest_ThenUnknown() {
    XCTAssertNil(NoGpsSprintText.best(of: .to100, in: []))
    XCTAssertEqual(NoGpsSprintText.bestText(of: .to100, in: []), L("nogps_unknown"))
    XCTAssertEqual(NoGpsSprintText.bestText(of: .quarterMile, in: [FakeSprint(.to100, 8.4)]), L("nogps_unknown"))
  }

  /// The row of the list: the time, with the trap for the quarter mile.
  func test_GivenKind_WhenResult_ThenTrapOnlyForQuarter() {
    XCTAssertEqual(NoGpsSprintText.result(kind: .to100, sec: 8.4, trapKmh: 0, locale: en), "8.40 s")
    XCTAssertEqual(NoGpsSprintText.result(kind: .quarterMile, sec: 15.2, trapKmh: 142, locale: en), "15.20 s · 142 km/h")
  }
}

private final class FakeSprint: NoGpsSprint {
  private let fakeKind: NoGpsSprintKind
  private let fakeSec: Double
  private let fakeTrap: Int

  init(_ kind: NoGpsSprintKind, _ sec: Double, trap: Int = 0) {
    fakeKind = kind
    fakeSec = sec
    fakeTrap = trap
    super.init()
  }

  override var kind: NoGpsSprintKind { fakeKind }
  override var sec: Double { fakeSec }
  override var trapKmh: Int { fakeTrap }
}
