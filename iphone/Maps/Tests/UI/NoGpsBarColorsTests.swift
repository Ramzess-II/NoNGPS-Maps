@testable import Organic_Maps__Debug_
import XCTest

/// The bars take the NonGPS cream in the light theme and the grey of the night one, not the Organic Maps green.
final class NoGpsBarColorsTests: XCTestCase {
  private let light = UITraitCollection(userInterfaceStyle: .light)
  private let dark = UITraitCollection(userInterfaceStyle: .dark)

  private func rgb(_ color: UIColor, _ traits: UITraitCollection) -> [Int] {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
    return [r, g, b].map { Int(($0 * 255).rounded()) }
  }

  private func style(_ sheet: GlobalStyleSheet) throws -> Style {
    let style = Style()
    guard case .add(let resolver) = sheet.styleResolver else { throw XCTSkip("\(sheet) is not a plain style") }
    resolver(style)
    return style
  }

  func testPrimaryIsCreamInLightAndGreyAtNight() {
    XCTAssertEqual(rgb(.nogpsPrimary, light), [0xE3, 0xE1, 0xD2])
    XCTAssertEqual(rgb(.nogpsPrimary, dark), rgb(.greenPrimary, dark))
  }

  func testTextIsDarkInLightAndLightAtNight() {
    XCTAssertEqual(rgb(.nogpsPrimaryText, light), rgb(.blackPrimaryText, light))
    XCTAssertEqual(rgb(.nogpsPrimaryText, dark), rgb(.whitePrimaryText, dark))
  }

  func testBarStylesCarryThem() throws {
    let bar = try style(.navigationBar)
    XCTAssertEqual(bar.barTintColor, .nogpsPrimary)
    XCTAssertEqual(bar.tintColor, .nogpsPrimaryText)
    XCTAssertEqual(bar.fontColor, .nogpsPrimaryText)
    XCTAssertEqual(try style(.navigationBarItem).fontColor, .nogpsPrimaryText)
    XCTAssertEqual(try style(.primaryBackground).backgroundColor, .nogpsPrimary)
    XCTAssertEqual(try style(.searchStatusBarView).backgroundColor, .nogpsPrimary)
  }
}
