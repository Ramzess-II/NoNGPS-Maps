@testable import Organic_Maps__Debug_
import XCTest

/// About NonGPS Maps fits a phone screen: the globe takes the height the other rows leave, between 200 and 400 pt.
final class NoGpsAboutLayoutTests: XCTestCase {
  private func laidOut(_ size: CGSize) -> (globe: GlobeSceneView, scroll: UIScrollView) {
    let controller = AboutNoGpsController()
    controller.view.frame = CGRect(origin: .zero, size: size)
    controller.view.layoutIfNeeded()
    let globe = controller.view.firstSubview(ofType: GlobeSceneView.self)!
    let scroll = controller.view.firstSubview(ofType: UIScrollView.self)!
    return (globe, scroll)
  }

  func testPageFitsTheScreenOfALargePhone() {
    let (globe, scroll) = laidOut(CGSize(width: 393, height: 852))
    XCTAssertLessThanOrEqual(scroll.contentSize.height, 852 - 40 + 0.5)
    XCTAssertGreaterThan(globe.frame.height, 200)
    XCTAssertLessThanOrEqual(globe.frame.height, GlobeScene.sceneHeightPt)
  }

  func testGlobeIsNotTallerThanTheScene() {
    let (globe, _) = laidOut(CGSize(width: 430, height: 2000))
    XCTAssertEqual(globe.frame.height, GlobeScene.sceneHeightPt, accuracy: 0.5)
  }

  func testSmallPhoneKeepsTheGlobeAtItsMinimumAndScrolls() {
    let (globe, scroll) = laidOut(CGSize(width: 375, height: 500))
    XCTAssertEqual(globe.frame.height, 200, accuracy: 0.5)
    XCTAssertGreaterThan(scroll.contentSize.height, 500 - 40)
  }
}

private extension UIView {
  func firstSubview<T: UIView>(ofType type: T.Type) -> T? {
    for subview in subviews {
      if let found = subview as? T ?? subview.firstSubview(ofType: type) {
        return found
      }
    }
    return nil
  }
}
