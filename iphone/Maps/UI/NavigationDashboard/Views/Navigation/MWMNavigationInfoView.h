#import "RoutePreviewView.h"

typedef NS_ENUM(NSUInteger, MWMNavigationInfoViewState) {
  MWMNavigationInfoViewStateHidden,
  MWMNavigationInfoViewStateNavigation
};

@class MWMNavigationDashboardEntity;

NS_SWIFT_NAME(NavigationInfoView)
@interface MWMNavigationInfoView : UIView

@property(nonatomic) MWMNavigationInfoViewState state;
@property(weak, nonatomic) UIView * ownerView;
@property(nonatomic) CGRect availableArea;
@property(weak, nonatomic) id<RouteNavigationControlsDelegate> delegate;

- (void)onNavigationInfoUpdated:(MWMNavigationDashboardEntity *)info;

@end
