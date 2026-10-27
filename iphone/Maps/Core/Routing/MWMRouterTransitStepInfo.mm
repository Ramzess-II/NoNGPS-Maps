#import "MWMRouterTransitStepInfo+Core.h"

#include "map/transit/transit_display.hpp"

#include "base/assert.hpp"

namespace
{
MWMRouterTransitType convertType(TransitType type)
{
  switch (type)
  {
  case TransitType::IntermediatePoint: return MWMRouterTransitTypeIntermediatePoint;
  case TransitType::Pedestrian: return MWMRouterTransitTypePedestrian;
  case TransitType::Subway: return MWMRouterTransitTypeSubway;
  case TransitType::Train: return MWMRouterTransitTypeTrain;
  case TransitType::LightRail: return MWMRouterTransitTypeLightRail;
  case TransitType::Monorail: return MWMRouterTransitTypeMonorail;
  case TransitType::Tram: return MWMRouterTransitTypeTram;
  case TransitType::Bus: return MWMRouterTransitTypeBus;
  case TransitType::Ferry: return MWMRouterTransitTypeFerry;
  case TransitType::CableTram: return MWMRouterTransitTypeCableTram;
  case TransitType::AerialLift: return MWMRouterTransitTypeAerialLift;
  case TransitType::Funicular: return MWMRouterTransitTypeFunicular;
  // Trolleybus stops are not visually distinguished from buses in known cities; reuse the bus icon.
  case TransitType::Trolleybus: return MWMRouterTransitTypeBus;
  case TransitType::AirService: return MWMRouterTransitTypeAirService;
  case TransitType::WaterService: return MWMRouterTransitTypeWaterService;
  }
  UNREACHABLE();
}

UIColor * convertColor(uint32_t colorARGB)
{
  CGFloat const alpha = CGFloat((colorARGB >> 24) & 0xFF) / 255;
  CGFloat const red = CGFloat((colorARGB >> 16) & 0xFF) / 255;
  CGFloat const green = CGFloat((colorARGB >> 8) & 0xFF) / 255;
  CGFloat const blue = CGFloat(colorARGB & 0xFF) / 255;
  return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

BOOL equalOrBothNil(id lhs, id rhs)
{
  return lhs == rhs || [lhs isEqual:rhs];
}
}  // namespace

@implementation MWMRouterTransitStepInfo

- (instancetype)initWithStepInfo:(TransitStepInfo const &)info
{
  self = [super init];
  if (self)
  {
    _type = convertType(info.m_type);
    _distance = @(info.m_distanceStr.c_str());
    _distanceUnits = @(info.m_distanceUnitsSuffix.c_str());
    _number = @(info.m_number.c_str());
    _color = convertColor(info.m_colorARGB);
    _intermediateIndex = info.m_intermediateIndex;
  }
  return self;
}

// The steps are made again at every position, so the route preview compares them by what they show.
- (BOOL)isEqual:(id)object
{
  if (self == object)
    return YES;
  if (![object isKindOfClass:[MWMRouterTransitStepInfo class]])
    return NO;
  MWMRouterTransitStepInfo * other = object;
  return self.type == other.type && self.intermediateIndex == other.intermediateIndex &&
         equalOrBothNil(self.distance, other.distance) && equalOrBothNil(self.distanceUnits, other.distanceUnits) &&
         equalOrBothNil(self.number, other.number) && equalOrBothNil(self.color, other.color);
}

- (NSUInteger)hash
{
  return self.type ^ self.distance.hash ^ self.number.hash;
}

@end
