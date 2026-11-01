#import "MWMNavigationInfoView.h"
#import "CLLocation+Mercator.h"
#import "MWMButton.h"
#import "MWMLocationHelpers.h"
#import "MWMLocationManager.h"
#import "MWMMapViewControlsCommon.h"
#import "MapViewController.h"
#import "SwiftBridge.h"
#import "UIImageView+Coloring.h"

#include "geometry/angles.hpp"

namespace
{
CGFloat constexpr kTurnsiPhoneWidth = 96;
CGFloat constexpr kTurnsiPadWidth = 140;

CGFloat constexpr kBaseTurnsTopOffset = 28;
CGFloat constexpr kShiftedTurnsTopOffset = 8;

CGFloat ScaledTurnsWidth()
{
  CGFloat const baseWidth = IPAD ? kTurnsiPadWidth : kTurnsiPhoneWidth;
  CGFloat const scaledWidth = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledValueForValue:baseWidth];
  return MAX(baseWidth, scaledWidth);
}
}  // namespace

@interface MWMNavigationInfoView ()

@property(weak, nonatomic) IBOutlet UIView * streetNameView;
@property(weak, nonatomic) IBOutlet NSLayoutConstraint * streetNameTopOffsetConstraint;
@property(weak, nonatomic) IBOutlet NSLayoutConstraint * streetNameViewHideOffset;
@property(weak, nonatomic) IBOutlet UILabel * streetNameLabel;
@property(weak, nonatomic) IBOutlet UIView * turnsView;
@property(weak, nonatomic) IBOutlet NSLayoutConstraint * turnsViewHideOffset;
@property(weak, nonatomic) IBOutlet UIImageView * nextTurnImageView;
@property(weak, nonatomic) IBOutlet UILabel * roundTurnLabel;
@property(weak, nonatomic) IBOutlet UILabel * distanceToNextTurnLabel;
@property(weak, nonatomic) IBOutlet UIView * secondTurnView;
@property(weak, nonatomic) IBOutlet UIImageView * secondTurnImageView;
@property(weak, nonatomic) IBOutlet NSLayoutConstraint * turnsWidth;

@property(weak, nonatomic) IBOutlet NSLayoutConstraint * turnsTopOffset;

@property(nonatomic) BOOL isVisible;

@property(weak, nonatomic) MWMNavigationDashboardEntity * navigationInfo;

@property(nonatomic) BOOL hasLocation;

@property(nonatomic) NSLayoutConstraint * topConstraint;
@property(nonatomic) NSLayoutConstraint * leadingConstraint;
@property(nonatomic) NSLayoutConstraint * trailingConstraint;
@property(nonatomic) NSLayoutConstraint * heightConstraint;

@end

@implementation MWMNavigationInfoView

- (void)awakeFromNib
{
  [super awakeFromNib];

  self.streetNameLabel.font = UIFont.bold24.dynamic;
  self.streetNameLabel.adjustsFontForContentSizeCategory = YES;

  self.roundTurnLabel.font = UIFont.bold24.dynamic;
  self.roundTurnLabel.adjustsFontForContentSizeCategory = YES;

  self.distanceToNextTurnLabel.adjustsFontForContentSizeCategory = YES;
  self.turnsWidth.constant = ScaledTurnsWidth();
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
  [super traitCollectionDidChange:previousTraitCollection];
  if (previousTraitCollection && [previousTraitCollection.preferredContentSizeCategory
                                     isEqualToString:self.traitCollection.preferredContentSizeCategory])
    return;

  self.turnsWidth.constant = ScaledTurnsWidth();
  [self onNavigationInfoUpdated:self.navigationInfo];
  [self setNeedsLayout];
}

- (IBAction)ttsButtonAction
{
  [self.delegate ttsButtonDidTap];
}

- (IBAction)settingsButtonAction
{
  [self.delegate settingsButtonDidTap];
}

- (IBAction)stopRoutingButtonAction
{
  [self.delegate stopRoutingButtonDidTap];
}

#pragma mark - MWMNavigationDashboardManager

