@testable import Organic_Maps__Debug_
import XCTest

final class NavigationSourceButtonTests: XCTestCase {
  /// The source button of the navigation sheet shows the box when the car follows it, or when the mark is set by hand
  /// with a box set up. Else it shows GPS.
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

  func test_GivenStateButton_WhenCaptionIsSetAndCleared_ThenItIsShownAndHidden() throws {
    let button = StateButton()
    let label = try XCTUnwrap(findLabel(in: button))
    XCTAssertTrue(label.isHidden)
    button.caption = "±5 m"
    XCTAssertFalse(label.isHidden)
    XCTAssertEqual(label.text, "±5 m")
    button.caption = nil
    XCTAssertTrue(label.isHidden)
  }

  private func findLabel(in view: UIView) -> UILabel? {
    for subview in view.subviews {
      if let label = subview as? UILabel ?? findLabel(in: subview) {
        return label
      }
    }
    return nil
  }
}
