#import "MWMSideButtonsView.h"
#import "MWMButton.h"
#import "SwiftBridge.h"

namespace
{
CGFloat const kButtonsTopOffset = 6;
CGFloat const kButtonsBottomOffset = 6;
NSString * const kPanelPlaceKey = @"NoGpsRightPanelY";
}  // namespace

@interface MWMSideButtonsView ()

@property(weak, nonatomic) IBOutlet MWMButton * zoomIn;
@property(weak, nonatomic) IBOutlet MWMButton * zoomOut;
@property(weak, nonatomic) IBOutlet MWMButton * location;

@property(nonatomic) CGRect availableArea;
@property(nonatomic) MapControlsPanel * panel;
@property(nonatomic) UIView * locationDivider;
@property(nonatomic) UIView * searchDivider;
@property(nonatomic, readwrite) NavigationSearchWheel * searchWheel;
@property(nonatomic) MapPanelDragger * dragger;

@end

@implementation MWMSideButtonsView

- (void)awakeFromNib
{
  [super awakeFromNib];
  self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.panel =
      [[MapControlsPanel alloc] initWithEdge:self.isRTL ? MapControlsPanelEdgeLeft : MapControlsPanelEdgeRight];
  [self insertSubview:self.panel atIndex:0];
  self.locationDivider = [self addDivider];
  self.searchDivider = [self addDivider];
  self.searchWheel = [[NavigationSearchWheel alloc] init];
  [self addSubview:self.searchWheel.button];
  [self addSubview:self.searchWheel];
  __weak auto weakSelf = self;
  self.searchWheel.onChange = ^{
    // A touch on the open wheel is not a long press on the panel.
    weakSelf.dragger.isEnabled = !weakSelf.searchWheel.isOpen;
  };
  self.dragger = [[MapPanelDragger alloc] initWithView:self
      key:kPanelPlaceKey
      travel:^CGFloat { return weakSelf.travel; }
      onLift:^(BOOL lifted) { weakSelf.panel.isLifted = lifted; }
      onMove:^{ [weakSelf layoutYPosition]; }];
}

- (UIView *)addDivider
{
  UIView * divider = [[UIView alloc] init];
  divider.userInteractionEnabled = NO;
  [divider setStyleNameAndApply:@"SolidDivider"];
  [self addSubview:divider];
  return divider;
}

- (void)layoutSubviews
{
  UIButton * search = self.searchWheel.button;
  search.hidden = !self.searchShown;
  search.frame = {{}, self.zoomIn.size};
  self.zoomIn.minY = self.searchShown ? search.maxY + MapControlsPanel.groupGap : 0;
  self.zoomOut.minY = self.zoomIn.maxY;
  self.location.minY = self.zoomOut.maxY + MapControlsPanel.groupGap;
  self.bounds = {{}, {self.zoomOut.width, self.location.maxY}};
  if (self.zoomHidden)
    self.height = self.location.height;
  self.location.maxY = self.height;
  // Beside the panel, toward the middle of the map, its flat side at the panel.
  self.searchWheel.frame = {
      {self.isRTL ? self.width : -self.searchWheel.width, search.midY - self.searchWheel.height / 2},
      self.searchWheel.size};

  [self animate];
  [self layoutPanel];
  [super layoutSubviews];
}

- (BOOL)isRTL
{
  return UIApplication.sharedApplication.userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
}

- (BOOL)isZoomShown
{
  return !self.zoomHidden && self.location.maxY <= self.availableHeight;
}

// The panel goes on to the edge of the screen, under the safe area too.
- (void)layoutPanel
{
  BOOL const zoomShown = self.isZoomShown;
  CGFloat const top = zoomShown ? 0 : self.location.minY;
  CGFloat const edgeGap =
      self.isRTL ? self.availableArea.origin.x : self.superview.width - CGRectGetMaxX(self.availableArea);
  CGRect const frame = {{self.isRTL ? -edgeGap : 0, top}, {self.width + edgeGap, self.height - top}};
  self.locationDivider.hidden = !zoomShown;
  self.searchDivider.hidden = !zoomShown || !self.searchShown;
  // No empty panel when even the location button has no place.
  self.panel.hidden = self.location.height > self.availableHeight;
  // The line between the zoom buttons and the location button, with margins on every side.
  CGFloat const margin = MapControlsPanel.groupDividerMargin;
  CGFloat const height = MapControlsPanel.groupDividerHeight;
  self.locationDivider.frame = {{margin, self.zoomOut.maxY + (MapControlsPanel.groupGap - height) / 2},
                                {self.width - 2 * margin, height}};
  self.searchDivider.frame = {{margin, self.zoomIn.minY - (MapControlsPanel.groupGap + height) / 2},
                              {self.width - 2 * margin, height}};
  if (CGRectEqualToRect(self.panel.frame, frame))
    return;
  BOOL const animated = !CGRectIsEmpty(self.panel.frame) && self.panel.frame.origin.y != frame.origin.y;
  [UIView animateWithDuration:animated ? AppConstants.defaultAnimationDuration : 0
                   animations:^{ self.panel.frame = frame; }];
}

