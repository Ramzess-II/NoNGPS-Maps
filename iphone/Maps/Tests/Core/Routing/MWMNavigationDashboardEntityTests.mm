#import <XCTest/XCTest.h>

#import "MWMNavigationDashboardEntity.h"
#import "MWMRouterType.h"

#include "map/transit/transit_display.hpp"
#include "routing/following_info.hpp"

#include <limits>

@class MWMRoutePoint;

@interface MWMNavigationDashboardEntity (Testing)
- (instancetype)initWithFollowingInfo:(routing::FollowingInfo const &)info
                          routePoints:(NSArray<MWMRoutePoint *> *)points
                                 type:(MWMRouterType)type;
- (instancetype)initWithTransitInfo:(TransitRouteInfo const &)info;
@end

namespace
{
int const kRawDurations[] = {
    0, 29, 59, 89, 90, 269, 270, 1665, 2085, 3569, 3570, 3630, 86400, 94485, std::numeric_limits<int>::max()};
}

@interface MWMNavigationDashboardEntityTests : XCTestCase
@end

@implementation MWMNavigationDashboardEntityTests

- (void)testFollowingEstimateKeepsRawSeconds
{
  for (int seconds : kRawDurations)
  {
    routing::FollowingInfo info;
    info.m_time = seconds;
    auto entity = [[MWMNavigationDashboardEntity alloc] initWithFollowingInfo:info
                                                                  routePoints:@[]
                                                                         type:MWMRouterTypeVehicle];
    XCTAssertEqual(entity.timeToTarget, static_cast<NSUInteger>(seconds));
  }
}

- (void)testTransitEstimateKeepsRawSeconds
{
  for (int seconds : kRawDurations)
  {
    TransitRouteInfo info;
    info.m_totalTimeInSec = seconds;
    auto entity = [[MWMNavigationDashboardEntity alloc] initWithTransitInfo:info];
    XCTAssertEqual(entity.timeToTarget, static_cast<NSUInteger>(seconds));
  }
}

// A new entity comes at every position, and the route preview renders again only when its estimate changes.
- (void)testTransitEstimateWithWalkIconIsEqualForTheSameInfo
{
  TransitRouteInfo info;
  info.m_totalTimeInSec = 600;
  info.m_totalPedestrianDistanceStr = "300";
  info.m_totalPedestrianUnitsSuffix = "m";
  auto estimate = [[[MWMNavigationDashboardEntity alloc] initWithTransitInfo:info] estimate];
  XCTAssertEqualObjects(estimate, [[[MWMNavigationDashboardEntity alloc] initWithTransitInfo:info] estimate]);

  info.m_totalPedestrianDistanceStr = "400";
  XCTAssertNotEqualObjects(estimate, [[[MWMNavigationDashboardEntity alloc] initWithTransitInfo:info] estimate]);
}

@end
