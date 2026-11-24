#import "MWMMailViewController.h"

@implementation MWMMailViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.navigationBar.tintColor = UIColor.nogpsPrimaryText;
  self.navigationBar.barTintColor = UIColor.nogpsPrimary;
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
  return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? UIStatusBarStyleLightContent
                                                                             : UIStatusBarStyleDarkContent;
}

- (UIViewController *)childViewControllerForStatusBarStyle
{
  return nil;
}
@end
