@testable import Organic_Maps__Debug_
import XCTest

/// What the How NonGPS works page does with a link and a locale, see HowNoGpsController. The same decisions are
/// tested on Android in HowNoGpsFragmentTest.
final class HowNoGpsTests: XCTestCase {
  func testIntroLinkPlaysTheIntro() throws {
    let intro = try XCTUnwrap(URL(string: "nogps-guide://intro"))
    XCTAssertEqual(HowNoGpsController.action(for: intro), .intro)
  }

  func testWebLinksGoToTheBrowser() throws {
    let https = try XCTUnwrap(URL(string: "https://non-gps.com"))
    XCTAssertEqual(HowNoGpsController.action(for: https), .browser(https))
    let http = try XCTUnwrap(URL(string: "http://example.com/a"))
    XCTAssertEqual(HowNoGpsController.action(for: http), .browser(http))
  }

  func testTheBundledPageLoads() throws {
    let page = try XCTUnwrap(URL(string: "file:///bundle/nogps_guide.html?lang=uk"))
    XCTAssertEqual(HowNoGpsController.action(for: page), .load)
  }

  func testUkrainianForUkAndRuOnly() {
    XCTAssertEqual(HowNoGpsController.pageLang("uk"), "uk")
    XCTAssertEqual(HowNoGpsController.pageLang("ru"), "uk")
    XCTAssertEqual(HowNoGpsController.pageLang("de"), "en")
    XCTAssertEqual(HowNoGpsController.pageLang(nil), "en")
  }

  func testBundledPageIsInTheApp() {
    XCTAssertNotNil(Bundle.main.url(forResource: "nogps_guide", withExtension: "html"))
  }
}
