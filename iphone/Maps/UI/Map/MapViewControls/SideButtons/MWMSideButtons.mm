#import "MWMSideButtons.h"
#import "MWMButton.h"
#import "MWMLocationManager.h"
#import "MWMMapViewControlsManager.h"
#import "MWMSideButtonsView.h"
#import "SwiftBridge.h"

#include <CoreApi/Framework.h>

namespace
{
NSString * const kMWMSideButtonsViewNibName = @"MWMSideButtonsView";
NSString * const kUDDidShowLongTapToShowSideButtonsToast = @"kUDDidShowLongTapToShowSideButtonsToast";
// A slide shorter than this is a tap, pt.
CGFloat const kZoomSwipeStartPt = 24;
}  // namespace

@interface MWMMapViewControlsManager ()

@property(nonatomic) MWMSideButtons * sideButtons;

@end

@interface MWMSideButtons () <UIGestureRecognizerDelegate>

@property(nonatomic) IBOutlet MWMSideButtonsView * sideView;
@property(weak, nonatomic) IBOutlet MWMButton * zoomInButton;
@property(weak, nonatomic) IBOutlet MWMButton * zoomOutButton;
@property(weak, nonatomic) IBOutlet MWMButton * locationButton;

// The zoom button the finger is on, and whether its slide has become a zoom.
@property(weak, nonatomic) MWMButton * pressedZoomButton;
@property(nonatomic) BOOL zoomSwipeStarted;
// The slide of the finger up already applied to the zoom, pt.
@property(nonatomic) CGFloat zoomSwipeApplied;
@property(nonatomic, readonly) BOOL isZoomEnabled;

@property(nonatomic) MWMMyPositionMode locationMode;

@end

@implementation MWMSideButtons

- (UIView *)view
{
  return self.sideView;
}

+ (MWMSideButtons *)buttons
{
  return [MWMMapViewControlsManager manager].sideButtons;
}

+ (UIView *)introAnchor
{
  return [self buttons].sideView;
}
- (instancetype)initWithParentView:(UIView *)view
{
  self = [super init];
  if (self)
  {
    [NSBundle.mainBundle loadNibNamed:kMWMSideButtonsViewNibName owner:self options:nil];
    [self.zoomInButton setImage:[MWMSideButtons symbol:@"plus"] forState:UIControlStateNormal];
    [self.zoomOutButton setImage:[MWMSideButtons symbol:@"minus"] forState:UIControlStateNormal];
    [self.locationButton setStyleNameAndApply:@"mapPanelButton"];
    [view addSubview:self.sideView];
    [self.sideView setNeedsLayout];
    // The pan zooms only from the zoom buttons, and lets the touch through until it does.
    for (UIGestureRecognizer * recognizer in self.sideView.gestureRecognizers)
    {
      if ([recognizer isKindOfClass:UIPanGestureRecognizer.class])
      {
        recognizer.delegate = self;
        recognizer.cancelsTouchesInView = NO;
      }
    }
    self.zoomHidden = NO;
  }
  return self;
}

+ (void)updateAvailableArea:(CGRect)frame
{
  [[self buttons].sideView updateAvailableArea:frame];
}

- (void)zoomIn
{
  GetFramework().Scale(Framework::SCALE_MAG, true);
}

- (void)zoomOut
{
  GetFramework().Scale(Framework::SCALE_MIN, true);
}

- (void)processMyPositionStateModeEvent:(MWMMyPositionMode)mode
{
  [self refreshLocationButtonState:mode];
  self.locationMode = mode;
}

- (void)resetSearch
{
  [self.sideView.searchWheel reset];
}

#pragma mark - Location button

+ (UIImage *)symbol:(NSString *)name
{
  auto const config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
  return [UIImage systemImageNamed:name withConfiguration:config];
}

- (void)refreshLocationButtonState:(MWMMyPositionMode)state
{
  MWMButton * locBtn = self.locationButton;
  [locBtn.imageView stopRotation];
  NSString * symbol = @"location";
  switch (state)
  {
  case MWMMyPositionModePendingPosition:
  case MWMMyPositionModeNotFollow:
  case MWMMyPositionModeNotFollowNoPosition: break;
  case MWMMyPositionModeFollow: symbol = @"location.fill"; break;
  case MWMMyPositionModeFollowAndRotate: symbol = @"location.north.line.fill"; break;
  }
  [locBtn setImage:[MWMSideButtons symbol:symbol] forState:UIControlStateNormal];
  if (state == MWMMyPositionModePendingPosition)
    [locBtn.imageView startRotation:1];
}

#pragma mark - Actions

- (IBAction)zoomTouchDown:(MWMButton *)sender
{
  self.pressedZoomButton = sender;
}
- (IBAction)zoomTouchUpInside:(UIButton *)sender
{
  self.pressedZoomButton = nil;
  if ([sender isEqual:self.zoomInButton])
    [self zoomIn];
  else
    [self zoomOut];
}

- (IBAction)zoomTouchUpOutside:(UIButton *)sender
{
  self.pressedZoomButton = nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
  return [touch.view isDescendantOfView:self.zoomInButton] || [touch.view isDescendantOfView:self.zoomOutButton];
}

- (IBAction)zoomSwipe:(UIPanGestureRecognizer *)sender
{
  UIView * const superview = self.sideView.superview;
  CGFloat const dy = -[sender translationInView:superview].y;
  if (sender.state == UIGestureRecognizerStateBegan)
    self.zoomSwipeStarted = NO;
  if (!self.zoomSwipeStarted)
  {
    if (!self.pressedZoomButton || fabs(dy) < kZoomSwipeStartPt)
      return;
    // The slide is a zoom now: the button must not tap when the finger lifts.
    self.zoomSwipeStarted = YES;
    // Zoom counts from where the slide became a zoom, so it never jumps when the finger comes back.
    self.zoomSwipeApplied = dy;
    [self.pressedZoomButton cancelTrackingWithEvent:nil];
    self.pressedZoomButton = nil;
  }
  // Only the new part of the slide zooms: a resting finger holds the zoom, whatever the rate of touch events.
  CGFloat const slide = dy - self.zoomSwipeApplied;
  self.zoomSwipeApplied = dy;
  if (slide != 0)
    GetFramework().Scale([MapControlsPanel zoomFactorForSlide:slide frameHeight:superview.bounds.size.height], false);
}

- (IBAction)locationTouchUpInside
{
  [MWMLocationManager enableLocationAlert];
  GetFramework().SwitchMyPositionNextMode();
}

#pragma mark - Properties

- (BOOL)zoomHidden
{
  return self.sideView.zoomHidden;
}
- (void)setZoomHidden:(BOOL)zoomHidden
{
  self.sideView.zoomHidden = zoomHidden;
}

- (BOOL)searchShown
{
  return self.sideView.searchShown;
}
- (void)setSearchShown:(BOOL)searchShown
{
  self.sideView.searchShown = searchShown;
}

- (BOOL)hidden
{
  return self.sideView.hidden;
}
- (void)setHidden:(BOOL)hidden
{
  return [self.sideView setHidden:hidden animated:YES];
}

@end