- (void)onNavigationInfoUpdated:(MWMNavigationDashboardEntity *)info
{
  self.navigationInfo = info;
  if (self.state != MWMNavigationInfoViewStateNavigation)
    return;
  if (info.streetName.length != 0)
  {
    [self setStreetNameVisible:YES];
    self.streetNameLabel.text = info.streetName;
  }
  else
  {
    [self setStreetNameVisible:NO];
  }
  if (info.turnImage)
  {
    [self setTurnsViewVisible:YES];
    self.nextTurnImageView.image = info.turnImage;

    if (info.roundExitNumber == 0)
    {
      self.roundTurnLabel.hidden = YES;
    }
    else
    {
      self.roundTurnLabel.hidden = NO;
      self.roundTurnLabel.text = @(info.roundExitNumber).stringValue;
    }

    NSDictionary * turnNumberAttributes = @{
      NSForegroundColorAttributeName: [UIColor whitePrimary],
      NSFontAttributeName: IPAD ? UIFont.bold36.dynamic : UIFont.bold28.dynamic
    };
    NSDictionary * turnLegendAttributes = @{
      NSForegroundColorAttributeName: [UIColor whitePrimary],
      NSFontAttributeName: IPAD ? UIFont.bold24.dynamic : UIFont.bold16.dynamic
    };

    NSMutableAttributedString * distance = [[NSMutableAttributedString alloc] initWithString:info.distanceToTurn
                                                                                  attributes:turnNumberAttributes];
    [distance appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:[NSString stringWithFormat:@" %@", info.turnUnits]
                                             attributes:turnLegendAttributes]];

    self.distanceToNextTurnLabel.attributedText = distance;
    if (info.nextTurnImage)
    {
      self.secondTurnView.hidden = NO;
      self.secondTurnImageView.image = info.nextTurnImage;
    }
    else
    {
      self.secondTurnView.hidden = YES;
    }
  }
  else
  {
    [self setTurnsViewVisible:NO];
  }
  [self setNeedsLayout];
}

#pragma mark - SolidTouchView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
  UIView * hitView = [super hitTest:point withEvent:event];
  if (hitView == self)
    return nil;
  return hitView;
}

- (void)configLayout
{
  UIView * ov = self.superview;
  self.translatesAutoresizingMaskIntoConstraints = NO;

  self.topConstraint = [self.topAnchor constraintEqualToAnchor:ov.topAnchor];
  self.leadingConstraint = [self.leadingAnchor constraintEqualToAnchor:ov.leadingAnchor];
  self.trailingConstraint = [self.trailingAnchor constraintEqualToAnchor:ov.trailingAnchor];
  self.heightConstraint = [self.heightAnchor constraintEqualToConstant:ov.frame.size.height];
  self.streetNameTopOffsetConstraint.constant = self.additionalStreetNameTopOffset;
  [NSLayoutConstraint activateConstraints:@[
    self.topConstraint, self.leadingConstraint, self.trailingConstraint, self.heightConstraint
  ]];
  [self refreshLayout];
}

// Additional spacing for devices with a small top safe area (such as SE or when the device is in landscape mode).
- (CGFloat)additionalStreetNameTopOffset
{
  return MapsAppDelegate.theApp.window.safeAreaInsets.top <= 20 ? 10 : 0;
  ;
}

- (void)refreshLayout
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation))
      self.streetNameLabel.numberOfLines = 1;
    else
      self.streetNameLabel.numberOfLines = 2;

    auto const availableArea = self.availableArea;
    [self animateConstraintsWithAnimations:^{
      self.topConstraint.constant = availableArea.origin.y;
      self.leadingConstraint.constant = availableArea.origin.x + kViewControlsOffsetToBounds;
      self.trailingConstraint.constant = availableArea.origin.x - kViewControlsOffsetToBounds;
      self.heightConstraint.constant = availableArea.size.height;

      self.turnsTopOffset.constant = availableArea.origin.y > 0 ? kShiftedTurnsTopOffset : kBaseTurnsTopOffset;
      self.streetNameTopOffsetConstraint.constant = self.additionalStreetNameTopOffset;
    }];
  });
}

#pragma mark - Properties

- (void)setAvailableArea:(CGRect)availableArea
{
  if (CGRectEqualToRect(_availableArea, availableArea))
    return;
  _availableArea = availableArea;
  [self refreshLayout];
}

- (void)setState:(MWMNavigationInfoViewState)state
{
  if (_state == state)
    return;
  _state = state;
  switch (state)
  {
  case MWMNavigationInfoViewStateHidden: self.isVisible = NO; break;
  case MWMNavigationInfoViewStateNavigation: self.isVisible = YES; break;
  }
}

- (void)setStreetNameVisible:(BOOL)isVisible
{
  self.streetNameView.hidden = !isVisible;
  self.streetNameViewHideOffset.priority = isVisible ? UILayoutPriorityDefaultLow : UILayoutPriorityDefaultHigh;
}

- (void)setTurnsViewVisible:(BOOL)isVisible
{
  self.turnsView.hidden = !isVisible;
  self.turnsViewHideOffset.priority = isVisible ? UILayoutPriorityDefaultLow : UILayoutPriorityDefaultHigh;
}

- (void)setIsVisible:(BOOL)isVisible
{
  if (_isVisible == isVisible)
    return;
  _isVisible = isVisible;
  [self setNeedsLayout];
  if (isVisible)
  {
    self.turnsWidth.constant = ScaledTurnsWidth();
    UIView * sv = self.ownerView;
    NSAssert(sv != nil, @"Superview can't be nil");
    if (![sv.subviews containsObject:self])
    {
      [sv insertSubview:self atIndex:0];
      [self configLayout];
    }
  }
  [UIView animateWithDuration:AppConstants.defaultAnimationDuration
      animations:^{
        self.alpha = isVisible ? 1 : 0;
        [self layoutIfNeeded];
      }
      completion:^(BOOL finished) {
        if (!isVisible)
          self.hidden = isVisible;
      }];
}

@end
