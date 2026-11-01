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
