@testable import Organic_Maps__Debug_
import XCTest

/// The step machine and the typewriter of the intro of the first start, see NoGpsIntroSequence. The same tests run on
/// Android, see nogps.intro.IntroTest.
final class NoGpsIntroTests: XCTestCase {
  /// Longer than any balloon: it takes more than one tick of the typewriter to appear.
  private let text = 40

  func testStepsFollowTheModal() {
    let sequence = NoGpsIntroSequence()
    XCTAssertEqual(sequence.step, .modal)
    // The modal is not typed: the accent button opens the first balloon at once.
    XCTAssertFalse(sequence.isTyping(text, 0))
    sequence.tap(text, 0)
    XCTAssertEqual(sequence.step, .bottom)
    sequence.tap(text, Double(text))
    XCTAssertEqual(sequence.step, .right)
    sequence.tap(text, Double(text))
    XCTAssertEqual(sequence.step, .left)
    XCTAssertFalse(sequence.isOver)
  }

  func testTextsOfTheSteps() {
    XCTAssertFalse(NoGpsIntroStep.modal.isTyped)
    for step in [NoGpsIntroStep.bottom, .right, .left] {
      XCTAssert(step.isTyped)
      XCTAssertFalse(step.text.isEmpty)
    }
    // The slide of the zoom buttons is told on iOS only, and is appended to the balloon of the right panel.
    XCTAssert(NoGpsIntroStep.right.text.hasSuffix(L("nogps_intro_right_swipe")))
    XCTAssert(NoGpsIntroStep.right.text.hasPrefix(L("nogps_intro_right")))
  }

  func testTypesAboutThirtyCharactersASecond() {
    let sequence = NoGpsIntroSequence()
    sequence.tap(text, 0)
    XCTAssertEqual(sequence.step, .bottom)
    XCTAssertEqual(sequence.revealed(text, 0), 0)
    XCTAssertEqual(sequence.revealed(text, 0.5), 15)
    XCTAssertEqual(sequence.revealed(text, 1), 30)
    // Never past the end of the text.
    XCTAssertEqual(sequence.revealed(text, 100), text)
    XCTAssertFalse(sequence.isTyping(text, 100))
    XCTAssertEqual(NoGpsIntroSequence.typeCharsPerS, 30)
  }

  func testTapWhileTypingShowsTheRestAndTheNextTapAdvances() {
    let sequence = NoGpsIntroSequence()
    sequence.tap(text, 0)
    XCTAssert(sequence.isTyping(text, 1))
    sequence.tap(text, 1)
    // The same step, with the whole text: the typewriter is over.
    XCTAssertEqual(sequence.step, .bottom)
    XCTAssertEqual(sequence.revealed(text, 1), text)
    XCTAssertFalse(sequence.isTyping(text, 1))
    sequence.tap(text, 1)
    XCTAssertEqual(sequence.step, .right)
    // The next step types from the start again.
    XCTAssert(sequence.isTyping(text, 1))
  }

  func testTheLastTapEndsTheIntro() {
    let sequence = NoGpsIntroSequence()
    for _ in NoGpsIntroStep.allCases {
      XCTAssertFalse(sequence.isOver)
      sequence.tap(text, Double(text))
    }
    XCTAssert(sequence.isOver)
    XCTAssertNil(sequence.step)
    // Nothing is shown after it, and a tap changes nothing.
    sequence.tap(text, Double(text))
    XCTAssert(sequence.isOver)
    XCTAssertEqual(sequence.revealed(text, Double(text)), 0)
  }

  func testNavigationFinishesTheIntro() {
    let sequence = NoGpsIntroSequence()
    sequence.tap(text, 0)
    XCTAssertEqual(sequence.step, .bottom)
    sequence.finish()
    XCTAssert(sequence.isOver)
  }

  func testTheFlagShowsItOnlyOnce() {
    XCTAssert(NoGpsIntroSequence.isNeeded(shown: false, navigating: false))
    // The second start of the app.
    XCTAssertFalse(NoGpsIntroSequence.isNeeded(shown: true, navigating: false))
    // Not over the navigation, even on the first start.
    XCTAssertFalse(NoGpsIntroSequence.isNeeded(shown: false, navigating: true))
    XCTAssertFalse(NoGpsIntroSequence.isNeeded(shown: true, navigating: true))
  }

  func testBalloonArrowStaysInsideTheBody() {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 80)
    // A tip far outside the balloon is kept in its flat side, not in a rounded corner.
    for tip in [CGFloat(-100), 0, 100, 300] {
      for onTop in [true, false] {
        let path = NoGpsIntroOverlay.balloonPath(in: frame, tipX: tip, arrowOnTop: onTop)
        XCTAssert(frame.insetBy(dx: -0.5, dy: -0.5).contains(path.bounds), "\(path.bounds) with \(tip)")
      }
    }
  }
}
