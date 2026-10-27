@testable import Organic_Maps__Debug_
import XCTest

final class MWMRoutePointTests: XCTestCase {
  func test_GivenMissingRoutePointMetadata_WhenInitialized_ThenUsesCoordinatesAsTitle() {
    for title in [nil, ""] as [String?] {
      let routePoint = MWMRoutePoint(cgPoint: .zero,
                                     title: title,
                                     subtitle: nil,
                                     type: .intermediate,
                                     intermediateIndex: 0)

      XCTAssertEqual(routePoint.title, routePoint.latLonString)
      XCTAssertEqual(routePoint.subtitle, "")
    }
  }

  func test_GivenNamedRoutePoint_WhenInitialized_ThenKeepsName() {
    let routePoint = MWMRoutePoint(cgPoint: .zero,
                                   title: "Some place",
                                   subtitle: nil,
                                   type: .intermediate,
                                   intermediateIndex: 0)

    XCTAssertEqual(routePoint.title, "Some place")
    XCTAssertEqual(routePoint.subtitle, "")
  }

  func test_GivenNoNearbyAddress_WhenInitializedFromMapPoint_ThenUsesCoordinatesAsTitle() {
    let point = CGPoint.zero
    let address = FrameworkHelper.address(at: point)
    XCTAssertNil(address)

    let routePoint = MWMRoutePoint(cgPoint: point,
                                   title: address,
                                   subtitle: nil,
                                   type: .intermediate,
                                   intermediateIndex: 0)

    XCTAssertEqual(routePoint.title, routePoint.latLonString)
  }

  /// The navigation without GPS shows the car by a mark of the user or by the sensor box also when the location
  /// services are off or denied, and the route starts there.
  func test_GivenNoGpsMarkWithoutLocationServices_WhenInitializedFromLastLocation_ThenStartsAtTheMark() throws {
    let wasStarted = LocationManager.isStarted()
    LocationManager.stop()
    defer {
      if wasStarted {
        LocationManager.start()
      }
    }
    let mark = CLLocation(latitude: 50.45, longitude: 30.52)
    LocationManager.onNoGpsPosition(mark, fromGps: false)

    let routePoint = try XCTUnwrap(MWMRoutePoint(lastLocationAndType: .start, intermediateIndex: 0))
    XCTAssertTrue(routePoint.isMyPosition)
    XCTAssertEqual(routePoint.latitude, 50.45, accuracy: 1e-6)
    XCTAssertEqual(routePoint.longitude, 30.52, accuracy: 1e-6)

    // A GPS position needs the location services.
    LocationManager.onNoGpsPosition(mark, fromGps: true)
    XCTAssertNil(MWMRoutePoint(lastLocationAndType: .start, intermediateIndex: 0))
  }
}