- (void)layoutXPosition:(BOOL)hidden
{
  if (UIApplication.sharedApplication.userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft)
  {
    if (hidden)
      self.maxX = 0;
    else
      self.minX = self.availableArea.origin.x;
  }
  else
  {
    auto const availableAreaMaxX = self.availableArea.origin.x + self.availableArea.size.width;
    if (hidden)
      self.minX = self.superview.width;
    else
      self.maxX = availableAreaMaxX;
  }
}

// The panel on the left side of the map has the same center by default.
- (void)layoutYPosition
{
  // The panel follows the finger.
  NSTimeInterval const duration = self.dragger.isMoving ? 0 : AppConstants.defaultAnimationDuration;
  [UIView animateWithDuration:duration
                   animations:^{
                     self.minY = self.topBound + self.dragger.fraction * self.travel;
                     if (self.maxY > self.bottomBound)
                       self.maxY = self.bottomBound;
                   }];
}

- (void)fadeZoomButtonsShow:(BOOL)show
{
  CGFloat const alpha = show ? 1.0 : 0.0;
  [UIView animateWithDuration:AppConstants.defaultAnimationDuration
                   animations:^{
                     self.zoomIn.alpha = alpha;
                     self.zoomOut.alpha = alpha;
                     self.searchWheel.button.alpha = alpha;
                   }];
}

- (void)fadeLocationButtonShow:(BOOL)show
{
  [UIView animateWithDuration:AppConstants.defaultAnimationDuration
                   animations:^{ self.location.alpha = show ? 1.0 : 0.0; }];
}

// Show/hide zoom and location buttons depending on available vertical space.
- (void)animate
{
  [self layoutYPosition];

  BOOL const isZoomHidden = self.zoomIn.alpha == 0.0;
  BOOL const willZoomHide = (self.location.maxY > self.availableHeight);
  if (willZoomHide != isZoomHidden)
    [self fadeZoomButtonsShow:!willZoomHide];

  BOOL const isLocationHidden = self.location.alpha == 0.0;
  BOOL const willLocationHide = (self.location.height > self.availableHeight);
  if (willLocationHide != isLocationHidden)
    [self fadeLocationButtonShow:!willLocationHide];
}

// The open wheel lies out of the panel.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
  if (self.searchWheel.isOpen && CGRectContainsPoint(self.searchWheel.frame, point))
    return YES;
  return [super pointInside:point withEvent:event];
}

#pragma mark - Properties

- (void)setSearchShown:(BOOL)searchShown
{
  if (_searchShown == searchShown)
    return;
  _searchShown = searchShown;
  if (!searchShown)
    [self.searchWheel clear];
  [self setNeedsLayout];
}

- (void)setZoomHidden:(BOOL)zoomHidden
{
  _zoomHidden = zoomHidden;
  self.zoomIn.hidden = zoomHidden;
  self.zoomOut.hidden = zoomHidden;
  [self setNeedsLayout];
}

- (void)setHidden:(BOOL)hidden animated:(BOOL)animated
{
  if (animated)
  {
    if (self.hidden == hidden)
      return;
    // Side buttons should be visible during any our show/hide anamation.
    // Visibility should be detemined by alpha, not self.hidden.
    self.hidden = NO;
    [UIView animateWithDuration:AppConstants.defaultAnimationDuration
        animations:^{
          self.alpha = hidden ? 0.0 : 1.0;
          [self layoutXPosition:hidden];
        }
        completion:^(BOOL finished) { self.hidden = hidden; }];
  }
  else
  {
    self.hidden = hidden;
  }
}

- (void)updateAvailableArea:(CGRect)frame
{
  if (CGRectIsEmpty(frame))
    return;
  if (CGRectEqualToRect(self.availableArea, frame))
    return;
  // If during our show/hide animation position is changed it is corrupted.
  // Such kind of animation has 2 keys (opacity and position).
  // But there are other animation cases like change of orientation.
  // So we can use condition below:
  // if (self.layer.animationKeys.count != 2)
  // More elegant way is to check if x values are changed.
  // If no - there is no need to update self x values.
  if (self.availableArea.origin.x != frame.origin.x || self.availableArea.size.width != frame.size.width)
  {
    self.availableArea = frame;
    [self layoutXPosition:self.hidden];
  }
  else
    self.availableArea = frame;
  [self setNeedsLayout];
}

- (CGFloat)availableHeight
{
  return self.availableArea.size.height - kButtonsTopOffset - kButtonsBottomOffset;
}

// The distance the buttons can be moved by the user.
- (CGFloat)travel
{
  return MAX(0, self.bottomBound - self.topBound - self.height);
}

- (CGFloat)topBound
{
  return self.availableArea.origin.y + kButtonsTopOffset;
}
- (CGFloat)bottomBound
{
  auto const area = self.availableArea;
  return area.origin.y + area.size.height - kButtonsBottomOffset;
}

@end
