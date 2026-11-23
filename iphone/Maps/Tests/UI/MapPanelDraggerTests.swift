@testable import Organic_Maps__Debug_
import XCTest

final class MapPanelDraggerTests: XCTestCase {
  private typealias Dragger = MapPanelDragger
  private let dt = CGFloat(1) / 60

  func testFlingSlowsToStop() {
    var (y, v) = (CGFloat(0), CGFloat(1000))
    var frames = 0
    while v != 0 {
      let previous = v
      (y, v) = Dragger.step(y: y, v: v, dt: dt, min: 0, max: 10000)
      XCTAssertLessThan(v, previous)
      XCTAssertGreaterThanOrEqual(v, 0)
      frames += 1
      XCTAssertLessThan(frames, 1000)
    }
    // A scroll view flung with 1000 pt/s goes about 500 pt.
    XCTAssertEqual(y, 1000 / -log(Dragger.Constants.deceleration) / 1000, accuracy: 20)
  }

  func testBouncesAtEachEnd() {
    let decay = pow(Dragger.Constants.deceleration, dt * 1000)
    var step = Dragger.step(y: 99, v: 1000, dt: dt, min: 0, max: 100)
    XCTAssertEqual(step.v, -1000 * decay * Dragger.Constants.bounce, accuracy: 0.001)
    XCTAssertLessThanOrEqual(step.y, 100)
    step = Dragger.step(y: 1, v: -1000, dt: dt, min: 0, max: 100)
    XCTAssertEqual(step.v, 1000 * decay * Dragger.Constants.bounce, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(step.y, 0)
  }

  func testNeverLeavesRange() {
    for v in [CGFloat(-50000), -3000, 3000, 50000] {
      var (y, speed) = (CGFloat(50), v)
      // A long frame too, e.g. after the app was in the background.
      for dt in [dt, dt, 1, dt] + Array(repeating: dt, count: 500) {
        (y, speed) = Dragger.step(y: y, v: speed, dt: dt, min: 0, max: 100)
        XCTAssert((0 ... 100).contains(y), "\(y) with \(v)")
      }
      XCTAssertEqual(speed, 0)
    }
  }

  func testSlowReleaseDoesNotMove() {
    XCTAssertFalse(Dragger.flings(0))
    XCTAssertFalse(Dragger.flings(Dragger.Constants.flingSpeed - 1))
    XCTAssertFalse(Dragger.flings(-Dragger.Constants.flingSpeed + 1))
    XCTAssert(Dragger.flings(Dragger.Constants.flingSpeed))
    XCTAssert(Dragger.flings(-Dragger.Constants.flingSpeed))
    // A slow fling stops at once.
    let step = Dragger.step(y: 50, v: Dragger.Constants.stopSpeed / 2, dt: dt, min: 0, max: 100)
    XCTAssertEqual(step.v, 0)
  }
}

final class MapControlsPanelTests: XCTestCase {
  private func button(_ y: CGFloat, hidden: Bool = false) -> UIView {
    let view = UIView(frame: CGRect(x: 0, y: y, width: 56, height: 48))
    view.isHidden = hidden
    return view
  }

  func testGapGoesToNearerButton() {
    let (upper, lower) = (button(0), button(56))
    let buttons = [upper, lower]
    XCTAssertTrue(MapControlsPanel.button(at: CGPoint(x: 28, y: 51), in: buttons) === upper)
    XCTAssertTrue(MapControlsPanel.button(at: CGPoint(x: 28, y: 53), in: buttons) === lower)
  }

  func testMarginIsTwelvePoints() {
    let buttons = [button(100)]
    XCTAssertNotNil(MapControlsPanel.button(at: CGPoint(x: 28, y: 89), in: buttons))
    XCTAssertNil(MapControlsPanel.button(at: CGPoint(x: 28, y: 87), in: buttons))
    XCTAssertNotNil(MapControlsPanel.button(at: CGPoint(x: -11, y: 120), in: buttons))
    XCTAssertNil(MapControlsPanel.button(at: CGPoint(x: -13, y: 120), in: buttons))
  }

  func testHiddenButtonIsSkipped() {
    let (hidden, shown) = (button(0, hidden: true), button(56))
    XCTAssertTrue(MapControlsPanel.button(at: CGPoint(x: 28, y: 46), in: [hidden, shown]) === shown)
    XCTAssertNil(MapControlsPanel.button(at: CGPoint(x: 28, y: 5), in: [hidden]))
  }

  func testBottomEdgeOfUpperButtonGoesToUpperButton() {
    // No gap: the lower button starts where the upper one ends.
    let (upper, lower) = (button(0), button(48))
    XCTAssertTrue(MapControlsPanel.button(at: CGPoint(x: 28, y: 48), in: [upper, lower]) === upper)
    XCTAssertTrue(MapControlsPanel.button(at: CGPoint(x: 28, y: 47), in: [upper, lower]) === upper)
    XCTAssertTrue(MapControlsPanel.button(at: CGPoint(x: 28, y: 50), in: [upper, lower]) === lower)
  }

  func testPanelButtonKeepsStateTint() {
    let button = NoGpsPanelButton()
    button.stateTint = .linkBlue
    button.isHighlighted = true
    button.isHighlighted = false
    XCTAssertEqual(button.tintColor, .linkBlue)
  }

  func testPillTakesTapsUpToMinHeight() {
    let pill = NoGpsPillButton(frame: CGRect(x: 0, y: 0, width: 100, height: 36))
    XCTAssertTrue(pill.point(inside: CGPoint(x: 50, y: -5), with: nil))
    XCTAssertFalse(pill.point(inside: CGPoint(x: 50, y: -7), with: nil))
    XCTAssertFalse(pill.point(inside: CGPoint(x: 120, y: 10), with: nil))
  }
}

final class ZoomSlideTests: XCTestCase {
  func testFactorFollowsDistance() {
    XCTAssertEqual(ZoomSlide.factor(slide: 0, frameHeight: 1000), 1, accuracy: 1e-9)
    XCTAssertEqual(ZoomSlide.factor(slide: 1000, frameHeight: 1000), exp(ZoomSlide.gain), accuracy: 1e-9)
    // Up zooms in, down zooms out, by the same amount.
    let up = ZoomSlide.factor(slide: 300, frameHeight: 1000)
    XCTAssertEqual(ZoomSlide.factor(slide: -300, frameHeight: 1000), 1 / up, accuracy: 1e-9)
  }

  func testSlideSplitInStepsZoomsAsOneSlide() {
    // The same finger travel zooms the same on a 60 Hz and a 120 Hz panel.
    let coarse = ZoomSlide()
    coarse.start(at: 0)
    let twoMoves = coarse.step(to: 100, frameHeight: 800) * coarse.step(to: 200, frameHeight: 800)
    let fine = ZoomSlide()
    fine.start(at: 0)
    var manyMoves = CGFloat(1)
    for i in 1 ... 20 {
      manyMoves *= fine.step(to: CGFloat(i) * 10, frameHeight: 800)
    }
    XCTAssertEqual(manyMoves, twoMoves, accuracy: 1e-9)
    XCTAssertEqual(manyMoves, ZoomSlide.factor(slide: 200, frameHeight: 800), accuracy: 1e-9)
  }

  func testRestingFingerHoldsTheZoom() {
    let slide = ZoomSlide()
    // The zoom counts from where the slide became a zoom: the first move does not jump.
    slide.start(at: 24)
    XCTAssertEqual(slide.step(to: 24, frameHeight: 800), 1)
    XCTAssertEqual(slide.step(to: 100, frameHeight: 800), ZoomSlide.factor(slide: 76, frameHeight: 800),
                   accuracy: 1e-9)
    // The same finger position reported again zooms no further, whatever the rate of the touch events.
    XCTAssertEqual(slide.step(to: 100, frameHeight: 800), 1)
    XCTAssertEqual(slide.step(to: 100, frameHeight: 800), 1)
    // The finger comes back: the zoom goes back with it.
    XCTAssertEqual(slide.step(to: 24, frameHeight: 800), 1 / ZoomSlide.factor(slide: 76, frameHeight: 800),
                   accuracy: 1e-9)
  }
}
